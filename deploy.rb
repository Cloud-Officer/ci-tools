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
require_relative 'lib/cli_main'

# Timing constants for polling and warmup periods
POLL_INTERVAL = 15      # Seconds between status checks
MAX_POLL_ATTEMPTS = 120 # Max polling attempts (30 minutes at 15-second intervals)
WARMUP = 60             # Warmup period after scale-up

# Instance types that use load balancer health checks
LOAD_BALANCED_INSTANCES = %w[api grpc].freeze

# ASG lifecycle states of instances on their way out
TERMINATING_STATES = %w[Terminating Terminating:Wait Terminating:Proceed Terminated].freeze

# CloudFormation stack statuses to query
ACTIVE_STACK_STATUSES = %w[CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE UPDATE_FAILED UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_COMPLETE IMPORT_ROLLBACK_IN_PROGRESS IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE].freeze

def log_timestamp
  Time.now.strftime('%Y-%m-%d %H:%M:%S')
end

def log_tag
  tag = Thread.current[:deploy_log_tag]
  tag.nil? ? '' : "[#{tag}] "
end

def log(message)
  puts("#{log_timestamp} #{log_tag}#{message}")
end

def log_warn(message)
  warn("#{log_timestamp} #{log_tag}#{message}")
end

def with_log_tag(tag)
  previous = Thread.current[:deploy_log_tag]
  Thread.current[:deploy_log_tag] = tag
  yield
ensure
  Thread.current[:deploy_log_tag] = previous
end

def instance_names(options)
  names = options[:instance].to_s.split(',').filter_map { |name| name.strip unless name.strip.empty? }
  names.uniq!
  names
end

def instance_options(options, name)
  options.merge(instance: name)
end

def map_instances(names)
  names.to_h { |name| [name, with_log_tag(names.one? ? nil : name) { yield(name) }] }
end

def capture_instance_outcome(name)
  with_log_tag(name) do
    { value: yield(name) }
  rescue StandardError => e
    log_warn("Failed: #{e.full_message}")
    { error: e }
  end
end

def join_quietly(thread)
  thread.join
rescue StandardError, SignalException
  nil
end

def collect_thread_outcomes(threads)
  threads.transform_values(&:value)
rescue SignalException
  threads.values.select(&:alive?).each { |thread| thread.raise(Interrupt) }
  threads.each_value { |thread| join_quietly(thread) }
  raise
end

def run_instances_in_parallel(names, &)
  threads =
    names.to_h do |name|
      thread =
        Thread.new do # rubocop:disable ThreadSafety/NewThread
          Thread.current.report_on_exception = false
          capture_instance_outcome(name, &)
        end
      [name, thread]
    end

  collect_thread_outcomes(threads)
end

def run_for_instances(names, parallel:, &)
  return run_instances_in_parallel(names, &) if parallel

  names.to_h { |name| [name, capture_instance_outcome(name, &)] }
end

def report_instance_outcomes(outcomes, label)
  outcomes.each do |name, outcome|
    if outcome.key?(:error)
      log_warn("#{label} for #{name}: FAILED - #{outcome[:error].message}")
    else
      log("#{label} for #{name}: OK")
    end
  end

  failed = outcomes.select { |_name, outcome| outcome.key?(:error) }
                   .keys
  raise("#{label} failed for: #{failed.join(', ')}") unless failed.empty?
end

def deploy_each(names, parallel:, label:, &)
  return { names.first => yield(names.first) } if names.one?

  outcomes = run_for_instances(names, parallel: parallel, &)
  report_instance_outcomes(outcomes, label)
  outcomes.transform_values { |outcome| outcome[:value] }
end

def load_balanced_instance?(instance)
  LOAD_BALANCED_INSTANCES.include?(instance)
end

def poll_until(description:, max_attempts: MAX_POLL_ATTEMPTS, interval: POLL_INTERVAL)
  attempts = 0
  loop do
    break if yield
    raise("Timed out #{description}") if (attempts += 1) >= max_attempts

    sleep(interval)
  end
end

def wait_for_healthy_instances(elb, target_group_arn)
  log('Waiting for all instances to be healthy...')
  poll_until(description: 'waiting for healthy instances') do
    descriptions = elb.describe_target_health({ target_group_arn: target_group_arn }).target_health_descriptions

    if descriptions.empty?
      log('No targets registered yet...')
      next false
    end

    unhealthy = descriptions.count { |h| h.target_health.state != 'healthy' }
    log("Waiting on #{unhealthy} unhealthy targets...")
    unhealthy.zero?
  end
end

def wait_for_asg_instance_count(asg_client, asg_name, target_count, direction:)
  raise(ArgumentError, "Invalid direction #{direction.inspect}, expected :up or :down") unless %i[up down].include?(direction)

  poll_until(description: "waiting for ASG #{asg_name} to reach #{target_count} instances") do
    response = asg_client.describe_auto_scaling_groups({ auto_scaling_group_names: [asg_name] }).auto_scaling_groups
    raise("Unable to describe ASG #{asg_name}") if response.empty?

    instances = response.first.instances
    count = direction == :up ? instances.count { |i| i.lifecycle_state == 'InService' } : instances.count { |i| !TERMINATING_STATES.include?(i.lifecycle_state) }
    log("Waiting on instances #{count}/#{target_count}...")
    direction == :up ? count >= target_count : count <= target_count
  end
end

def find_matching_distribution(cloudfront, environment)
  matches =
    cloudfront.list_distributions.flat_map do |page|
      page.distribution_list.items.select do |distribution|
        distribution.aliases.items.any? { |a| a == environment || a.start_with?("#{environment}.") }
      end
    end

  raise("Multiple cloudfront distributions match environment '#{environment}': #{matches.map(&:id).join(', ')}") if matches.length > 1

  matches.first
end

def viewer_request_association(associations)
  Array(associations.items).find { |item| item.event_type == 'viewer-request' }
end

def update_distribution_lambda(cloudfront, distribution, function_arn)
  current = viewer_request_association(distribution.default_cache_behavior.lambda_function_associations)
  return if current&.lambda_function_arn == function_arn

  log("Updating distribution #{distribution.id} lambda function associations to #{function_arn}...")
  config = cloudfront.get_distribution_config({ id: distribution.id })
  config_assoc = config.distribution_config.default_cache_behavior.lambda_function_associations
  target = viewer_request_association(config_assoc)

  if target
    target.lambda_function_arn = function_arn
  else
    config_assoc.items.push({ event_type: 'viewer-request', include_body: false, lambda_function_arn: function_arn })
    config_assoc.quantity += 1
  end

  cloudfront.update_distribution({ id: distribution.id, if_match: config.etag, distribution_config: config.distribution_config })
  log("Update completed successfully for distribution #{distribution.id} and lambda function associations to #{function_arn}.")
end

def publish_lambda_and_update_cloudfront(options)
  log("Publishing lambda version for function #{options[:lambda_publish_version]}...")
  lambda_client = Aws::Lambda::Client.new
  version = lambda_client.publish_version({ function_name: "#{options[:environment]}-#{options[:lambda_publish_version]}" })
  log("Publish completed successfully for function ARN = #{version.function_arn}.")
  log('Checking cloudfront distributions...')
  cloudfront = Aws::CloudFront::Client.new
  distribution = find_matching_distribution(cloudfront, options[:environment])
  raise('Unable to find cloudfront distribution') if distribution.nil?

  update_distribution_lambda(cloudfront, distribution, version.function_arn)
end

def environment_pattern(environment)
  escaped = Regexp.escape(environment)
  environment.match?(/\d\z/) ? escaped : "#{escaped}\\d*"
end

def single_match!(matches, description)
  raise("Unable to find #{description}") if matches.empty?
  raise("Multiple #{description}s match: #{matches.keys.join(', ')}") if matches.length > 1

  matches.first
end

def find_standalone_instance(ec2, options)
  log("Searching for #{options[:instance]} standalone instance...")
  pattern = /\A#{Regexp.escape(options[:instance])}-#{environment_pattern(options[:environment])}-standalone\z/
  matches = {}

  ec2.instances.each do |instance|
    next unless %w[running stopped].include?(instance.data.state.name)

    instance.tags.each { |tag| matches[tag.value] = instance.id if tag.key == 'Name' && tag.value.match?(pattern) }
  end

  name, instance_id = single_match!(matches, 'standalone instance')
  log("Standalone instance #{name} found with id #{instance_id}.")
  [instance_id, name]
end

def create_ami(ec2, instance_id, instance_name, options)
  ami = ec2.client.create_image({ instance_id: instance_id, name: instance_name.sub('standalone', Time.now.strftime('%Y-%m-%d-%H%M%S')) })
  log("Creating image #{ami.image_id}...")
  max_attempts = options[:instance] == 'worker' ? 1024 : 256
  begin
    Aws::EC2::Waiters::ImageAvailable.new({ client: ec2.client, max_attempts: max_attempts, delay: 30 }).wait({ filters: [{ name: 'image-id', values: [ami.image_id] }] })
  rescue Aws::Waiters::Errors::FailureStateError => e
    reason = e.response.images.first.state_reason&.message
    raise("Image #{ami.image_id} creation failed#{": #{reason}" unless reason.to_s.empty?}")
  end

  log("Image creation completed for #{ami.image_id}.")
  ami.image_id
end

def find_auto_scaling_group(asg_resources, stack_name, options)
  log('Checking auto scaling groups...')
  pattern = /\A#{Regexp.escape(stack_name)}-#{Regexp.escape(options[:instance])}-[^-]+\z/
  matches = asg_resources.groups.each_with_object({}) { |group, found| found[group.auto_scaling_group_name] = group if group.auto_scaling_group_name.match?(pattern) }
  name, group = single_match!(matches, 'auto scaling group')

  log("Auto scaling group #{name} found with desired capacity at #{group.desired_capacity}.")
  { name: name, desired_capacity: group.desired_capacity, min_size: group.min_size, max_size: group.max_size }
end

def find_target_group(elb, stack_name, options)
  ports = options[:instance] == 'grpc' ? ['8443-HTTP2'] : %w[80 443]
  names = ports.map { |port| "#{stack_name.split('-').first}-#{port}" }
  log('Checking load balancer target groups...')

  matches =
    elb.describe_target_groups.each_with_object({}) do |page, found|
      page.target_groups.each { |group| found[group.target_group_name] = group.target_group_arn if names.include?(group.target_group_name) }
    end

  single_match!(matches, 'load balancer target group').last
end

def find_cloudformation_stack(cfn, options)
  log('Checking cloudformation stacks...')
  pattern = /\A#{environment_pattern(options[:environment])}-StackInstances-[^-]+\z/

  matches =
    cfn.list_stacks({ stack_status_filter: ACTIVE_STACK_STATUSES }).each_with_object({}) do |page, found|
      page.stack_summaries.each { |stack| found[stack.stack_name] = stack.stack_status if stack.stack_name.match?(pattern) }
    end

  name, status = single_match!(matches, 'cloudformation stack')
  log("Stack #{name} found with status #{status}.")
  name
end

def parameter_prefix_for(instance)
  case instance
  when 'api', 'grpc' then instance.upcase
  else instance.capitalize
  end
end

DeployContext =
  Struct.new(:options, :asg, :ami_id, :stack) do
    def stack_name
      stack[:stack_name]
    end

    def parameters
      stack[:parameters]
    end

    def prefix
      stack[:prefix]
    end

    def ssm_prefix
      stack[:ssm_prefix]
    end
  end

RollingDeploy = Struct.new(:asg_client, :asg, :mixed_params, :elb, :target_group_arn, :options)

def resolve_parameter_value(key, deploy)
  case key
  when "#{deploy.prefix}ImageId" then deploy.ami_id
  when "#{deploy.prefix}MinSize" then deploy.asg[:min_size].to_s
  when "#{deploy.prefix}MaxSize" then deploy.asg[:max_size].to_s
  when "#{deploy.prefix}DesiredCapacity" then deploy.asg[:desired_capacity].to_s
  when "#{deploy.prefix}InstanceType" then deploy.options[:type]
  when 'SpotTargetCapacity' then deploy.options[:spot_target_capacity]&.to_s
  end
end

# Backstop only. The authoritative set of secret parameters is read from the
# template's NoEcho flags by fetch_no_echo_parameter_keys. Adding a name here is
# not how a new secret gets protected -- marking it NoEcho in the template is.
CFN_KNOWN_SECRET_PARAMETERS = %w[DbPassword MqPassword SendGridApiKey].freeze

def update_ssm_parameters(deploy)
  ssm = Aws::SSM::Client.new
  deploy.parameters.each do |parameter|
    replace_with = resolve_parameter_value(parameter.parameter_key, deploy)
    next if replace_with.nil?

    log("Updating SSM parameter '#{deploy.ssm_prefix}/#{parameter.parameter_key}' with value = '#{replace_with}'...")
    ssm.put_parameter({ name: "#{deploy.ssm_prefix}/#{parameter.parameter_key}", value: replace_with, type: 'String', overwrite: true })
  end
end

# describe_stacks reports every NoEcho parameter's value as "****". Sending that
# masked string back in update_stack overwrites the real secret with literal
# asterisks, so each one has to be resent with use_previous_value instead.
def fetch_no_echo_parameter_keys(cfn, stack_name)
  cfn.get_template_summary({ stack_name: stack_name }).parameters.filter_map do |parameter|
    parameter.parameter_key if parameter.no_echo
  end
end

CFN_MASKED_PARAMETER_VALUE = '****'

def mark_cfn_secrets_for_previous_value!(parameters, secret_keys)
  protected_keys = CFN_KNOWN_SECRET_PARAMETERS | secret_keys

  parameters.each do |parameter|
    next unless protected_keys.include?(parameter.parameter_key) || parameter.parameter_value == CFN_MASKED_PARAMETER_VALUE

    parameter.parameter_value = nil
    parameter.use_previous_value = true
  end
end

def capture_ssm_snapshot(deploy)
  names =
    deploy.parameters.filter_map do |parameter|
      next if resolve_parameter_value(parameter.parameter_key, deploy).nil?

      "#{deploy.ssm_prefix}/#{parameter.parameter_key}"
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
    log("Restoring SSM parameter '#{name}' to '#{value}'...")
    ssm.put_parameter({ name: name, value: value, type: 'String', overwrite: true })
  end
end

def wait_for_stack_update(cfn, stack_name)
  failure_states = %w[UPDATE_FAILED UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED]
  poll_until(description: "waiting for stack #{stack_name} to update") do
    response = cfn.describe_stacks({ stack_name: stack_name }).stacks
    raise("Unable to describe stack #{stack_name}") if response.empty?

    stack = response.first

    if failure_states.include?(stack.stack_status)
      message = "Stack #{stack_name} update failed with status #{stack.stack_status}"
      message += ": #{stack.stack_status_reason}" unless stack.stack_status_reason.to_s.empty?
      raise(message)
    end

    stack.stack_status == 'UPDATE_COMPLETE'
  end
end

def update_cloudformation_stack(cfn, deploys)
  stack_name = deploys.first.stack_name
  images = deploys.map { |deploy| "#{deploy.prefix}ImageId #{deploy.ami_id}" }
                  .join(', ')
  log("Updating cloudformation stack #{stack_name} with #{images}...")
  begin
    cfn.update_stack({ stack_name: stack_name, use_previous_template: true, parameters: deploys.first.parameters, capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND], disable_rollback: false })
  rescue Aws::CloudFormation::Errors::ValidationError => e
    raise unless e.message.include?('No updates are to be performed')

    log_warn("Stopping here: #{e.message}")
    return :no_updates
  end
  wait_for_stack_update(cfn, stack_name)
  log("Update completed successfully for cloudformation stack #{stack_name} with #{images}.")
  :updated
end

def update_ssm_parameters_with_rollback(deploys, ssm_snapshot)
  deploys.each { |deploy| update_ssm_parameters(deploy) }
rescue StandardError, SignalException
  log_warn('SSM parameter update failed, rolling back SSM parameters...')
  restore_ssm_parameters(ssm_snapshot)
  raise
end

def update_stack_with_ssm_rollback(cfn, deploys, ssm_snapshot)
  update_cloudformation_stack(cfn, deploys)
rescue StandardError, SignalException
  log_warn('CloudFormation update failed, rolling back SSM parameters...')
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

def discover_cfn_stack_context(cfn, options)
  stack_name = find_cloudformation_stack(cfn, options)
  stacks_response = cfn.describe_stacks({ stack_name: stack_name }).stacks
  raise("Unable to describe stack #{stack_name}") if stacks_response.empty?

  environment = stack_name.split('-').first.tr('0-9', '')
  subnet = extract_subnet_number(stack_name)
  {
    stack_name: stack_name,
    # Parameters is an optional member: the SDK returns nil for a stack that
    # declares none, and every consumer below iterates it.
    parameters: stacks_response.first.parameters || [],
    secret_parameter_keys: fetch_no_echo_parameter_keys(cfn, stack_name),
    environment: environment,
    subnet: subnet,
    prefix: parameter_prefix_for(options[:instance]),
    ssm_prefix: "/#{environment}/#{subnet}"
  }
end

def warm_up_after_scale_up(rollout)
  wait_for_healthy_instances(rollout.elb, rollout.target_group_arn) if load_balanced_instance?(rollout.options[:instance])

  log('Waiting for cache/instances to warm up...')
  sleep(WARMUP)
end

def scale_down_after_deploy(rollout, new_capacity)
  asg = rollout.asg
  mixed_params = rollout.mixed_params

  if rollout.options[:skip_scale_down]
    log("Setting max_size to #{asg[:max_size]}...")
    update_asg_capacity(rollout.asg_client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above], max_size: asg[:max_size])
    return
  end

  log("Setting desired capacity from #{new_capacity} to #{asg[:desired_capacity]}...")
  update_asg_capacity(rollout.asg_client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above], desired_capacity: asg[:desired_capacity], max_size: asg[:max_size])

  if load_balanced_instance?(rollout.options[:instance])
    sleep(POLL_INTERVAL)
    wait_for_healthy_instances(rollout.elb, rollout.target_group_arn)
  end

  log('Waiting for auto scaling group to stop the instances...')
  wait_for_asg_instance_count(rollout.asg_client, asg[:name], asg[:desired_capacity], direction: :down)
end

def run_rolling_deploy(rollout, new_capacity)
  if new_capacity > rollout.asg[:desired_capacity]
    log('Waiting for auto scaling group to start the instances...')
    wait_for_asg_instance_count(rollout.asg_client, rollout.asg[:name], new_capacity, direction: :up)
    warm_up_after_scale_up(rollout)
  end

  scale_down_after_deploy(rollout, new_capacity)
ensure
  log('Restoring ASG mixed-instances policy...')
  update_asg_capacity(rollout.asg_client, rollout.asg[:name], base_capacity: rollout.mixed_params[:base_capacity], percent_above: rollout.mixed_params[:percent_above])
end

def run_rolling_deploy_with_capacity_rollback(rollout, plan)
  run_rolling_deploy(rollout, plan[:new_capacity])
rescue StandardError, SignalException
  asg = rollout.asg
  log_warn("Rolling deploy failed, restoring desired capacity to #{asg[:desired_capacity]}...")
  begin
    update_asg_capacity(rollout.asg_client, asg[:name], base_capacity: rollout.mixed_params[:base_capacity], percent_above: rollout.mixed_params[:percent_above], desired_capacity: asg[:desired_capacity], max_size: plan[:new_max].nil? ? nil : asg[:max_size])
  rescue StandardError => e
    log_warn("WARNING: failed to restore auto scaling group capacity - #{asg[:name]} may still be scaled up")
    log_warn(e.full_message)
  end

  raise
end

def discover_load_balancer(stack_name, options)
  return [nil, nil] unless load_balanced_instance?(options[:instance])

  elb = Aws::ElasticLoadBalancingV2::Client.new
  [elb, find_target_group(elb, stack_name, options)]
end

def run_deployment(options)
  if options[:profile]
    log("Setting profile '#{options[:profile]}'...")
    Aws.config.update({ profile: options[:profile] })
  end

  if options[:lambda_publish_version]
    publish_lambda_and_update_cloudfront(options)
    return
  end

  names = instance_names(options)
  ami_only = options[:create_ami_only] && options[:ami].nil?
  ec2 = Aws::EC2::Resource.new if options[:ami].nil?
  standalones = options[:ami] ? {} : map_instances(names) { |name| find_standalone_instance(ec2, instance_options(options, name)) }
  targets = discover_deploy_targets(names, options) unless ami_only
  ami_ids = resolve_ami_ids(ec2, names, standalones, options)

  if ami_only
    log('Exiting now as --create_ami_only was supplied.')
    return
  end

  deploy_to_targets(targets, ami_ids, options)
end

def resolve_ami_ids(ec2, names, standalones, options)
  return names.to_h { |name| [name, options[:ami]] } if options[:ami]

  deploy_each(names, parallel: true, label: 'AMI creation') do |name|
    instance_id, instance_name = standalones[name]
    create_ami(ec2, instance_id, instance_name, instance_options(options, name))
  end
end

def discover_deploy_targets(names, options)
  cfn = Aws::CloudFormation::Client.new
  ctx = discover_cfn_stack_context(cfn, instance_options(options, names.first))
  asg_resources = Aws::AutoScaling::Resource.new

  instances =
    map_instances(names) do |name|
      per_instance = instance_options(options, name)
      asg = find_auto_scaling_group(asg_resources, ctx[:stack_name], per_instance)
      elb, target_group_arn = discover_load_balancer(ctx[:stack_name], per_instance)
      { options: per_instance, asg: asg, elb: elb, target_group_arn: target_group_arn }
    end

  { cfn: cfn, ctx: ctx, asg_resources: asg_resources, instances: instances }
end

def deploy_to_targets(targets, ami_ids, options)
  ctx = targets[:ctx]
  deploys = targets[:instances].to_h { |name, target| [name, DeployContext.new(options: target[:options], asg: target[:asg], ami_id: ami_ids[name], stack: ctx.merge(prefix: parameter_prefix_for(name)))] }

  ssm_snapshot = deploys.values.map { |deploy| capture_ssm_snapshot(deploy) }
                        .reduce({}, :merge)
  update_ssm_parameters_with_rollback(deploys.values, ssm_snapshot)
  mark_cfn_secrets_for_previous_value!(ctx[:parameters], ctx[:secret_parameter_keys])
  return if update_stack_with_ssm_rollback(targets[:cfn], deploys.values, ssm_snapshot) == :no_updates

  mixed_params = fetch_asg_mixed_parameters(ctx[:environment], ctx[:subnet])
  factors = resolve_capacity_factors(options)
  asg_client = targets[:asg_resources].client

  deploy_each(deploys.keys, parallel: !options[:sequential_rollout], label: 'Deployment') do |name|
    roll_out_instance(asg_client, deploys[name], targets[:instances][name], mixed_params, factors)
  end

  log('Deployment completed successfully.')
end

def roll_out_instance(asg_client, deploy, target, mixed_params, factors)
  asg = deploy.asg
  plan = compute_asg_capacity_plan(asg, **factors)

  log("Increasing desired capacity from #{asg[:desired_capacity]} to #{plan[:new_capacity]}...")
  update_asg_capacity(asg_client, asg[:name], base_capacity: mixed_params[:base_capacity], percent_above: 100, desired_capacity: plan[:new_capacity], max_size: plan[:new_max])

  rollout = RollingDeploy.new(asg_client: asg_client, asg: asg, mixed_params: mixed_params, elb: target[:elb], target_group_arn: target[:target_group_arn], options: deploy.options)
  run_rolling_deploy_with_capacity_rollback(rollout, plan)

  log("Update completed successfully for Auto scaling group #{asg[:name]}.")
end

def validate_instance_list!(options)
  names = instance_names(options)
  error =
    if names.empty?
      'missing argument: instance'
    elsif names.length > 1 && options[:ami]
      '--ami cannot be used with more than one instance'
    elsif names.length > 1 && options[:type]
      '--type cannot be used with more than one instance'
    end
  return if error.nil?

  warn(error)
  exit(1)
end

def parse_deploy_options(argv = ARGV)
  options =
    CliMain.parse_options!(mandatory: %i[environment instance profile], argv: argv) do |opts|
      opts.on('--ami ami', String)
      opts.on('--create_ami_only')
      opts.on('--environment environment', String)
      opts.on('--instance instance1,instance2', String)
      opts.on('--type instance_type', String)
      opts.on('--lambda_publish_version function_name', String)
      opts.on('--profile profile', String)
      opts.on('--preserve_desired_capacity')
      opts.on('--sequential_rollout')
      opts.on('--skip_scale_down')
      opts.on('--spot_target_capacity spot_target_capacity', Integer)
    end
  validate_instance_list!(options)
  options
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  CliMain.run! do
    options = parse_deploy_options
    log('Starting deployment...')
    run_deployment(options)
  end
end
# :nocov:
