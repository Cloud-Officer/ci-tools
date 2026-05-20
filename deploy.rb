#!/usr/bin/env ruby
#
# https://docs.aws.amazon.com/sdk-for-ruby

# frozen_string_literal: true

require 'aws-sdk-autoscaling'
require 'aws-sdk-cloudformation'
require 'aws-sdk-cloudfront'
require 'aws-sdk-core'
require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'
require 'aws-sdk-lambda'
require 'aws-sdk-ssm'
require 'optparse'

# Timing constants for polling and warmup periods
POLL_INTERVAL = 15      # Seconds between status checks
MAX_POLL_ATTEMPTS = 120 # Max polling attempts (30 minutes at 15-second intervals)
WARMUP_SHORT = 60       # Short warmup period for standard instances
WARMUP_LONG = 180       # Long warmup period for gRPC instances

# Instance types that use load balancer health checks
LOAD_BALANCED_INSTANCES = %w[api grpc].freeze

# CloudFormation stack statuses to query
ACTIVE_STACK_STATUSES = %w[CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE UPDATE_FAILED UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_COMPLETE IMPORT_ROLLBACK_IN_PROGRESS IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE].freeze

def load_balanced_instance?(instance)
  LOAD_BALANCED_INSTANCES.include?(instance)
end

def poll_until(description:, max_attempts: MAX_POLL_ATTEMPTS, interval: POLL_INTERVAL)
  attempts = 0
  loop do
    raise("Timed out #{description}") if (attempts += 1) > max_attempts

    sleep(interval)
    break if yield
  end
end

def wait_for_healthy_instances(elb, target_group_arn)
  puts('Waiting for all instances to be healthy...')
  poll_until(description: 'waiting for healthy instances') do
    unhealthy =
      elb.describe_target_health({ target_group_arn: target_group_arn })
         .target_health_descriptions.count { |h| h.target_health.state != 'healthy' }
    puts("Waiting on #{unhealthy} unhealthy targets...")
    unhealthy.zero?
  end
end

def wait_for_asg_instance_count(asg_client, asg_name, target_count)
  poll_until(description: "waiting for ASG #{asg_name} to reach #{target_count} instances") do
    response = asg_client.describe_auto_scaling_groups({ auto_scaling_group_names: [asg_name] }).auto_scaling_groups
    raise("Unable to describe ASG #{asg_name}") if response.empty?

    count = response.first.instances.count
    puts("Waiting on instances #{count}/#{target_count}...")
    count == target_count
  end
end

def find_matching_distribution(cloudfront, environment)
  cloudfront.list_distributions.distribution_list.items.find do |distribution|
    distribution.aliases.items.any? { |a| a.include?(environment) }
  end
end

def update_distribution_lambda(cloudfront, distribution, function_arn)
  associations = distribution.default_cache_behavior.lambda_function_associations
  return if !associations.quantity.zero? && associations.items.first.lambda_function_arn == function_arn

  puts("Updating distribution #{distribution.id} lambda function associations to #{function_arn}...")
  config = cloudfront.get_distribution_config({ id: distribution.id })
  config_assoc = config.distribution_config.default_cache_behavior.lambda_function_associations

  if config_assoc.quantity.zero?
    config_assoc.items.push({ event_type: 'viewer-request', include_body: false, lambda_function_arn: function_arn })
    config_assoc.quantity = 1
  else
    config_assoc.items.first.lambda_function_arn = function_arn
  end

  cloudfront.update_distribution({ id: distribution.id, if_match: config.etag, distribution_config: config.distribution_config })
  puts("Update completed successfully for distribution #{distribution.id} and lambda function associations to #{function_arn}.")
end

def publish_lambda_and_update_cloudfront(options)
  puts("Publishing lambda version for function #{options[:lambda_publish_version]}...")
  lambda_client = Aws::Lambda::Client.new
  version = lambda_client.publish_version({ function_name: "#{options[:environment]} - #{options[:lambda_publish_version]}" })
  puts("Publish completed successfully for function ARN = #{version.function_arn}.")
  puts('Checking cloudfront distributions...')
  cloudfront = Aws::CloudFront::Client.new
  distribution = find_matching_distribution(cloudfront, options[:environment])
  raise('Unable to find cloudfront distribution') if distribution.nil?

  update_distribution_lambda(cloudfront, distribution, version.function_arn)
end

def find_standalone_instance(ec2, options)
  puts("Searching for #{options[:instance]} standalone instance...")
  ec2.instances.each do |instance|
    next unless %w[running stopped].include?(instance.data.state.name)

    instance.tags.each do |tag|
      next unless tag.key == 'Name'
      next unless tag.value[/#{Regexp.escape(options[:instance])}-#{Regexp.escape(options[:environment])}.*-standalone/]

      puts("Standalone instance #{tag.value} found with id #{instance.id}.")
      return [instance.id, tag.value]
    end
  end

  raise('Unable to find standalone instance')
end

def create_ami(ec2, instance_id, instance_name, options)
  ami = ec2.client.create_image({ instance_id: instance_id, name: instance_name.sub('standalone', Time.now.strftime('%Y-%m-%d-%H%M%S')) })
  puts("Creating image #{ami.image_id}...")
  max_attempts = options[:instance] == 'worker' ? 1024 : 256
  Aws::EC2::Waiters::ImageAvailable.new({ client: ec2.client, max_attempts: max_attempts, delay: 30 }).wait(
    { filters: [{ name: 'image-id', values: [ami.image_id] }, { name: 'state', values: ['available'] }] }
  )

  puts("Image creation completed for #{ami.image_id}.")
  ami.image_id
end

def find_auto_scaling_group(asg_resources, options)
  puts('Checking auto scaling groups...')
  asg_resources.groups.each do |group|
    next unless group.auto_scaling_group_name[/#{Regexp.escape(options[:environment])}.*-#{Regexp.escape(options[:instance])}.*/]

    puts("Auto scaling group #{group.auto_scaling_group_name} found with desired capacity at #{group.desired_capacity}.")
    return { name: group.auto_scaling_group_name, desired_capacity: group.desired_capacity, min_size: group.min_size, max_size: group.max_size }
  end

  raise('Unable to find auto scaling group')
end

def find_target_group(elb, options)
  ports = options[:instance] == 'grpc' ? ['8443-HTTP2'] : %w[80 443]
  puts('Checking load balancer target groups...')

  elb.describe_target_groups.each do |targets|
    targets.target_groups.each do |group|
      ports.each do |port|
        return group.target_group_arn if group.target_group_name[/#{Regexp.escape(options[:environment])}\d*-#{Regexp.escape(port)}$/]
      end
    end
  end

  raise('Unable to find load balancer target group')
end

def find_cloudformation_stack(cfn, options)
  puts('Checking cloudformation stacks...')
  cfn.list_stacks({ stack_status_filter: ACTIVE_STACK_STATUSES }).stack_summaries.each do |stack|
    next unless stack.stack_name[/#{Regexp.escape(options[:environment])}.*-StackInstances.*/]

    puts("Stack #{stack.stack_name} found with status #{stack.stack_status}.")
    return stack.stack_name
  end

  raise('Unable to find cloudformation stack')
end

def parameter_prefix_for(instance)
  case instance
  when 'api', 'grpc' then instance.upcase
  else instance.capitalize
  end
end

def resolve_parameter_value(key, prefix, ami_id, asg, options)
  case key
  when "#{prefix}ImageId" then ami_id
  when "#{prefix}MinSize" then asg[:min_size].to_s
  when "#{prefix}MaxSize" then asg[:max_size].to_s
  when "#{prefix}DesiredCapacity" then asg[:desired_capacity].to_s
  when "#{prefix}InstanceType" then options[:type]
  when 'SpotTargetCapacity' then options[:spot_target_capacity]&.to_s
  end
end

CFN_SECRET_PARAMETERS = %w[DbPassword MqPassword SendGridApiKey].freeze

def update_ssm_parameters(parameters, prefix, ami_id, asg, options, ssm_prefix)
  ssm = Aws::SSM::Client.new
  parameters.each do |parameter|
    replace_with = resolve_parameter_value(parameter.parameter_key, prefix, ami_id, asg, options)
    next if replace_with.nil?

    puts("Updating SSM parameter '#{ssm_prefix}/#{parameter.parameter_key}' with value = '#{replace_with}'...")
    ssm.put_parameter({ name: "#{ssm_prefix}/#{parameter.parameter_key}", value: replace_with, type: 'String', overwrite: true })
  end
end

def mark_cfn_secrets_for_previous_value!(parameters)
  parameters.each do |parameter|
    next unless CFN_SECRET_PARAMETERS.include?(parameter.parameter_key)

    parameter.parameter_value = nil
    parameter.use_previous_value = true
  end
end

def capture_ssm_snapshot(parameters, prefix, ami_id, asg, options, ssm_prefix)
  names =
    parameters.filter_map do |parameter|
      next if resolve_parameter_value(parameter.parameter_key, prefix, ami_id, asg, options).nil?

      "#{ssm_prefix}/#{parameter.parameter_key}"
    end

  return {} if names.empty?

  ssm = Aws::SSM::Client.new
  response = ssm.get_parameters({ names: names, with_decryption: true })
  response.parameters.to_h { |p| [p.name, p.value] }
end

def restore_ssm_parameters(ssm_snapshot)
  return if ssm_snapshot.empty?

  ssm = Aws::SSM::Client.new

  ssm_snapshot.each do |name, value|
    puts("Restoring SSM parameter '#{name}' to '#{value}'...")
    ssm.put_parameter({ name: name, value: value, type: 'String', overwrite: true })
  end
end

def wait_for_stack_update(cfn, stack_name)
  failure_states = %w[UPDATE_FAILED UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED]
  poll_until(description: "waiting for stack #{stack_name} to update") do
    response = cfn.describe_stacks({ stack_name: stack_name }).stacks
    raise("Unable to describe stack #{stack_name}") if response.empty?

    raise('Stack update failed') if failure_states.include?(response.first.stack_status)

    response.first.stack_status == 'UPDATE_COMPLETE'
  end
end

def update_cloudformation_stack(cfn, stack_name, parameters, prefix, ami_id)
  puts("Updating cloudformation stack #{stack_name} with #{prefix}ImageId #{ami_id}...")
  begin
    cfn.update_stack({ stack_name: stack_name, use_previous_template: true, parameters: parameters, capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND], disable_rollback: false })
  rescue Aws::CloudFormation::Errors::ValidationError => e
    puts("Stopping here: #{e.message}")
    exit(e.message.include?('No updates are to be performed') ? 0 : 1)
  end
  wait_for_stack_update(cfn, stack_name)
  puts("Update completed successfully for cloudformation stack #{stack_name} with #{prefix}ImageId #{ami_id}.")
end

def update_stack_with_ssm_rollback(cfn, stack_name, parameters, prefix, ami_id, ssm_snapshot)
  update_cloudformation_stack(cfn, stack_name, parameters, prefix, ami_id)
rescue SystemExit => e
  if e.status.nonzero?
    puts('CloudFormation update failed, rolling back SSM parameters...')
    restore_ssm_parameters(ssm_snapshot)
  end

  raise
rescue StandardError
  puts('CloudFormation update failed, rolling back SSM parameters...')
  restore_ssm_parameters(ssm_snapshot)
  raise
end

def fetch_asg_mixed_parameters(environment, subnet)
  ssm = Aws::SSM::Client.new
  response = ssm.get_parameters({ names: ["/#{environment}/#{subnet}/OnDemandPercentAbove", "/#{environment}/#{subnet}/OnDemandBaseCapacity"], with_decryption: true })
  result = {}
  response.parameters.each do |param|
    case param[:name]
    when "/#{environment}/#{subnet}/OnDemandPercentAbove" then result[:percent_above] = param.value.to_s
    when "/#{environment}/#{subnet}/OnDemandBaseCapacity" then result[:base_capacity] = param.value.to_s
    end
  end

  raise('Unable to load ASG mixed parameters: OnDemandPercentAbove') if result[:percent_above].nil?
  raise('Unable to load ASG mixed parameters: OnDemandBaseCapacity') if result[:base_capacity].nil?

  result
end

def extract_subnet_number(stack_name)
  digits = stack_name.split('-').first.scan(/\d+/).first
  raise("Unable to extract subnet number from stack name '#{stack_name}'") if digits.nil?

  Integer(digits, 10)
end

def update_asg_capacity(asg_client, asg_name, base_capacity:, percent_above:, desired_capacity: nil, max_size: nil)
  params = {
    auto_scaling_group_name: asg_name,
    mixed_instances_policy: {
      instances_distribution: {
        on_demand_base_capacity: base_capacity,
        on_demand_percentage_above_base_capacity: percent_above
      }
    }
  }
  params[:desired_capacity] = desired_capacity unless desired_capacity.nil?
  params[:max_size] = max_size unless max_size.nil?
  asg_client.update_auto_scaling_group(params)
end

def resolve_capacity_factors(options)
  asg_increase = options[:environment].start_with?('prod') ? 3 : 1
  asg_multiplier = 2

  if options[:preserve_desired_capacity]
    asg_increase = 0
    asg_multiplier = 1
  end

  { asg_increase: asg_increase, asg_multiplier: asg_multiplier }
end

def compute_asg_capacity_plan(asg, asg_increase:, asg_multiplier:)
  new_capacity = (asg[:desired_capacity] * asg_multiplier) + asg_increase
  new_max = asg[:max_size] < new_capacity ? (asg[:max_size] * asg_multiplier) + asg_increase : nil
  { new_capacity: new_capacity, new_max: new_max }
end

def resolve_ami_id(options)
  return options[:ami] if options[:ami]

  ec2 = Aws::EC2::Resource.new
  instance_id, instance_name = find_standalone_instance(ec2, options)
  create_ami(ec2, instance_id, instance_name, options)
end

def discover_cfn_stack_context(cfn, options)
  stack_name = find_cloudformation_stack(cfn, options)
  stacks_response = cfn.describe_stacks({ stack_name: stack_name }).stacks
  raise("Unable to describe stack #{stack_name}") if stacks_response.empty?

  environment = stack_name.split('-').first.tr('0-9', '')
  subnet = extract_subnet_number(stack_name)
  {
    stack_name: stack_name,
    parameters: stacks_response.first.parameters,
    environment: environment,
    subnet: subnet,
    prefix: parameter_prefix_for(options[:instance]),
    ssm_prefix: "/#{environment}/#{subnet}"
  }
end

def warm_up_after_scale_up(elb, target_group_arn, options)
  if load_balanced_instance?(options[:instance])
    sleep(WARMUP_SHORT) if options[:instance] == 'grpc'
    wait_for_healthy_instances(elb, target_group_arn)
  end

  puts('Waiting for cache/instances to warm up...')
  sleep(options[:instance] == 'grpc' ? WARMUP_LONG : WARMUP_SHORT)
end

def scale_down_after_deploy(asg_resources, asg, mixed_params, new_capacity, elb, target_group_arn, options)
  if options[:skip_scale_down]
    puts("Setting max_size to #{asg[:max_size]}...")
    update_asg_capacity(asg_resources.client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above], max_size: asg[:max_size])
    return
  end

  puts("Setting desired capacity from #{new_capacity} to #{asg[:desired_capacity]}...")
  update_asg_capacity(asg_resources.client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above], desired_capacity: asg[:desired_capacity], max_size: asg[:max_size])

  if load_balanced_instance?(options[:instance])
    sleep(POLL_INTERVAL)
    wait_for_healthy_instances(elb, target_group_arn)
  end

  puts('Waiting for auto scaling group to stop the instances...')
  wait_for_asg_instance_count(asg_resources.client, asg[:name], asg[:desired_capacity])
end

def run_rolling_deploy(asg_resources, asg, mixed_params, new_capacity, elb, target_group_arn, options)
  if new_capacity > asg[:desired_capacity]
    puts('Waiting for auto scaling group to start the instances...')
    wait_for_asg_instance_count(asg_resources.client, asg[:name], new_capacity)
    warm_up_after_scale_up(elb, target_group_arn, options)
  end

  scale_down_after_deploy(asg_resources, asg, mixed_params, new_capacity, elb, target_group_arn, options)
ensure
  puts('Restoring ASG mixed-instances policy...')
  update_asg_capacity(asg_resources.client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above])
