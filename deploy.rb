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

def wait_for_healthy_instances(elb, target_group_arn)
  puts('Waiting for all instances to be healthy...')

  loop do
    unhealthy_targets = 0
    sleep(15)

    elb.describe_target_health({ target_group_arn: target_group_arn }).target_health_descriptions.each do |health_description|
      unhealthy_targets += 1 if health_description.target_health.state != 'healthy'
    end

    puts("Waiting on #{unhealthy_targets} unhealthy targets...")
    break if unhealthy_targets.zero?
  end
end

begin
  # parse command line options

  options = {}
  asg_increase = 1
  asg_multiplier = 2
  asg_max_size = 1
  asg_min_size = 1

  OptionParser.new do |opts|
    opts.banner = 'Usage: deploy.rb options'
    opts.separator('')
    opts.separator('options')

    opts.on('--ami ami', String)
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
  end.parse!(into: options)

  mandatory = %i[environment instance profile]
  missing = mandatory.select { |param| options[param].nil? }
  raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

  puts('Starting deployment...')

  if options[:profile]
    puts("Setting profile '#{options[:profile]}'...")
    Aws.config.update({ profile: options[:profile] })
  end

  if options[:lambda_publish_version]
    puts("Publishing lambda version for function #{options[:lambda_publish_version]}...")
    lambda = Aws::Lambda::Client.new
    version = lambda.publish_version({ function_name: "#{options[:environment]} - #{options[:lambda_publish_version]}" })
    puts("Publish completed successfully for function ARN = #{version.function_arn}.")

    puts('Checking cloudfront distributions...')
    cloudfront = Aws::CloudFront::Client.new
    distribution_id = nil

    cloudfront.list_distributions.distribution_list.items.each do |distribution|
      distribution.aliases.items.each do |distribution_alias|
        next unless distribution_alias.include?(options[:environment])

        distribution_id = distribution.id

        if distribution.default_cache_behavior.lambda_function_associations.quantity.zero? || distribution.default_cache_behavior.lambda_function_associations.items.first.lambda_function_arn != version.function_arn
          puts("Updating distribution #{distribution.id} lambda function associations to #{version.function_arn}...")
          get_distribution = cloudfront.get_distribution_config({ id: distribution.id })

          if get_distribution.distribution_config.default_cache_behavior.lambda_function_associations.quantity.zero?
            get_distribution.distribution_config.default_cache_behavior.lambda_function_associations.items.push(
              {
                event_type: 'viewer-request',
                include_body: false,
                lambda_function_arn: version.function_arn
              }
            )
            get_distribution.distribution_config.default_cache_behavior.lambda_function_associations.quantity = 1
          else
            get_distribution.distribution_config.default_cache_behavior.lambda_function_associations.items.first.lambda_function_arn = version.function_arn
          end

          cloudfront.update_distribution({ id: distribution.id, if_match: get_distribution.etag, distribution_config: get_distribution.distribution_config })
          puts("Update completed successfully for distribution #{distribution.id} and lambda function associations to #{version.function_arn}.")
        end

        break
      end
    end

    raise('Unable to find cloudfront distribution') if distribution_id.nil?

    exit
  end

  asg_increase = 3 if options[:environment].start_with?('prod')

  if options[:preserve_desired_capacity]
    asg_increase = 0
    asg_multiplier = 1
  end

  if options[:ami]
    ami_id = options[:ami]
  else
    # find standalone instance

    instance_id = nil
    instance_name = ''
    ec2 = Aws::EC2::Resource.new
    puts("Searching for #{options[:instance]} standalone instance...")
    instance_states = %w[running stopped]

    ec2.instances.each do |instance|
      next unless instance_states.include?(instance.data.state.name)

      instance.tags.each do |tag|
        next unless tag.key == 'Name'

        if tag.value[/#{options[:instance]}-#{options[:environment]}.*-standalone/]
          instance_id = instance.id
          instance_name = tag.value
        end
      end
    end

    raise('Unable to find standalone instance') if instance_id.nil?

    puts("Standalone instance #{instance_name} found with id #{instance_id}.")

    # create image

    ami = ec2.client.create_image(
      {
        instance_id: instance_id,
        name: instance_name.sub('standalone', Time.now.strftime('%Y-%m-%d-%H%M%S'))
      }
    )
    puts("Creating image #{ami.image_id}...")
    waiter = Aws::EC2::Waiters::ImageAvailable.new(
      {
        client: ec2.client,
        max_attempts: if options[:instance] == 'worker'
                        1024
                      else
                        256
                      end,
        delay: 30
      }
    )
    waiter.wait(
      {
        filters:
          [
            {
              name: 'image-id',
              values:
                [
                  ami.image_id
                ]
            },
            {
              name: 'state',
              values:
                [
                  'available'
                ]
            }
          ]
      }
    )
    ami_id = ami.image_id
    puts("Image creation completed for #{ami.image_id}.")
  end

  # find auto scaling group

  asg_resources = Aws::AutoScaling::Resource.new
  auto_scaling_group_name = ''
  desired_capacity = 1
  puts('Checking auto scaling groups...')

  asg_resources.groups.each do |group|
    next unless group.auto_scaling_group_name[/#{options[:environment]}.*-#{options[:instance]}.*/]

    puts("Auto scaling group #{group.auto_scaling_group_name} found with desired capacity at #{group.desired_capacity}.")
    auto_scaling_group_name = group.auto_scaling_group_name
    desired_capacity = group.desired_capacity
    asg_min_size = group.min_size
    asg_max_size = group.max_size
    break
  end

  raise('Unable to find auto scaling group') if auto_scaling_group_name.empty?

  if (options[:instance] == 'api') || (options[:instance] == 'grpc')
    # find load balancer target group

    elb = Aws::ElasticLoadBalancingV2::Client.new
    target_group_arn = nil

    port = '80'
    port = '8443-HTTP2' if options[:instance] == 'grpc'
    puts('Checking load balancer target groups...')

    elb.describe_target_groups.each do |targets|
      targets.target_groups.each do |group|
        target_group_arn = group.target_group_arn if group.target_group_name[/#{options[:environment]}\d*-#{port}$/]
      end
    end

    raise('Unable to find load balancer target group') if target_group_arn.nil?
  end

  # get asg parameters

  ondemand_percent_above = ondemand_base_capacity = nil
  ssm = Aws::SSM::Client.new
  asg_parameters = ssm.get_parameters(
    {
      names: [
        "/#{environment}/#{subnet}/OnDemandPercentAbove",
        "/#{environment}/#{subnet}/OnDemandBaseCapacity"
      ],
      with_decryption: true
    }
  )
  asg_parameters.parameters.each do |parameter|
    case parameter[:name]
    when "/#{environment}/#{subnet}/OnDemandPercentAbove"
      ondemand_percent_above = parameter.value.to_s
    when "/#{environment}/#{subnet}/OnDemandBaseCapacity"
      ondemand_base_capacity = parameter.value.to_s
    end
  end
  raise('Unable to load ASG mixed parameters: OnDemandPercentAbove') if ondemand_percent_above.nil?
  raise('Unable to load ASG mixed parameters: OnDemandBaseCapacity') if ondemand_base_capacity.nil?

  # check cloudformation stacks...

  puts('Checking cloudformation stacks...')
  cf = Aws::CloudFormation::Client.new
  stacks = cf.list_stacks(
    {
      stack_status_filter: %w[CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE UPDATE_FAILED UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_COMPLETE IMPORT_ROLLBACK_IN_PROGRESS IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE]
    }
  )

  stack_name = nil

  stacks.stack_summaries.each do |stack|
    next unless stack.stack_name[/#{options[:environment]}.*-StackInstances.*/]

    puts("Stack #{stack.stack_name} found with status #{stack.stack_status}.")
    stack_name = stack.stack_name
    break
  end

  raise('Unable to find cloudformation stack') if stack_name.nil?

  parameters = cf.describe_stacks(
    {
      stack_name: stack_name
    }
  ).stacks.first.parameters
  environment = stack_name.split('-').first.tr('0-9', '')
  subnet = Integer(stack_name.split('-').first.scan(/\d+/).first, 10)

  # set ssm parameters: ami, min_size, max_size, desired_capacity

  parameter_prefix =
    case options[:instance]
    when 'api', 'grpc'
      options[:instance].upcase
    else
      options[:instance].capitalize
    end
  ignored_parameters = %w[DbPassword MqPassword SendGridApiKey]

  parameters.each do |parameter|
    replace_with =
      case parameter.parameter_key
      when "#{parameter_prefix}ImageId"
        ami_id
      when "#{parameter_prefix}MinSize"
        asg_min_size.to_s
      when "#{parameter_prefix}MaxSize"
        asg_max_size.to_s
      when "#{parameter_prefix}DesiredCapacity"
        desired_capacity.to_s
      when "#{parameter_prefix}InstanceType"
        options[:type] # nil if not specified
      when 'SpotTargetCapacity'
        options[:spot_target_capacity]&.to_s # nil if not specified
      end

    unless replace_with.nil?
      puts("Updating SSM parameter '/#{environment}/#{subnet}/#{parameter.parameter_key}' with value = '#{replace_with}'...")
      ssm = Aws::SSM::Client.new
      ssm.put_parameter(
        {
          name: "/#{environment}/#{subnet}/#{parameter.parameter_key}",
          value: replace_with,
          type: 'String',
          overwrite: true
        }
      )
    end

    next unless ignored_parameters.include?(parameter.parameter_key)

    parameter.parameter_value = nil
    parameter.use_previous_value = true
  end

  puts("Updating cloudformation stack #{stack_name} with #{parameter_prefix}ImageId #{ami_id}...")

  begin
    cf.update_stack(
      {
        stack_name: stack_name,
        use_previous_template: true,
        parameters: parameters,
        capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND],
        disable_rollback: false
      }
    )
  rescue Aws::CloudFormation::Errors::ValidationError => e
    puts("Stopping here: #{e.message}")
    exit
  end

  # wait until stack has updated

  stack_states = %w[UPDATE_FAILED UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED]

  loop do
    sleep(15)
    stack = cf.describe_stacks(
      {
        stack_name: stack_name
      }
    ).stacks.first
    break if stack.stack_status == 'UPDATE_COMPLETE'
    raise('Stack update failed') if stack_states.include?(stack.stack_status)
  end

  puts("Update completed successfully for cloudformation stack #{stack_name} with #{parameter_prefix}ImageId #{ami_id}.")

  # set new launch configuration and increase desired capacity

  puts("Increasing desired capacity from #{desired_capacity} to #{(desired_capacity * asg_multiplier) + asg_increase}...")

  if asg_max_size >= (desired_capacity * asg_multiplier) + asg_increase
    asg_resources.client.update_auto_scaling_group(
      {
        auto_scaling_group_name: auto_scaling_group_name,
        desired_capacity: (desired_capacity * asg_multiplier) + asg_increase,
        mixed_instances_policy: {
          instances_distribution: {
            on_demand_base_capacity: ondemand_base_capacity,
            on_demand_percentage_above_base_capacity: 100
          }
        }
      }
    )
  else
    asg_resources.client.update_auto_scaling_group(
      {
        auto_scaling_group_name: auto_scaling_group_name,
        desired_capacity: (desired_capacity * asg_multiplier) + asg_increase,
        max_size: (asg_max_size * asg_multiplier) + asg_increase,
        mixed_instances_policy: {
          instances_distribution: {
            on_demand_base_capacity: ondemand_base_capacity,
            on_demand_percentage_above_base_capacity: 100
          }
        }
      }
    )
  end

  # wait for auto scaling group to start instances

  if ((desired_capacity * asg_multiplier) + asg_increase) > desired_capacity
    puts('Waiting for auto scaling group to start the instances...')

    loop do
      sleep(15)
      instances = asg_resources.client.describe_auto_scaling_groups({ auto_scaling_group_names: [auto_scaling_group_name] }).auto_scaling_groups.first.instances.count
      puts("Waiting on instances #{instances}/#{(desired_capacity * asg_multiplier) + asg_increase}...")
      break if instances == (desired_capacity * asg_multiplier) + asg_increase
    end

    if (options[:instance] == 'api') || (options[:instance] == 'grpc')
      sleep(60) if options[:instance] == 'grpc'
      wait_for_healthy_instances(elb, target_group_arn)
    end

    puts('Waiting for cache/instances to warm up...')

    if options[:instance] == 'grpc'
      sleep(180)
    else
      sleep(60)
    end
  end

  # set original desired capacity

  if options[:skip_scale_down]
    puts("Setting max_size to #{asg_max_size}...")
    asg_resources.client.update_auto_scaling_group(
      {
        auto_scaling_group_name: auto_scaling_group_name,
        max_size: asg_max_size,
        mixed_instances_policy: {
          instances_distribution: {
            on_demand_base_capacity: ondemand_base_capacity,
            on_demand_percentage_above_base_capacity: ondemand_percent_above
          }
        }
      }
    )
  else
    puts("Setting desired capacity from #{(desired_capacity * asg_multiplier) + asg_increase} to #{desired_capacity}...")
    asg_resources.client.update_auto_scaling_group(
      {
        auto_scaling_group_name: auto_scaling_group_name,
        desired_capacity: desired_capacity,
        max_size: asg_max_size,
        mixed_instances_policy: {
          instances_distribution: {
            on_demand_base_capacity: ondemand_base_capacity,
            on_demand_percentage_above_base_capacity: ondemand_percent_above
          }
        }
      }
    )

    if (options[:instance] == 'api') || (options[:instance] == 'grpc')
      sleep(15)
      wait_for_healthy_instances(elb, target_group_arn)
    end

    # wait for auto scaling group to stop instances

    puts('Waiting for auto scaling group to stop the instances...')

    loop do
      sleep(15)
      instances = asg_resources.client.describe_auto_scaling_groups({ auto_scaling_group_names: [auto_scaling_group_name] }).auto_scaling_groups.first.instances.count
      puts("Waiting on instances #{instances}/#{desired_capacity}...")
      break if instances == desired_capacity
    end
  end

  puts("Update completed successfully for Auto scaling group #{auto_scaling_group_name}.")

  puts('Deployment completed successfully.')
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