end

def discover_load_balancer(options)
  return [nil, nil] unless load_balanced_instance?(options[:instance])

  elb = Aws::ElasticLoadBalancingV2::Client.new
  [elb, find_target_group(elb, options)]
end

def run_deployment(options)
  if options[:profile]
    puts("Setting profile '#{options[:profile]}'...")
    Aws.config.update({ profile: options[:profile] })
  end

  if options[:lambda_publish_version]
    publish_lambda_and_update_cloudfront(options)
    return
  end

  ami_id = resolve_ami_id(options)
  if options[:create_ami_only] && options[:ami].nil?
    puts('Exiting now as --create_ami_only was supplied.')
    return
  end

  factors = resolve_capacity_factors(options)
  asg_resources = Aws::AutoScaling::Resource.new
  asg = find_auto_scaling_group(asg_resources, options)
  elb, target_group_arn = discover_load_balancer(options)

  cfn = Aws::CloudFormation::Client.new
  ctx = discover_cfn_stack_context(cfn, options)

  ssm_snapshot = capture_ssm_snapshot(ctx[:parameters], ctx[:prefix], ami_id, asg, options, ctx[:ssm_prefix])
  update_ssm_parameters(ctx[:parameters], ctx[:prefix], ami_id, asg, options, ctx[:ssm_prefix])
  mark_cfn_secrets_for_previous_value!(ctx[:parameters])

  update_stack_with_ssm_rollback(cfn, ctx[:stack_name], ctx[:parameters], ctx[:prefix], ami_id, ssm_snapshot)

  mixed_params = fetch_asg_mixed_parameters(ctx[:environment], ctx[:subnet])
  plan = compute_asg_capacity_plan(asg, **factors)

  puts("Increasing desired capacity from #{asg[:desired_capacity]} to #{plan[:new_capacity]}...")
  update_asg_capacity(asg_resources.client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: 100, desired_capacity: plan[:new_capacity], max_size: plan[:new_max])

  run_rolling_deploy(asg_resources, asg, mixed_params, plan[:new_capacity], elb, target_group_arn, options)

  puts("Update completed successfully for Auto scaling group #{asg[:name]}.")
  puts('Deployment completed successfully.')
end

def parse_deploy_options(argv = ARGV)
  options = {}

  OptionParser.new do |opts|
    opts.banner = 'Usage: deploy.rb options'
    opts.separator('')
    opts.separator('options')
    opts.on('--ami ami', String)
    opts.on('--create_ami_only')
    opts.on('--environment environment', String)
    opts.on('--instance instance', String)
    opts.on('--type instance_type', String)
    opts.on('--lambda_publish_version function_name', String)
    opts.on('--profile profile', String)
    opts.on('--preserve_desired_capacity')
    opts.on('--skip_scale_down')
    opts.on('--spot_target_capacity spot_target_capacity', Integer)
    opts.on('-h', '--help') do
      puts(opts)
      exit(0)
    end
  end.parse!(argv, into: options)

  mandatory = %i[environment instance profile]
  missing = mandatory.select { |param| options[param].nil? }
  raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

  options
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    options = parse_deploy_options
    puts('Starting deployment...')
    run_deployment(options)
  rescue StandardError => e
    warn(e)
    warn(e.backtrace)
    exit(1)
  end
end
# :nocov:
