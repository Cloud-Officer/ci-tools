#!/usr/bin/env ruby
#
# Original author: Yves Desgagne (Cloud Officer)
# Pre-flight checks, notifications and recovery: Tommy Lacroix (https://github.com/tlacroix)
# MIT License, see LICENSE
#
# https://docs.aws.amazon.com/sdk-for-ruby

# frozen_string_literal: true

require 'aws-sdk-autoscaling'
require 'aws-sdk-cloudformation'
require 'aws-sdk-cloudfront'
require 'aws-sdk-codedeploy'
require 'aws-sdk-core'
require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'
require 'aws-sdk-iam'
require 'aws-sdk-lambda'
require 'aws-sdk-ssm'
require 'json'
require 'open3'
require 'securerandom'
require 'shellwords'
require 'socket'
require 'uri'
require 'yaml'
require_relative 'lib/ami_job'
require_relative 'lib/ami_status_table'
require_relative 'lib/aws_sso'
require_relative 'lib/cli_main'
require_relative 'lib/deploy_errors'
require_relative 'lib/deploy_permissions'
require_relative 'lib/plugin_manager'
require_relative 'lib/plugins'
require_relative 'lib/run_log'
require_relative 'lib/tee_output'

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

READY_POLL_INTERVAL = 5
READY_MAX_POLL_ATTEMPTS = 720
SSM_POLL_INTERVAL = 2
SSM_MAX_POLL_ATTEMPTS = 60
SSM_PENDING_STATUSES = %w[Pending InProgress Delayed].freeze
ACTIVE_DEPLOYMENT_STATUSES = %w[Created Queued InProgress Baking Ready].freeze
YES_ANSWERS = %w[y yes].freeze
USER_DATA_TAG = 'UserDataCompleted'
CODEDEPLOY_LOG = '/opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log'
DEFAULT_LOG_MARKER = 'Validate service end.'

REFUSED_CREDENTIAL_CODES = %w[InvalidClientTokenId InvalidAccessKeyId SignatureDoesNotMatch AuthFailure UnrecognizedClientException IncompleteSignature InvalidSignatureException InvalidToken].freeze
EXPIRED_CREDENTIAL_CODES = %w[ExpiredToken ExpiredTokenException RequestExpired TokenRefreshRequired].freeze
PROFILE_ERRORS = [
  Aws::Errors::NoSuchProfileError,
  Aws::Errors::MissingCredentialsError,
  Aws::Errors::MissingRegionError,
  Aws::Errors::NoSourceProfileError,
  Aws::Errors::NoSourceCredentialsError,
  Aws::Errors::InvalidCredentialSourceError,
  Aws::Errors::InvalidProcessCredentialsPayload,
  Aws::Errors::InvalidSSOCredentials,
  Aws::Errors::InvalidSSOToken
].freeze

AWS_MAX_ATTEMPTS = 8
AWS_THROTTLING_CODES = %w[Throttling ThrottlingException RequestLimitExceeded TooManyRequestsException RequestThrottled].freeze
NETWORK_RETRY_TIMEOUT = 1800
NETWORK_RETRY_MAX_DELAY = 60
SSM_RESTORE_TIMEOUT = 300
AMI_POLL_INTERVAL = 10
AMI_MAX_POLL_ATTEMPTS = 768
WORKER_AMI_MAX_POLL_ATTEMPTS = 3072
AMI_RENDER_INTERVAL = 1
IMAGE_FAILURE_STATES = %w[failed error invalid deregistered].freeze
RESUME_FLAGS = %i[preserve_desired_capacity sequential_rollout skip_scale_down sms skip-lock skip-other-deploy-check skip-permission-check].freeze
CODEDEPLOY_POLL_INTERVAL = 10
CODEDEPLOY_TIMEOUT = 3600
CODEDEPLOY_LOOKBACK = 50
CODEDEPLOY_BATCH_SIZE = 25
DEPLOYMENT_FAILURE_STATUSES = %w[Failed Stopped].freeze
STACK_WAIT_TIMEOUT = 3600
RESIZE_TIMEOUT = 900
TAG_REMOVAL_CHECKS = 6
TAG_REMOVAL_INTERVAL = 5
RESET_PARAMETERS = %w[InstanceEnabled WorkerInstanceEnabled].freeze
NO_STACK_UPDATES = 'No updates are to be performed'
ASG_BASELINE_TAG = 'deploy-rb:rollout-baseline'
ASG_BASELINE_FORMAT = /\Adesired=(?<desired>\d+),max=(?<max>\d+)\z/
EC2_FILTER_VALUE_LIMIT = 200
HEALTHCHECK_TIMEOUT = 15
HEALTHCHECK_INTERVAL = 15
HEALTHCHECK_GIVE_UP_AFTER = 300
PLUGINS_FILE = 'plugins.yaml'
CURL_STATUS_FORMAT = ['%', '{http_code}'].join

class PreflightError < StandardError; end

EXIT_FAILED = 1
EXIT_ROLLED_BACK = 2
EXIT_NEEDS_HUMAN = 3
LOCK_PARAMETER_PREFIX = '/deploy-rb/locks'

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

def capture_instance_outcome(name, tagged: true)
  with_log_tag(tagged ? name : nil) do
    { value: yield(name) }
  rescue StandardError => e
    log_warn("Failed: #{e.full_message}")
    { error: e }
  end
end

def join_quietly(thread)
  thread.join
rescue StandardError, SignalException
  return unless thread.alive?

  log_warn('Still waiting for the interrupted AMI builds to clean up...')
  retry
end

def collect_thread_outcomes(threads)
  threads.transform_values(&:value)
rescue SignalException
  threads.values.select(&:alive?).each { |thread| thread.raise(Interrupt) }
  threads.each_value { |thread| join_quietly(thread) }
  raise
end

def start_thread
  Thread.new do # rubocop:disable ThreadSafety/NewThread
    Thread.current.report_on_exception = false
    yield
  end
end

def run_instances_in_parallel(names, &)
  threads = names.to_h { |name| [name, start_thread { capture_instance_outcome(name, tagged: !names.one?, &) }] }

  collect_thread_outcomes(threads)
end

def run_for_instances(names, parallel:, &)
  return run_instances_in_parallel(names, &) if parallel

  names.to_h { |name| [name, capture_instance_outcome(name, tagged: !names.one?, &)] }
end

def log_instance_outcomes(outcomes, label)
  outcomes.each do |name, outcome|
    if outcome.key?(:error)
      log_warn("#{label} for #{name}: FAILED - #{outcome[:error].message}")
    else
      log("#{label} for #{name}: OK")
    end
  end
end

def failed_instances(outcomes)
  outcomes.select { |_name, outcome| outcome.key?(:error) }
          .keys
end

def report_instance_outcomes(outcomes, label)
  log_instance_outcomes(outcomes, label)
  failed = failed_instances(outcomes)
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

def server_error_status?(status)
  !status.nil? && status >= 500
end

def transient_error?(error)
  case error
  when Seahorse::Client::NetworkingError, SocketError, Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError then true
  when Aws::Errors::ServiceError then AWS_THROTTLING_CODES.include?(error.code) || server_error_status?(error.context&.http_response&.status_code)
  else false
  end
end

def with_network_retries(description, deadline: Time.now + NETWORK_RETRY_TIMEOUT)
  attempt = 0

  begin
    yield
  rescue StandardError => e
    raise unless transient_error?(e) && Time.now < deadline

    delay = [5 * (2**attempt), NETWORK_RETRY_MAX_DELAY].min
    attempt += 1
    log_warn("Network problem #{description} (#{e.class}: #{e.message}), retrying in #{delay} s...")
    sleep(delay)
    retry
  end
end

def wait_for_healthy_instances(elb, target_group_arn)
  log('Waiting for all instances to be healthy...')
  poll_until(description: 'waiting for healthy instances') do
    descriptions = with_network_retries('reading target health') { elb.describe_target_health({ target_group_arn: target_group_arn }).target_health_descriptions }

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
    response = with_network_retries("describing ASG #{asg_name}") { asg_client.describe_auto_scaling_groups({ auto_scaling_group_names: [asg_name] }).auto_scaling_groups }
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

def create_image(client, instance_id, image_name)
  with_network_retries("creating image #{image_name}") do
    client.create_image({ instance_id: instance_id, name: image_name }).image_id
  rescue Aws::EC2::Errors::InvalidAMINameDuplicate
    images = client.describe_images({ owners: ['self'], filters: [{ name: 'name', values: [image_name] }] }).images
    images.first&.image_id || raise
  end
end

def weighted_progress(pairs)
  pairs = pairs.map { |percent, _size| [percent, 1] } if pairs.sum(&:last).zero?
  pairs.sum { |percent, size| percent * size } / pairs.sum(&:last)
end

def snapshot_progress(client, image)
  volumes = image.block_device_mappings.filter_map(&:ebs)
  snapshot_ids = volumes.filter_map(&:snapshot_id).grep(/\Asnap-/)
  return if snapshot_ids.empty?

  snapshots = client.describe_snapshots({ snapshot_ids: snapshot_ids }).flat_map(&:snapshots).to_h { |snapshot| [snapshot.snapshot_id, snapshot] }
  pairs =
    volumes.map do |volume|
      snapshot = snapshots[volume.snapshot_id]
      [Integer(snapshot&.progress.to_s.delete('%'), 10, exception: false) || 0, snapshot&.volume_size || volume.volume_size || 0]
    end
  "#{weighted_progress(pairs)}%"
rescue Aws::Errors::ServiceError => e
  raise if transient_error?(e)
end

def check_image_state(image)
  return unless IMAGE_FAILURE_STATES.include?(image.state)

  reason = image.state_reason&.message
  raise("Image #{image.image_id} creation failed#{": #{reason}" unless reason.to_s.empty?}")
end

def wait_for_image(client, ami_id, options)
  job = options[:ami_job]
  max_attempts = options[:instance] == 'worker' ? WORKER_AMI_MAX_POLL_ATTEMPTS : AMI_MAX_POLL_ATTEMPTS

  poll_until(description: "waiting for image #{ami_id}", max_attempts: max_attempts, interval: AMI_POLL_INTERVAL) do
    image = with_network_retries("waiting for image #{ami_id}") { client.describe_images({ image_ids: [ami_id] }).images.first }
    next false if image.nil?

    check_image_state(image)
    job&.update(state: image.state, progress: with_network_retries("reading the snapshots of #{ami_id}") { snapshot_progress(client, image) })
    image.state == 'available'
  rescue Aws::EC2::Errors::InvalidAMIIDNotFound
    false
  end
end

def create_ami(ec2, instance_id, instance_name, options)
  job = options[:ami_job]
  image_name = instance_name.sub('standalone', Time.now.strftime('%Y-%m-%d-%H%M%S'))
  ami_id = create_image(ec2.client, instance_id, image_name)
  job ? job.update(state: 'pending', ami_id: ami_id, name: image_name) : log("Creating image #{ami_id}...")
  wait_for_image(ec2.client, ami_id, options)
  log("Image creation completed for #{ami_id}.") unless job
  ami_id
end

def find_auto_scaling_group(asg_resources, stack_name, options)
  log('Checking auto scaling groups...')
  pattern = /\A#{Regexp.escape(stack_name)}-#{Regexp.escape(options[:instance])}-[^-]+\z/
  matches = asg_resources.groups.each_with_object({}) { |group, found| found[group.auto_scaling_group_name] = group if group.auto_scaling_group_name.match?(pattern) }
  name, group = single_match!(matches, 'auto scaling group')

  log("Auto scaling group #{name} found with desired capacity at #{group.desired_capacity}.")
  asg = { name: name, desired_capacity: group.desired_capacity, min_size: group.min_size, max_size: group.max_size }
  baseline = asg_baseline(group.data.tags, group.min_size)
  return asg if baseline.nil?

  log_warn("#{name} is still scaled up from an unfinished rollout: using its capacity from before it (desired #{baseline[:desired_capacity]}, max #{baseline[:max_size]}).")
  asg.merge(baseline)
end

def asg_baseline(tags, min_size)
  tag = Array(tags).find { |candidate| candidate.key == ASG_BASELINE_TAG }
  return if tag.nil?

  match = tag.value.to_s.match(ASG_BASELINE_FORMAT)
  desired = match && Integer(match[:desired], 10)
  max = match && Integer(match[:max], 10)
  raise(PreflightError, "Tag #{ASG_BASELINE_TAG} of #{tag.resource_id} is invalid: #{tag.value}") unless match && desired >= min_size && max >= desired

  { desired_capacity: desired, max_size: max }
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

RollingDeploy = Struct.new(:asg_client, :asg, :mixed_params, :elb, :target_group_arn, :options, :ami_id)

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
    with_network_retries("updating #{parameter.parameter_key}") { ssm.put_parameter({ name: "#{deploy.ssm_prefix}/#{parameter.parameter_key}", value: replace_with, type: 'String', overwrite: true }) }
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
  response = with_network_retries('reading the current SSM values') { ssm.get_parameters({ names: names, with_decryption: true }) }
  response.parameters.to_h { |p| [p.name, p.value] }
end

def aws_profile_arguments
  Aws.config[:profile] ? ['--profile', Aws.config[:profile]] : []
end

def print_ssm_restore_commands(ssm_snapshot)
  profile = aws_profile_arguments
  ssm_snapshot.each { |name, value| log_warn("  #{Shellwords.join(['aws', 'ssm', 'put-parameter', *profile, '--overwrite', '--type', 'String', '--name', name, '--value', value])}") }
end

def restore_ssm_parameters!(ssm_snapshot)
  return if ssm_snapshot.empty?

  ssm = Aws::SSM::Client.new
  deadline = Time.now + SSM_RESTORE_TIMEOUT

  ssm_snapshot.each do |name, value|
    log("Restoring SSM parameter '#{name}' to '#{value}'...")
    with_network_retries("restoring #{name}", deadline: deadline) { ssm.put_parameter({ name: name, value: value, type: 'String', overwrite: true }) }
  end
end

def restore_ssm_parameters(ssm_snapshot)
  restore_ssm_parameters!(ssm_snapshot)
rescue StandardError => e
  log_warn("Could not restore the SSM parameters (#{e.message}). Restore them by hand:")
  print_ssm_restore_commands(ssm_snapshot)
end

def latest_stack_event_id(cfn, stack_name)
  cfn.describe_stack_events({ stack_name: stack_name }).stack_events.first&.event_id
end

def new_stack_events(cfn, stack_name, last_event_id)
  events = []
  cfn.describe_stack_events({ stack_name: stack_name }).each_page do |page|
    page.stack_events.each do |event|
      return events.reverse if event.event_id == last_event_id

      events << event
    end
  end
  events.reverse
end

def log_stack_event(event)
  message = "Stack event: #{event.logical_resource_id} (#{event.resource_type}) #{event.resource_status}"
  message += ": #{event.resource_status_reason}" unless event.resource_status_reason.to_s.empty?
  log(message)
end

def wait_for_stack_update(cfn, stack_name, last_event_id = nil)
  failure_states = %w[UPDATE_FAILED UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED]
  poll_until(description: "waiting for stack #{stack_name} to update") do
    events = with_network_retries("reading the events of #{stack_name}") { new_stack_events(cfn, stack_name, last_event_id) }
    events.each { |event| log_stack_event(event) }
    last_event_id = events.last.event_id unless events.empty?

    response = with_network_retries("describing #{stack_name}") { cfn.describe_stacks({ stack_name: stack_name }).stacks }
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

def apply_stack_update(cfn, stack_name, parameters)
  last_event_id = with_network_retries("reading the events of #{stack_name}") { latest_stack_event_id(cfn, stack_name) }
  update = { stack_name: stack_name, use_previous_template: true, parameters: parameters, capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND], disable_rollback: false, client_request_token: "deploy-rb-#{SecureRandom.uuid}" }
  begin
    with_network_retries("starting the update of #{stack_name}") { cfn.update_stack(update) }
  rescue Aws::CloudFormation::Errors::ValidationError => e
    raise unless e.message.include?(NO_STACK_UPDATES)

    return :no_updates
  end
  wait_for_stack_update(cfn, stack_name, last_event_id)
  :updated
end

def update_cloudformation_stack(cfn, deploys)
  stack_name = deploys.first.stack_name
  images = deploys.map { |deploy| "#{deploy.prefix}ImageId #{deploy.ami_id}" }
                  .join(', ')
  log("Updating cloudformation stack #{stack_name} with #{images}...")
  result = apply_stack_update(cfn, stack_name, deploys.first.parameters)

  if result == :no_updates
    log_warn("Nothing to update in stack #{stack_name}: #{NO_STACK_UPDATES}.")
  else
    log("Update completed successfully for cloudformation stack #{stack_name} with #{images}.")
  end

  result
end

def update_ssm_parameters_with_rollback(deploys, ssm_snapshot)
  deploys.each { |deploy| update_ssm_parameters(deploy) }
rescue StandardError, SignalException
  log_warn('SSM parameter update failed, rolling back SSM parameters...')
  restore_ssm_parameters(ssm_snapshot)
  raise
end

def report_unknown_stack_outcome(stack_name, ssm_snapshot)
  log_warn("The update of #{stack_name} may still be running in AWS, so the SSM parameters keep their new values.")
  return if ssm_snapshot.empty?

  log_warn('If it fails or rolls back, restore them:')
  print_ssm_restore_commands(ssm_snapshot)
end

def with_stack_ssm_rollback(stack_name, ssm_snapshot)
  yield
rescue StandardError, SignalException => e
  if transient_error?(e)
    report_unknown_stack_outcome(stack_name, ssm_snapshot)
  else
    log_warn('CloudFormation update failed, rolling back SSM parameters...')
    restore_ssm_parameters(ssm_snapshot)
  end

  raise
end

def update_stack_with_ssm_rollback(cfn, deploys, ssm_snapshot)
  with_stack_ssm_rollback(deploys.first.stack_name, ssm_snapshot) { update_cloudformation_stack(cfn, deploys) }
end

def fetch_asg_mixed_parameters(environment, subnet)
  ssm = Aws::SSM::Client.new
  names = ["/#{environment}/#{subnet}/OnDemandPercentAbove", "/#{environment}/#{subnet}/OnDemandBaseCapacity"]
  response = with_network_retries('reading the ASG mixed parameters') { ssm.get_parameters({ names: names, with_decryption: true }) }
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
  with_network_retries("updating ASG #{asg_name}") { asg_client.update_auto_scaling_group(params) }
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
    stack_status: stacks_response.first.stack_status,
    # Parameters is an optional member: the SDK returns nil for a stack that
    # declares none, and every consumer below iterates it.
    parameters: stacks_response.first.parameters || [],
    secret_parameter_keys: fetch_no_echo_parameter_keys(cfn, stack_name),
    environment: environment,
    subnet: subnet,
    prefix: parameter_prefix_for(options[:instance].to_s),
    ssm_prefix: "/#{environment}/#{subnet}"
  }
end

def warm_up_after_scale_up(rollout)
  wait_for_healthy_instances(rollout.elb, rollout.target_group_arn) if load_balanced_instance?(rollout.options[:instance])

  log('Waiting for cache/instances to warm up...')
  sleep(WARMUP)
  check_new_instances(rollout)
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

def asg_baseline_tag(name)
  { resource_id: name, resource_type: 'auto-scaling-group', key: ASG_BASELINE_TAG }
end

def record_asg_baseline(asg_client, asg)
  tag = asg_baseline_tag(asg[:name]).merge(value: "desired=#{asg[:desired_capacity]},max=#{asg[:max_size]}", propagate_at_launch: false)
  with_network_retries("recording the capacity of #{asg[:name]}") { asg_client.create_or_update_tags({ tags: [tag] }) }
end

def clear_asg_baseline(asg_client, name)
  with_network_retries("clearing the rollout tag of #{name}") { asg_client.delete_tags({ tags: [asg_baseline_tag(name)] }) }
end

def print_scale_down_commands(rollout)
  asg = rollout.asg
  name = asg[:name]
  params = rollout.mixed_params
  policy = { InstancesDistribution: { OnDemandBaseCapacity: Integer(params[:base_capacity].to_s, 10), OnDemandPercentageAboveBaseCapacity: Integer(params[:percent_above].to_s, 10) } }
  log_warn("WARNING: #{name} stays scaled up and costs more until someone acts: its new instances were not seen healthy, so scaling down could end the healthy old ones and keep them.")
  log_warn('Rerun the deploy, or once the new instances are healthy (or to give up), scale it down by hand:')
  log_warn("  #{Shellwords.join(['aws', 'autoscaling', 'update-auto-scaling-group', *aws_profile_arguments, '--auto-scaling-group-name', name, '--desired-capacity', asg[:desired_capacity].to_s, '--max-size', asg[:max_size].to_s, '--mixed-instances-policy', JSON.generate(policy)])}")
  log_warn("  #{Shellwords.join(['aws', 'autoscaling', 'delete-tags', *aws_profile_arguments, '--tags', "ResourceId=#{name},ResourceType=auto-scaling-group,Key=#{ASG_BASELINE_TAG}"])}")
end

def scale_up_for_rollout(rollout, plan)
  asg = rollout.asg
  new_capacity = plan[:new_capacity]
  scaling_up = new_capacity > asg[:desired_capacity]
  record_asg_baseline(rollout.asg_client, asg) if scaling_up

  log("Increasing desired capacity from #{asg[:desired_capacity]} to #{new_capacity}...")
  update_asg_capacity(rollout.asg_client, asg[:name], base_capacity: rollout.mixed_params[:base_capacity], percent_above: 100, desired_capacity: new_capacity, max_size: plan[:new_max])
  return unless scaling_up

  log('Waiting for auto scaling group to start the instances...')
  wait_for_asg_instance_count(rollout.asg_client, asg[:name], new_capacity, direction: :up)
  warm_up_after_scale_up(rollout)
rescue StandardError, SignalException => e
  print_scale_down_commands(rollout) if rollout.options[:'skip-rollback'] || e.is_a?(SignalException)
  raise
end

def run_rolling_deploy(rollout, new_capacity)
  scale_down_after_deploy(rollout, new_capacity)
ensure
  log('Restoring ASG mixed-instances policy...')
  update_asg_capacity(rollout.asg_client, rollout.asg[:name], base_capacity: rollout.mixed_params[:base_capacity], percent_above: rollout.mixed_params[:percent_above])
end

def run_rolling_deploy_with_capacity_rollback(rollout, plan)
  run_rolling_deploy(rollout, plan[:new_capacity])
rescue StandardError, SignalException => e
  raise unless rollout.options[:'skip-rollback'] || e.is_a?(SignalException)

  asg = rollout.asg
  log_warn("Rolling deploy failed, restoring desired capacity to #{asg[:desired_capacity]}...")
  begin
    update_asg_capacity(rollout.asg_client, asg[:name], base_capacity: rollout.mixed_params[:base_capacity], percent_above: rollout.mixed_params[:percent_above], desired_capacity: asg[:desired_capacity], max_size: asg[:max_size])
    clear_asg_baseline(rollout.asg_client, asg[:name])
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

def dry_run?(options)
  options[:'dry-run'] == true
end

def stop_or_report(options, message)
  raise(PreflightError, message) unless dry_run?(options)

  log_warn("DRY RUN: a real run would stop here: #{message}")
end

def interactive?
  !@non_interactive && $stdin.tty?
end

def read_answer
  answer = $stdin.gets.to_s
  @run_log&.write(answer.end_with?("\n") ? answer : "#{answer}\n")
  answer.strip.downcase
end

def notify(event, **payload)
  @plugins&.emit(event, payload)
end

def confirm_or_abort(prompt, abort_message)
  print(prompt)
  raise(PreflightError, abort_message) unless YES_ANSWERS.include?(read_answer)
end

def credentials_problem(error)
  detail = error.message.lines.first.to_s.strip
  return "it is missing or incomplete in the AWS configuration (#{detail})" if PROFILE_ERRORS.any? { |kind| error.is_a?(kind) }
  return unless error.is_a?(Aws::Errors::ServiceError)
  return "its session has expired (#{detail})" if EXPIRED_CREDENTIAL_CODES.include?(error.code)

  "AWS refused its credentials (#{detail})" if REFUSED_CREDENTIAL_CODES.include?(error.code)
end

def check_credentials(options)
  AwsSso.with_sign_in(options[:profile]) { Aws::STS::Client.new.get_caller_identity.arn }
rescue AwsSso::SessionExpired => e
  raise(PreflightError, "Cannot use profile '#{options[:profile]}': #{e.message}.", cause: nil)
rescue *PROFILE_ERRORS, Aws::Errors::ServiceError => e
  problem = credentials_problem(e)
  raise if problem.nil?

  raise(PreflightError, "Cannot use profile '#{options[:profile]}': #{problem}.", cause: nil)
end

def confirm_unchecked_permissions(options, reason)
  log_warn("Could not check your permissions: #{reason}")
  return log_warn('DRY RUN: a real run would ask whether to continue, and stop without a terminal.') if dry_run?(options)

  raise(PreflightError, "Could not check your permissions (#{reason}): rerun with --skip-permission-check to go without.", cause: nil) unless interactive?

  notify(:question, kind: 'permissions_unchecked')
  confirm_or_abort('Continue without the permission check? [y/N] ', 'Permissions could not be checked, aborted.')
end

def report_missing_permissions(options, arn, needs, denied)
  missing =
    needs.transform_values { |actions| actions & denied }
         .reject { |_purpose, actions| actions.empty? }
  return log("#{arn} has the permissions this run needs.") if missing.empty?

  lines = missing.map { |purpose, actions| "  #{actions.join(', ')} (#{purpose})" }
  stop_or_report(options, "#{arn} is missing permissions:\n#{lines.join("\n")}\nA permission limited to some resources reads as missing: rerun with --skip-permission-check if this list is wrong.")
end

def check_permissions(options, caller_arn)
  return log('Not checking permissions (--skip-permission-check).') if options[:'skip-permission-check']

  names = instance_names(options)
  instance_checks = names.any? { |name| instance_healthcheck_command(instance_options(options, name)) }
  needs = DeployPermissions.required(options, load_balanced: names.any? { |name| load_balanced_instance?(name) }, building: requested_amis(options, names).value?(nil), instance_checks: instance_checks)
  log('Checking permissions...')
  iam = Aws::IAM::Client.new
  arn = DeployPermissions.simulation_arn(iam, caller_arn)
  return confirm_unchecked_permissions(options, "#{caller_arn} has no policies to simulate") if arn.nil?

  report_missing_permissions(options, arn, needs, DeployPermissions.denied(iam, arn, needs.values.reduce([], :|)))
rescue Aws::IAM::Errors::ServiceError => e
  confirm_unchecked_permissions(options, e.message)
end

def deploy_directory
  File.join(Dir.home, '.deploy')
end

def deploy_lock_name(options)
  "#{LOCK_PARAMETER_PREFIX}/#{options[:profile]}/#{options[:environment]}".gsub(%r{[^\w./-]}, '_')
end

def deploy_lock_holder(ssm, name)
  ssm.get_parameter({ name: name }).parameter.value
rescue Aws::SSM::Errors::ServiceError
  'unknown'
end

def acquire_deploy_lock(ssm, name, owner)
  with_network_retries("taking the deploy lock #{name}") { ssm.put_parameter({ name: name, value: owner, type: 'String', overwrite: false }) }
rescue Aws::SSM::Errors::ParameterAlreadyExists
  holder = deploy_lock_holder(ssm, name)
  return if holder == owner

  raise(PreflightError, "Another deploy is already running for #{name.delete_prefix("#{LOCK_PARAMETER_PREFIX}/")} (#{holder}): --skip-lock runs alongside it. If no deploy is running, delete the SSM parameter #{name}.")
end

def release_deploy_lock(ssm, name, owner)
  return log_warn("The deploy lock #{name} is no longer ours, leaving it.") unless deploy_lock_holder(ssm, name) == owner

  with_network_retries("releasing the deploy lock #{name}") { ssm.delete_parameter({ name: name }) }
rescue StandardError => e
  log_warn("Could not release the deploy lock (#{e.message}): delete the SSM parameter #{name} once no deploy is running.")
end

def hold_deploy_lock(options)
  ssm = Aws::SSM::Client.new
  name = deploy_lock_name(options)
  owner = "pid #{Process.pid} on #{Socket.gethostname}, started #{log_timestamp}"
  acquire_deploy_lock(ssm, name, owner)

  begin
    yield
  ensure
    release_deploy_lock(ssm, name, owner)
  end
end

def with_deploy_lock(options, &)
  return yield if dry_run?(options)

  if options[:'skip-lock']
    log('Not taking the deploy lock (--skip-lock).')
    return yield
  end

  hold_deploy_lock(options, &)
end

def deploy_config
  path = File.join(deploy_directory, 'config.yaml')
  return {} unless File.exist?(path)

  config = YAML.safe_load_file(path) || {}
  raise(PreflightError, "#{path} must be a mapping.") unless config.is_a?(Hash)

  config
rescue Psych::Exception => e
  raise(PreflightError, "#{path} is invalid: #{e.message}")
end

def log_marker_for(config, profile, instance)
  scope = [config.dig('profiles', profile, 'codedeploy', instance), config['codedeploy']].find { |candidate| candidate.is_a?(Hash) && candidate.key?('log_marker') }
  return DEFAULT_LOG_MARKER if scope.nil?

  scope['log_marker'] || nil
rescue TypeError
  raise(PreflightError, 'The profiles section of the deploy config is malformed.')
end

def deployment_instance_ids(codedeploy, deployment_id)
  codedeploy.list_deployment_instances({ deployment_id: deployment_id }).flat_map(&:instances_list)
rescue Aws::CodeDeploy::Errors::DeploymentNotStartedException
  []
end

def active_deployments(names, environment)
  codedeploy = Aws::CodeDeploy::Client.new
  group = codedeploy_group_for(environment)

  names.flat_map do |name|
    ids = codedeploy.list_deployments({ application_name: name, deployment_group_name: group, include_only_statuses: ACTIVE_DEPLOYMENT_STATUSES }).flat_map(&:deployments)
    ids.map { |id| { instance: name, id: id, targets: deployment_instance_ids(codedeploy, id) } }
  rescue Aws::CodeDeploy::Errors::ApplicationDoesNotExistException, Aws::CodeDeploy::Errors::DeploymentGroupDoesNotExistException
    []
  end
end

def pending_images(standalones)
  return [] if standalones.empty?

  filters = [{ name: 'source-instance-id', values: standalones.values.map(&:first) }, { name: 'state', values: ['pending'] }]
  Aws::EC2::Client.new.describe_images({ owners: ['self'], filters: filters }).images.map { |image| "#{image.image_id} (#{image.name})" }
end

def confirm_other_deploys(hints, options)
  return if hints.empty?

  hints.each { |hint| log_warn("WARNING: #{hint}") }
  return log_warn('DRY RUN: a real run would ask whether to continue, and stop without a terminal.') if dry_run?(options)

  raise(PreflightError, "Someone else may be deploying: #{hints.join('; ')}. Rerun with --skip-other-deploy-check to deploy anyway.") unless interactive?

  notify(:question, kind: 'other_deploy')
  confirm_or_abort('Someone else may be deploying. Continue anyway? [y/N] ', 'Someone else may be deploying, aborted.')
end

def check_for_other_deploys(names, standalones, targets, options)
  return log('Not checking for other deploys (--skip-other-deploy-check).') if options[:'skip-other-deploy-check']

  deployments = active_deployments(names, options[:environment])
  imaging, others = deployments.partition { |deployment| deployment[:targets].include?(standalones.dig(deployment[:instance], 0)) }
  unless imaging.empty?
    stop_or_report(
      options,
      "CodeDeploy is deploying to #{imaging.map { |deployment| "#{standalones[deployment[:instance]].last} (#{deployment[:id]})" }
.join(', ')}: wait for it before building the AMI."
    )
  end

  hints = others.map { |deployment| "CodeDeploy #{deployment[:id]} is running for #{deployment[:instance]}" }
  hints += pending_images(standalones).map { |image| "AMI #{image} is still being created" }
  stack = targets && targets[:ctx]
  hints << "stack #{stack[:stack_name]} is #{stack[:stack_status]}" if stack && stack[:stack_status].to_s.end_with?('_IN_PROGRESS')
  confirm_other_deploys(hints, options)
end

def describe_standalones(client, standalones)
  client.describe_instances({ instance_ids: standalones.values.map(&:first) }).flat_map(&:reservations).flat_map(&:instances).to_h { |instance| [instance.instance_id, instance] }
end

def running_standalones(client, standalones)
  states = describe_standalones(client, standalones).transform_values { |instance| instance.state.name }
  running, stopped = standalones.partition { |_name, (instance_id, _instance_name)| states[instance_id] == 'running' }
                                .map(&:to_h)
  stopped.each_value { |(_instance_id, instance_name)| log_warn("#{instance_name} is not running: skipping its readiness and CodeDeploy checks.") }
  running
end

def unready_standalones(client, standalones)
  filters = [{ name: 'resource-id', values: standalones.values.map(&:first) }, { name: 'key', values: [USER_DATA_TAG] }]
  tagged = client.describe_tags({ filters: filters }).flat_map { |page| page.tags.map(&:resource_id) }
  standalones.reject { |_name, (instance_id, _instance_name)| tagged.include?(instance_id) }
end

def wait_for_unready?(names)
  return true unless interactive?

  notify(:question, kind: 'standalones_not_ready', names: names)
  print("Wait for #{names.join(', ')}? [Y/n] ")
  answer = read_answer
  answer.empty? || YES_ANSWERS.include?(answer)
end

def wait_for_standalones(client, standalones, options)
  unready = unready_standalones(client, standalones)
  return if unready.empty?

  names = unready.values.map(&:last)
  log_warn("No #{USER_DATA_TAG} tag on #{names.join(', ')}: user data may still be running.")
  return log_warn('DRY RUN: a real run would ask whether to wait, and wait without a terminal.') if dry_run?(options)
  return log('Continuing without waiting.') unless options[:'reset-instances'] || wait_for_unready?(names)

  poll_until(description: "waiting for #{USER_DATA_TAG} on #{names.join(', ')}", max_attempts: READY_MAX_POLL_ATTEMPTS, interval: READY_POLL_INTERVAL) do
    unready = unready_standalones(client, unready)
    unready.empty?
  end
end

def codedeploy_check_commands(marker)
  commands = ["f=#{Shellwords.escape(CODEDEPLOY_LOG)}", 'test -f "$f" || { echo "$f does not exist"; exit 2; }', 'tail "$f"']
  marker ? commands + ["tail \"$f\" | grep -qF -- #{Shellwords.escape(marker)} || exit 3"] : commands
end

def wait_for_command_invocation(ssm, command_id, instance_id)
  invocation = nil

  poll_until(description: "waiting for SSM command #{command_id} on #{instance_id}", max_attempts: SSM_MAX_POLL_ATTEMPTS, interval: SSM_POLL_INTERVAL) do
    invocation = ssm.get_command_invocation({ command_id: command_id, instance_id: instance_id })
    !SSM_PENDING_STATUSES.include?(invocation.status)
  rescue Aws::SSM::Errors::InvocationDoesNotExist
    false
  end

  invocation
end

def codedeploy_failure_reason(invocation, marker)
  case invocation.response_code
  when 2 then "#{CODEDEPLOY_LOG} does not exist"
  when 3 then "no '#{marker}' in the last lines of the CodeDeploy log"
  else "SSM command #{invocation.status} (#{invocation.response_code}): #{invocation.standard_error_content}"
  end
end

def codedeploy_log_failures(ssm, marker, standalones)
  command = ssm.send_command({ instance_ids: standalones.values.map(&:first), document_name: 'AWS-RunShellScript', comment: 'deploy.rb: check CodeDeploy log before AMI', parameters: { commands: codedeploy_check_commands(marker) } })

  standalones.values.filter_map do |instance_id, instance_name|
    invocation = wait_for_command_invocation(ssm, command.command.command_id, instance_id)
    "#{instance_name}: #{codedeploy_failure_reason(invocation, marker)}" unless invocation.status == 'Success'
  end
rescue Aws::SSM::Errors::InvalidInstanceId => e
  standalones.values.map { |_instance_id, instance_name| "#{instance_name}: SSM cannot reach it (#{e.message})" }
end

def verify_codedeploy_logs(standalones, options)
  config = deploy_config
  ssm = Aws::SSM::Client.new
  by_marker = standalones.group_by { |name, _standalone| log_marker_for(config, options[:profile], name) }
  failures = by_marker.flat_map { |marker, group| codedeploy_log_failures(ssm, marker, group.to_h) }
  stop_or_report(options, "CodeDeploy check failed, no AMI created:\n#{failures.join("\n")}") unless failures.empty?
end

def check_standalones(standalones, options)
  return if standalones.empty?

  client = Aws::EC2::Client.new
  running = running_standalones(client, standalones)
  return if running.empty?

  wait_for_standalones(client, running, options)
  verify_codedeploy_logs(running, options) unless options[:'redeploy-latest']
end

def codedeploy_group_for(environment)
  environment.tr('0-9', '')
end

def name_tag(instance)
  instance.tags.find { |tag| tag.key == 'Name' }
          &.value.to_s
end

def ec2_filter_for(tag_filter)
  case tag_filter.type
  when 'KEY_ONLY' then { name: 'tag-key', values: [tag_filter.key] }
  when 'VALUE_ONLY' then { name: 'tag-value', values: [tag_filter.value] }
  else { name: "tag:#{tag_filter.key}", values: [tag_filter.value] }
  end
end

def instances_matching(client, tag_filters)
  state_filter = { name: 'instance-state-name', values: %w[pending running stopping stopped] }
  ids =
    tag_filters.flat_map do |tag_filter|
      instances = client.describe_instances({ filters: [ec2_filter_for(tag_filter), state_filter] }).flat_map(&:reservations).flat_map(&:instances)
      instances.map(&:instance_id)
    end
  ids.uniq
end

def target_tag_groups(info)
  tag_set = Array(info.ec2_tag_set&.ec2_tag_set_list).reject(&:empty?)
  tag_filters = info.ec2_tag_filters.to_a
  tag_filters.empty? ? tag_set : [tag_filters]
end

def deployment_group_targets(client, tag_groups)
  tag_groups.map { |tag_filters| instances_matching(client, tag_filters) }
            .reduce(:&).sort
end

def tag_matches_filter?(tag, filter)
  case filter.type
  when 'KEY_ONLY' then tag.key == filter.key
  when 'VALUE_ONLY' then File.fnmatch?(filter.value.to_s, tag.value.to_s)
  else tag.key == filter.key && File.fnmatch?(filter.value.to_s, tag.value.to_s)
  end
end

def extra_targets(client, instance_ids, tag_groups)
  filters = tag_groups.flatten
  instances = client.describe_instances({ instance_ids: instance_ids }).flat_map(&:reservations).flat_map(&:instances)

  instances.to_h do |instance|
    tags = instance.tags.select { |tag| filters.any? { |filter| tag_matches_filter?(tag, filter) } }
    [instance.instance_id, { name: name_tag(instance), tags: tags.map { |tag| { key: tag.key, value: tag.value } } }]
  end
end

def describe_extra_targets(extras)
  extras.map { |instance_id, extra| "#{extra[:name].empty? ? 'unnamed' : extra[:name]} (#{instance_id})" }
end

def describe_tags(tags)
  tags.map { |tag| "#{tag[:key]}=#{tag[:value]}" }
      .join(', ')
end

def read_extra_targets_choice(problem)
  print('Your choice? [1/2/3] (Enter cancels) ')

  case read_answer
  when '1' then :continue
  when '2' then :remove
  else raise(PreflightError, "#{problem}, aborted.")
  end
end

def confirm_extra_targets(problem, extras, options)
  log_warn("WARNING: #{problem}")

  if dry_run?(options)
    log_warn('DRY RUN: a real run would ask whether to continue, remove their CodeDeploy tags or cancel, and stop without a terminal.')
    return :continue
  end

  raise(PreflightError, problem) unless interactive?

  notify(:question, kind: 'extra_codedeploy_targets', group: problem[/\A\S+/])
  names = describe_extra_targets(extras).join(', ')
  log("  1) Continue: the redeploy also reaches #{names}")
  tags = extras.values.flat_map { |extra| extra[:tags] }
  tags.uniq!
  log("  2) Remove #{describe_tags(tags)} from #{names}, then continue")
  log('  3) Cancel')
  read_extra_targets_choice(problem)
end

def remove_codedeploy_tags(client, extras)
  extras.each do |instance_id, extra|
    raise(PreflightError, "No CodeDeploy tag to remove found on #{instance_id}.") if extra[:tags].empty?

    log("Removing #{describe_tags(extra[:tags])} from #{instance_id}...")
    with_network_retries("removing the CodeDeploy tags of #{instance_id}") { client.delete_tags({ resources: [instance_id], tags: extra[:tags] }) }
  end
end

def wait_for_only_target(client, tag_groups, instance_id, label)
  targets = []

  TAG_REMOVAL_CHECKS.times do
    targets = deployment_group_targets(client, tag_groups)
    return log("#{label} now targets only #{instance_id}.") if targets == [instance_id]

    sleep(TAG_REMOVAL_INTERVAL)
  end

  raise(PreflightError, "#{label} still targets #{targets.join(', ')} after removing the tags.")
end

def resolve_extra_targets(client, tag_groups, extra_ids, problem, options)
  extras = extra_targets(client, extra_ids, tag_groups)
  others = extras.values.map { |extra| extra[:name] }
  others = others.grep(/-standalone\z/)
  return stop_or_report(options, "#{problem}: #{others.join(', ')} is another environment's standalone instance") unless others.empty?

  confirm_extra_targets(problem, extras, options) == :remove ? extras : nil
end

def check_deployment_group_targets(clients, application, group, standalone, options)
  instance_id, name = standalone
  label = "#{application}/#{group}"
  info = clients[:codedeploy].get_deployment_group({ application_name: application, deployment_group_name: group }).deployment_group_info
  return stop_or_report(options, "#{label} targets auto scaling groups, not supported by --redeploy-latest") unless info.auto_scaling_groups.to_a.empty?

  tag_groups = target_tag_groups(info)
  return stop_or_report(options, "#{label} has no EC2 tag filters") if tag_groups.empty?

  targets = deployment_group_targets(clients[:ec2], tag_groups)
  return if targets == [instance_id]

  problem = "#{label} would deploy to #{targets.join(', ')}, expected only #{name} (#{instance_id})"
  return stop_or_report(options, problem) unless targets.include?(instance_id)

  to_clean = resolve_extra_targets(clients[:ec2], tag_groups, targets - [instance_id], problem, options)
  return if to_clean.nil?

  remove_codedeploy_tags(clients[:ec2], to_clean)
  wait_for_only_target(clients[:ec2], tag_groups, instance_id, label)
end

def fetch_deployments(codedeploy, ids)
  ids.each_slice(CODEDEPLOY_BATCH_SIZE).flat_map { |slice| codedeploy.batch_get_deployments({ deployment_ids: slice }).deployments_info }
end

def find_latest_successful_deployment(codedeploy, application, group, options)
  ids = codedeploy.list_deployments({ application_name: application, deployment_group_name: group, include_only_statuses: ['Succeeded'] }).deployments.first(CODEDEPLOY_LOOKBACK)
  latest = fetch_deployments(codedeploy, ids).select { |info| info.creator == 'user' }
                                             .max_by(&:create_time)
  return latest unless latest.nil?

  stop_or_report(options, "No successful user-triggered #{application}/#{group} deployment in the last #{CODEDEPLOY_LOOKBACK}")
end

def find_redeployment(clients, name, standalone, options)
  group = codedeploy_group_for(options[:environment])
  check_deployment_group_targets(clients, name, group, standalone, options)
  previous = find_latest_successful_deployment(clients[:codedeploy], name, group, options)
  log("Will redeploy #{previous.deployment_id} on #{standalone.last}.") if previous
  previous
rescue Aws::CodeDeploy::Errors::ApplicationDoesNotExistException, Aws::CodeDeploy::Errors::DeploymentGroupDoesNotExistException => e
  stop_or_report(options, "#{name}/#{group}: #{e.message}")
end

def find_redeployments(standalones, options)
  clients = { codedeploy: Aws::CodeDeploy::Client.new, ec2: Aws::EC2::Client.new }
  standalones.to_h { |name, standalone| [name, find_redeployment(clients, name, standalone, options)] }
             .compact
end

def standalone_environment(instance, standalone_name)
  standalone_name.delete_prefix("#{instance}-").delete_suffix('-standalone')
end

def environment_stacks(cfn, environment)
  summaries = with_network_retries("listing the #{environment} stacks") { cfn.list_stacks({ stack_status_filter: ACTIVE_STACK_STATUSES }).flat_map(&:stack_summaries) }
  pattern = /\A#{Regexp.escape(environment)}(-|\z)/
  summaries.select { |summary| summary.stack_name.match?(pattern) }
           .to_h { |summary| [summary.stack_name, summary.stack_status] }
end

def describe_stack_states(stacks)
  stacks.map { |name, status| "#{name} is #{status}" }
        .join(', ')
end

def failed_stacks(stacks)
  stacks.select { |_name, status| status.end_with?('FAILED') }
end

def wait_for_environment_stacks(environment)
  cfn = Aws::CloudFormation::Client.new
  deadline = Time.now + STACK_WAIT_TIMEOUT

  loop do
    stacks = environment_stacks(cfn, environment)
    failed = failed_stacks(stacks)
    raise("#{describe_stack_states(failed)}: fix it before CodeDeploy runs") unless failed.empty?

    busy = stacks.select { |_name, status| status.end_with?('IN_PROGRESS') }
    return if busy.empty?
    raise("Timed out waiting for #{describe_stack_states(busy)}") if Time.now > deadline

    yield(busy)
    sleep(POLL_INTERVAL)
  end
end

def check_environment_stacks(standalones, options)
  cfn = Aws::CloudFormation::Client.new
  environments = standalones.map { |name, standalone| standalone_environment(name, standalone.last) }
  environments.uniq!

  environments.each do |environment|
    failed = failed_stacks(environment_stacks(cfn, environment))
    stop_or_report(options, "#{describe_stack_states(failed)}: fix it before CodeDeploy runs") unless failed.empty?
  end
end

def find_started_deployment(codedeploy, deployment)
  window = { start: Time.now - 3600, end: Time.now + 300 }
  ids = codedeploy.list_deployments({ application_name: deployment[:application_name], deployment_group_name: deployment[:deployment_group_name], create_time_range: window }).deployments
  fetch_deployments(codedeploy, ids).find { |info| info.description == deployment[:description] }
                                    &.deployment_id
end

def start_deployment(codedeploy, deployment)
  with_network_retries("starting CodeDeploy for #{deployment[:application_name]}") do
    find_started_deployment(codedeploy, deployment) || codedeploy.create_deployment(deployment).deployment_id
  rescue Aws::CodeDeploy::Errors::ServiceError => e
    raise if transient_error?(e)

    find_started_deployment(codedeploy, deployment) || raise
  end
end

def wait_for_deployment(codedeploy, deployment_id)
  deadline = Time.now + CODEDEPLOY_TIMEOUT

  loop do
    info = with_network_retries("waiting for CodeDeploy #{deployment_id}", deadline: deadline) { codedeploy.get_deployment({ deployment_id: deployment_id }).deployment_info }
    return if info.status == 'Succeeded'
    raise("CodeDeploy #{deployment_id} is #{info.status}: #{info.error_information&.message}") if DEPLOYMENT_FAILURE_STATUSES.include?(info.status)
    raise("Timed out waiting for CodeDeploy #{deployment_id}") if Time.now > deadline

    sleep(CODEDEPLOY_POLL_INTERVAL)
  end
end

def redeploy_latest(standalone, job)
  previous = job.redeployment
  wait_for_environment_stacks(standalone_environment(job.instance, standalone.last)) { |busy| job.update(state: 'waiting', name: "for #{describe_stack_states(busy)}") }
  codedeploy = Aws::CodeDeploy::Client.new
  deployment = {
    application_name: previous.application_name,
    deployment_group_name: previous.deployment_group_name,
    revision: previous.revision.to_h,
    description: "deploy.rb --redeploy-latest: redeploy #{previous.deployment_id} (run #{SecureRandom.hex(6)})",
    file_exists_behavior: previous.file_exists_behavior
  }
  deployment_id = start_deployment(codedeploy, deployment.compact)
  job.update(state: 'deploying', name: deployment_id)
  wait_for_deployment(codedeploy, deployment_id)
end

def redeploy_and_check(standalone, job)
  redeploy_latest(standalone, job)
  job.update(state: 'checking', name: standalone.last)
  failures = codedeploy_log_failures(Aws::SSM::Client.new, job.log_marker, { job.instance => standalone })
  raise("CodeDeploy check failed: #{failures.join('; ')}") unless failures.empty?
end

def wait_for_instance_state(client, instance_id, wanted, deadline)
  loop do
    state = with_network_retries("waiting for #{instance_id}", deadline: deadline) { client.describe_instances({ instance_ids: [instance_id] }).reservations.first.instances.first.state.name }
    return if state == wanted
    raise("Timed out waiting for #{instance_id} to be #{wanted} (it is #{state})") if Time.now > deadline

    sleep(AMI_POLL_INTERVAL)
  end
end

def wait_for_ssm_online(instance_id, since, deadline)
  ssm = Aws::SSM::Client.new
  filters = [{ key: 'InstanceIds', values: [instance_id] }]

  loop do
    info = with_network_retries("waiting for #{instance_id} in SSM", deadline: deadline) { ssm.describe_instance_information({ filters: filters }).instance_information_list.first }
    return if info&.ping_status == 'Online' && info.last_ping_date_time && info.last_ping_date_time > since
    raise("Timed out waiting for #{instance_id} to be back online in SSM") if Time.now > deadline

    sleep(AMI_POLL_INTERVAL)
  end
end

def stop_instance(client, instance_id, deadline)
  with_network_retries("stopping #{instance_id}", deadline: deadline) { client.stop_instances({ instance_ids: [instance_id] }) }
rescue Aws::EC2::Errors::IncorrectInstanceState
  raise if Time.now > deadline

  sleep(AMI_POLL_INTERVAL)
  retry
end

def resize_instance(instance_id, type, start:)
  client = Aws::EC2::Client.new
  deadline = Time.now + RESIZE_TIMEOUT
  stop_instance(client, instance_id, deadline)
  wait_for_instance_state(client, instance_id, 'stopped', deadline)
  with_network_retries("resizing #{instance_id}", deadline: deadline) { client.modify_instance_attribute({ instance_id: instance_id, instance_type: { value: type } }) }
  return unless start

  started = Time.now
  deadline = started + RESIZE_TIMEOUT
  with_network_retries("starting #{instance_id}", deadline: deadline) { client.start_instances({ instance_ids: [instance_id] }) }
  wait_for_instance_state(client, instance_id, 'running', deadline)
  wait_for_ssm_online(instance_id, started, deadline)
end

def resize_standalone(standalone, job)
  instance_id, name = standalone
  job.update(state: 'resizing', name: "#{name} to #{job.resize[:to]}", resized: true)
  resize_instance(instance_id, job.resize[:to], start: true)
  job.update(name: name)
end

def manual_resize_commands(instance_id, resize)
  profile = aws_profile_arguments
  commands = [%w[aws ec2 stop-instances] + profile + ['--instance-ids', instance_id], %w[aws ec2 modify-instance-attribute] + profile + ['--instance-id', instance_id, '--instance-type', resize[:from]]]
  commands << (%w[aws ec2 start-instances] + profile + ['--instance-ids', instance_id]) if resize[:running]
  commands.map { |command| Shellwords.join(command) }
          .join('; ')
end

def restore_problem(standalone, resize)
  instance_id, name = standalone
  resize_instance(instance_id, resize[:from], start: resize[:running])
  nil
rescue StandardError => e
  problem = "Could not put #{name} back to #{resize[:from]} (#{e.message}). Restore it by hand: #{manual_resize_commands(instance_id, resize)}"
  log_warn(problem)
  problem
end

def restore_standalone_size(standalone, job)
  fields = job.snapshot
  return unless fields[:resized]

  job.update(state: 'restoring', name: "#{standalone.last} to #{job.resize[:from]}")
  problem = restore_problem(standalone, job.resize)
  outcome = problem ? { error: [fields[:error], problem].compact.join('; ') } : { resized: false }
  job.update(state: fields[:state], name: fields[:name], **outcome)
end

def plan_resize(name, current, type, architectures, options)
  return log("#{name} is already #{type}.") if current.instance_type == type
  return stop_or_report(options, "#{name} is #{current.architecture}, #{type} is #{architectures.join('/')}") unless architectures.include?(current.architecture)

  log("Will resize #{name} from #{current.instance_type} to #{type}, then back.")
  { from: current.instance_type, to: type, running: current.state.name == 'running' }
end

def plan_resizes(standalones, options)
  type = options[:resize]
  return {} if type.nil?

  client = Aws::EC2::Client.new
  architectures = client.describe_instance_types({ instance_types: [type] }).instance_types.first&.processor_info&.supported_architectures

  if architectures.nil?
    stop_or_report(options, "--resize #{type}: no such instance type")
    return {}
  end

  instances = describe_standalones(client, standalones)
  standalones.to_h { |name, (instance_id, standalone_name)| [name, plan_resize(standalone_name, instances[instance_id], type, architectures, options)] }
             .compact
rescue Aws::EC2::Errors::InvalidInstanceType => e
  stop_or_report(options, "--resize #{type}: #{e.message}")
  {}
end

def refuse_stopped_redeploys(standalones, resizes, options)
  candidates = standalones.except(*resizes.keys)
  return if candidates.empty?

  instances = describe_standalones(Aws::EC2::Client.new, candidates)
  stopped = candidates.values.reject { |instance_id, _name| instances[instance_id].state.name == 'running' }
  stop_or_report(options, "--redeploy-latest needs a running instance: start #{stopped.map(&:last).join(', ')}, or add --resize") unless stopped.empty?
end

def plan_redeployments(standalones, resizes, options)
  refuse_stopped_redeploys(standalones, resizes, options)
  check_environment_stacks(standalones, options)
  find_redeployments(standalones, options)
end

def plan_standalone_chores(standalones, options)
  return {} unless options[:resize] || options[:'redeploy-latest']
  return log_warn('--resize and --redeploy-latest only apply to the AMIs this run builds: nothing to do.') || {} if standalones.empty?

  resizes = plan_resizes(standalones, options)
  redeployments = options[:'redeploy-latest'] ? plan_redeployments(standalones, resizes, options) : {}
  config = deploy_config
  standalones.keys.to_h { |name| [name, { resize: resizes[name], redeployment: redeployments[name], log_marker: log_marker_for(config, options[:profile], name) }] }
end

def reset_context(cfn, options)
  ctx = discover_cfn_stack_context(cfn, options)
  missing = RESET_PARAMETERS - ctx[:parameters].map(&:parameter_key)
  stop_or_report(options, "#{ctx[:stack_name]} has no #{missing.join(', ')} parameter") unless missing.empty?
  ctx
end

def write_reset_parameters(names, value)
  ssm = Aws::SSM::Client.new
  response = with_network_retries('reading the current SSM values') { ssm.get_parameters({ names: names, with_decryption: true }) }
  snapshot = response.parameters.to_h { |parameter| [parameter.name, parameter.value] }
  missing = names - snapshot.keys
  raise(PreflightError, "Missing SSM parameters: #{missing.join(', ')}") unless missing.empty?

  names.each do |name|
    log("Updating SSM parameter '#{name}' with value = '#{value}'...")
    with_network_retries("updating #{name}") { ssm.put_parameter({ name: name, value: value, type: 'String', overwrite: true }) }
  end

  snapshot
rescue StandardError, SignalException
  restore_ssm_parameters(snapshot) if snapshot
  raise
end

def set_standalone_instances(options, value)
  cfn = Aws::CloudFormation::Client.new
  ctx = reset_context(cfn, options)
  stack_name = ctx[:stack_name]
  snapshot = write_reset_parameters(RESET_PARAMETERS.map { |key| "#{ctx[:ssm_prefix]}/#{key}" }, value)
  mark_cfn_secrets_for_previous_value!(ctx[:parameters], ctx[:secret_parameter_keys])
  log("Updating cloudformation stack #{stack_name} with #{RESET_PARAMETERS.join(' and ')} at #{value}...")
  result = with_stack_ssm_rollback(stack_name, snapshot) { apply_stack_update(cfn, stack_name, ctx[:parameters]) }
  log(result == :no_updates ? "Stack #{stack_name} already has them at #{value}." : "Update completed successfully for cloudformation stack #{stack_name}.")
end

def reset_standalone_instances(options)
  if dry_run?(options)
    reset_context(Aws::CloudFormation::Client.new, options)
    return log("DRY RUN: a real run would set #{RESET_PARAMETERS.join(' and ')} to 0, update the stack, then set them to 1 and update it again.")
  end

  notify(:reset_disabling)
  set_standalone_instances(options, '0')
  notify(:reset_disabled)

  begin
    notify(:reset_enabling)
    set_standalone_instances(options, '1')
  rescue StandardError, SignalException
    log_warn("The standalone instances may still be disabled: rerun with --reset-instances, or set #{RESET_PARAMETERS.join(' and ')} to 1 and update the stack.")
    raise
  end

  notify(:reset_done)
end

def build_deploys(targets, ami_ids, _options)
  ctx = targets[:ctx]
  targets[:instances].to_h { |name, target| [name, DeployContext.new(options: target[:options], asg: target[:asg], ami_id: ami_ids[name], stack: ctx.merge(prefix: parameter_prefix_for(name)))] }
end

def planned_ssm_values(deploys)
  deploys.each_with_object({}) do |deploy, planned|
    deploy.parameters.each do |parameter|
      value = resolve_parameter_value(parameter.parameter_key, deploy)
      planned["#{deploy.ssm_prefix}/#{parameter.parameter_key}"] = value unless value.nil?
    end
  end
end

def dry_run_build_step(standalone, chore)
  resize = chore[:resize]
  redeployment = chore[:redeployment]
  "  build an AMI of #{standalone.last}#{" resized to #{resize[:to]} (then back to #{resize[:from]})" if resize}#{" after redeploying #{redeployment.deployment_id}" if redeployment}"
end

def print_dry_run_plan(names, standalones, targets, options, chores = {})
  log('DRY RUN: nothing was changed. A real run would:')
  requested = requested_amis(options, names)
  names.each { |name| log(standalones[name] ? dry_run_build_step(standalones[name], chores.fetch(name, {})) : "  use #{requested[name]} for #{name}") }
  return if targets.nil?

  deploys = build_deploys(targets, names.to_h { |name| [name, requested[name] || "<new #{name} AMI>"] }, options).values
  current = deploys.map { |deploy| capture_ssm_snapshot(deploy) }
                   .reduce({}, :merge)
  planned_ssm_values(deploys).each { |name, value| log("  set #{name}: #{current.fetch(name, '(not set)')} -> #{value}") }
  log("  update stack #{targets[:ctx][:stack_name]}, then scale up and back down the #{names.join(', ')} groups that still have instances on a previous AMI")
end

def print_healthcheck_plan(healthchecks)
  return if healthchecks.nil? || healthchecks[:urls].empty?

  log(
    "  then check #{healthchecks[:urls].map { |url| redacted_url(url) }
.join(', ')}"
  )
end

def configure_aws_retries
  Aws.config.update({ retry_mode: 'standard', max_attempts: AWS_MAX_ATTEMPTS })
end

def run_deployment(options)
  if options[:profile]
    log("Setting profile '#{options[:profile]}'...")
    Aws.config.update({ profile: options[:profile] })
  end

  configure_aws_retries
  check_permissions(options, check_credentials(options))

  if options[:lambda_publish_version]
    return log("DRY RUN: a real run would publish lambda #{options[:environment]}-#{options[:lambda_publish_version]}.") if dry_run?(options)

    publish_lambda_and_update_cloudfront(options)
    notify(:lambda_published, function: options[:lambda_publish_version])
    return
  end

  with_deploy_lock(options) { deploy_instances(options) }
end

def parse_ami_list(value)
  value.split(',', -1).map { |ami| ami.strip.empty? || ami.strip.casecmp?('none') ? nil : ami.strip }
end

def requested_amis(options, names)
  amis = options[:ami] ? parse_ami_list(options[:ami]) : []
  names.each_with_index.to_h { |name, index| [name, amis[index]] }
end

def reset_before_deploy(names, options)
  return unless options[:'reset-instances']

  check_for_other_deploys(names, {}, nil, options) unless dry_run?(options)
  reset_standalone_instances(options)
end

def deploy_instances(options)
  names = instance_names(options)
  reset_before_deploy(names, options)
  return log('No instance to deploy.') if names.empty?

  to_build = names.select { |name| requested_amis(options, names)[name].nil? }
  ami_only = options[:create_ami_only] && !to_build.empty?
  ec2 = Aws::EC2::Resource.new unless to_build.empty?
  standalones = map_instances(to_build) { |name| find_standalone_instance(ec2, instance_options(options, name)) }
  targets = discover_deploy_targets(names, options) unless ami_only
  check_for_other_deploys(names, standalones, targets, options)
  check_standalones(standalones, options)
  chores = plan_standalone_chores(standalones, options)
  healthchecks = healthcheck_plan(options) unless ami_only
  names.each { |name| instance_healthcheck_command(instance_options(options, name)) } unless ami_only

  if dry_run?(options)
    print_dry_run_plan(names, standalones, targets, options, chores)
    return print_healthcheck_plan(healthchecks)
  end

  jobs = ami_jobs(names, standalones, options, chores)

  with_resume_command(names, jobs, options) do
    ami_ids = resolve_ami_ids(ec2, names, standalones, options, jobs)
    if ami_only
      notify(:amis_ready, jobs: job_summaries(jobs))
      next log('Exiting now as --create_ami_only was supplied.')
    end

    deploy_to_targets(targets, ami_ids, options, healthchecks)
    notify(:deploy_succeeded)
  end
end

def resume_command(names, ami_ids, options)
  selected = names.select { |name| ami_ids.key?(name) }
  args = [
    $PROGRAM_NAME,
    '--environment',
    options[:environment],
    '--profile',
    options[:profile],
    '--instance',
    selected.join(','),
    '--ami',
    selected.map { |name| ami_ids[name] }
            .join(',')
  ]
  args += ['--type', options[:type]] if options[:type]
  args += ['--spot_target_capacity', options[:spot_target_capacity].to_s] if options[:spot_target_capacity]
  args += RESUME_FLAGS.filter_map { |flag| "--#{flag}" if options[flag] }
  args += ['--disable-plugins', options[:'disable-plugins'].join(',')] if options[:'disable-plugins']
  Shellwords.join(args.compact)
end

def print_resume_command(names, jobs, options)
  built =
    jobs.select { |_name, job| job.available? }
        .transform_values { |job| job.snapshot[:ami_id] }
  return if built.empty?

  log_warn("To deploy the AMIs already built:\n  #{resume_command(names, requested_amis(options, names).compact.merge(built), options)}")
  pending = jobs.values.filter_map { |job| "#{job.instance} (#{job.snapshot[:ami_id]})" if job.pending? }
  log_warn("Still being created: #{pending.join(', ')}") unless pending.empty?
end

def with_resume_command(names, jobs, options)
  yield
rescue StandardError, SignalException
  print_resume_command(names, jobs, options)
  raise
end

def ami_jobs(names, standalones, options, chores = {})
  requested = requested_amis(options, names)
  names.select { |name| requested[name].nil? }
       .to_h { |name| [name, AmiJob.new(name, standalones[name].last, **chores.fetch(name, {}))] }
end

def with_ami_status_table(jobs)
  out = $stdout
  table = out.is_a?(TeeOutput) && out.tty? ? AmiStatusTable.new(jobs, out.console, @run_log) : AmiStatusTable.new(jobs, out)
  renderer =
    start_thread do
      loop do
        table.render
        Kernel.sleep(AMI_RENDER_INTERVAL)
      end
    end
  yield
ensure
  renderer&.kill&.join
  table&.render
end

def prepare_and_create_ami(ec2, standalone, options, job)
  resize_standalone(standalone, job) if job.resize
  redeploy_and_check(standalone, job) if job.redeployment
  instance_id, instance_name = standalone
  ami_id = create_ami(ec2, instance_id, instance_name, options.merge(ami_job: job))
  job.finish(ami_id)
  ami_id
end

def build_ami(ec2, standalone, options, job)
  Thread.handle_interrupt(Interrupt => :never) do
    Thread.handle_interrupt(Interrupt => :immediate) { prepare_and_create_ami(ec2, standalone, options, job) }
  rescue StandardError => e
    job.mark_failed(e.message)
    raise
  ensure
    restore_standalone_size(standalone, job)
  end
end

def confirm_partial_ami_failure(outcomes, supplied, options)
  log_instance_outcomes(outcomes, 'AMI creation')
  failed = failed_instances(outcomes)
  built = outcomes.except(*failed).transform_values { |outcome| outcome[:value] }
  return built if failed.empty?

  message = "AMI creation failed for: #{failed.join(', ')}"
  usable = supplied.keys + built.keys
  raise(message) if usable.empty? || options[:create_ami_only] || !interactive?

  notify(:question, kind: 'partial_ami_failure', failed: failed)
  print("Continue deploying #{usable.join(', ')} only? [y/N] ")
  raise(message) unless YES_ANSWERS.include?(read_answer)

  built
end

def job_summaries(jobs)
  jobs.map do |name, job|
    fields = job.snapshot
    { instance: name, ami_id: fields[:ami_id], state: fields[:state] }
  end
end

def resolve_ami_ids(ec2, names, standalones, options, jobs = ami_jobs(names, standalones, options))
  supplied = requested_amis(options, names).compact
  return supplied if jobs.empty?

  outcomes =
    with_ami_status_table(jobs.values) do
      run_for_instances(jobs.keys, parallel: true) { |name| build_ami(ec2, standalones[name], instance_options(options, name), jobs[name]) }
    end
  notify(:amis_done, jobs: job_summaries(jobs))
  ami_ids = supplied.merge(confirm_partial_ami_failure(outcomes, supplied, options))
  names.select { |name| ami_ids.key?(name) }
       .to_h { |name| [name, ami_ids[name]] }
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

def deploy_to_targets(targets, ami_ids, options, healthchecks = nil)
  ctx = targets[:ctx]
  targets = targets.merge(instances: targets[:instances].slice(*ami_ids.keys))
  deploys = build_deploys(targets, ami_ids, options)
  mixed_params = fetch_asg_mixed_parameters(ctx[:environment], ctx[:subnet])

  ssm_snapshot = deploys.values.map { |deploy| capture_ssm_snapshot(deploy) }
                        .reduce({}, :merge)
  update_ssm_parameters_with_rollback(deploys.values, ssm_snapshot)
  mark_cfn_secrets_for_previous_value!(ctx[:parameters], ctx[:secret_parameter_keys])
  notify(:stack_updated) if update_stack_or_escalate(targets[:cfn], deploys.values, ssm_snapshot) == :updated

  with_rollout_rollback(targets, deploys, ssm_snapshot, mixed_params, options) do
    roll_out_deploys(targets, deploys, mixed_params, options)
    run_healthchecks(healthchecks, strict: !options[:'skip-rollback'])
  end

  log('Deployment completed successfully.')
end

def update_stack_or_escalate(cfn, deploys, ssm_snapshot)
  update_stack_with_ssm_rollback(cfn, deploys, ssm_snapshot)
rescue StandardError => e
  raise unless transient_error?(e)

  raise(DeployErrors::NeedsHuman, "The update of #{deploys.first.stack_name} may still be running in AWS: #{e.message}")
end

def roll_out_deploys(targets, deploys, mixed_params, options)
  factors = resolve_capacity_factors(options)
  asg_client = targets[:asg_resources].client

  deploy_each(deploys.keys, parallel: !options[:sequential_rollout], label: 'Deployment') do |name|
    roll_out_instance(asg_client, deploys[name], targets[:instances][name], mixed_params, factors)
  end
end

def with_rollout_rollback(targets, deploys, ssm_snapshot, mixed_params, options)
  yield
rescue StandardError => e
  raise(DeployErrors::NeedsHuman, "#{e.message} (--skip-rollback: nothing was rolled back)") if options[:'skip-rollback']

  roll_back_after(e, targets, deploys, ssm_snapshot, mixed_params)
end

def roll_back_after(error, targets, deploys, ssm_snapshot, mixed_params)
  log_warn("Deploy failed: #{error.message}")
  notify(:rollback_started, error: error.message)

  begin
    roll_back_deploy(targets, deploys, ssm_snapshot, mixed_params)
  rescue StandardError => e
    notify(:rollback_failed, error: error.message, rollback_error: e.message)
    raise(DeployErrors::NeedsHuman, "Deploy failed (#{error.message}) and so did its rollback (#{e.message}): check the stack and its auto scaling groups.")
  end

  notify(:rollback_done, error: error.message)
  raise(DeployErrors::RolledBack, "Deploy failed and was rolled back to the previous AMIs: #{error.message}")
end

def roll_back_deploy(targets, deploys, ssm_snapshot, mixed_params)
  stack_name = deploys.values.first.stack_name
  log_warn("Rolling #{stack_name} back to the previous AMIs...")
  restore_ssm_parameters!(ssm_snapshot)
  apply_stack_update(targets[:cfn], stack_name, targets[:ctx][:parameters])
  asg_client = targets[:asg_resources].client

  deploy_each(deploys.keys, parallel: true, label: 'Rollback') do |name|
    roll_back_instance(asg_client, deploys[name], targets[:instances][name], mixed_params)
  end
end

def roll_back_instance(asg_client, deploy, target, mixed_params)
  asg = deploy.asg
  name = asg[:name]
  rollout = RollingDeploy.new(asg_client: asg_client, asg: asg, mixed_params: mixed_params, elb: target[:elb], target_group_arn: target[:target_group_arn], options: deploy.options, ami_id: deploy.ami_id)
  group = describe_asg(asg_client, name)
  failed = instance_ids_on(group, deploy.ami_id)
  replace_failed_instances(rollout, group, failed) unless failed.empty?

  log("Setting #{name} back to #{asg[:desired_capacity]} instance(s)...")
  update_asg_capacity(asg_client, name, base_capacity: mixed_params[:base_capacity], percent_above: mixed_params[:percent_above], desired_capacity: asg[:desired_capacity], max_size: asg[:max_size])
  wait_for_asg_instance_count(asg_client, name, asg[:desired_capacity], direction: :down)
  wait_for_healthy_instances(target[:elb], target[:target_group_arn]) if load_balanced_instance?(deploy.options[:instance])
  clear_asg_baseline(asg_client, name)
  log("Rolled back auto scaling group #{name}.")
end

def replace_failed_instances(rollout, group, failed)
  name = rollout.asg[:name]
  capacity = group.desired_capacity + failed.size
  log_warn("Replacing the #{failed.size} instance(s) of #{name} on #{rollout.ami_id}: #{failed.join(', ')}...")
  update_asg_capacity(rollout.asg_client, name, base_capacity: rollout.mixed_params[:base_capacity], percent_above: 100, desired_capacity: capacity, max_size: [group.max_size, capacity].max)
  wait_for_replacements(rollout, failed, [rollout.asg[:desired_capacity], group.desired_capacity].min)
  failed.each { |instance_id| terminate_failed_instance(rollout.asg_client, instance_id) }
end

def healthy_target_ids(elb, target_group_arn)
  descriptions = with_network_retries('reading target health') { elb.describe_target_health({ target_group_arn: target_group_arn }).target_health_descriptions }
  descriptions.filter_map { |description| description.target.id if description.target_health.state == 'healthy' }
end

def wait_for_replacements(rollout, failed, wanted)
  name = rollout.asg[:name]

  poll_until(description: "waiting for #{wanted} healthy instance(s) of #{name} on the previous AMI") do
    group = describe_asg(rollout.asg_client, name)
    ready = in_service_ids(group) - failed
    ready &= healthy_target_ids(rollout.elb, rollout.target_group_arn) if load_balanced_instance?(rollout.options[:instance])
    log("Waiting on replacement instances #{ready.size}/#{wanted}...")
    ready.size >= wanted
  end
end

def terminate_failed_instance(asg_client, instance_id)
  log("Terminating #{instance_id}...")
  with_network_retries("terminating #{instance_id}") { asg_client.terminate_instance_in_auto_scaling_group({ instance_id: instance_id, should_decrement_desired_capacity: true }) }
rescue Aws::AutoScaling::Errors::ValidationError => e
  log_warn("Could not terminate #{instance_id}: #{e.message}")
end

def instance_healthcheck_command(options)
  command = deploy_config.dig('profiles', options[:profile], 'instance_healthchecks', options[:instance])
  return if command.nil?
  return command if command.is_a?(String) && !command.strip.empty?

  raise(PreflightError, "The instance health check of #{options[:profile]}/#{options[:instance]} must be a shell command.")
rescue TypeError
  raise(PreflightError, 'The profiles section of the deploy config is malformed.')
end

def instance_healthcheck_failures(ssm, instance_ids, command)
  sent = with_network_retries('sending the instance health check') { ssm.send_command({ instance_ids: instance_ids, document_name: 'AWS-RunShellScript', comment: 'deploy.rb: health check of the new instances', parameters: { commands: [command] } }) }

  instance_ids.filter_map do |instance_id|
    invocation = wait_for_command_invocation(ssm, sent.command.command_id, instance_id)
    "#{instance_id}: #{invocation.status} (#{invocation.response_code}) #{invocation.standard_error_content.to_s.strip}".strip unless invocation.status == 'Success'
  end
rescue Aws::SSM::Errors::InvalidInstanceId => e
  instance_ids.map { |instance_id| "#{instance_id}: SSM cannot reach it (#{e.message})" }
end

def check_new_instances(rollout)
  command = instance_healthcheck_command(rollout.options)
  return if command.nil?

  name = rollout.asg[:name]
  group = describe_asg(rollout.asg_client, name)
  instance_ids = instance_ids_on(group, rollout.ami_id) & in_service_ids(group)
  raise("No instance of #{name} runs #{rollout.ami_id} to health check.") if instance_ids.empty?

  plan = healthcheck_plan(rollout.options)
  run_instance_healthcheck(Aws::SSM::Client.new, name, instance_ids, command, plan)
end

def run_instance_healthcheck(ssm, name, instance_ids, command, plan)
  deadline = Time.now + plan[:give_up_after]
  log("Running the instance health check on #{instance_ids.join(', ')}...")

  loop do
    failures = instance_healthcheck_failures(ssm, instance_ids, command)
    return log("Instance health check OK on #{name}.") if failures.empty?
    raise("Instance health check failed on #{name}: #{failures.join('; ')}") if Time.now >= deadline

    log_warn("Instance health check failing on #{name}: #{failures.join('; ')}, retrying in #{plan[:interval]} s...")
    sleep(plan[:interval])
  end
end

def describe_asg(asg_client, name)
  groups = with_network_retries("describing ASG #{name}") { asg_client.describe_auto_scaling_groups({ auto_scaling_group_names: [name] }).auto_scaling_groups }
  raise("Unable to describe ASG #{name}") if groups.empty?

  groups.first
end

def instance_images(group)
  client = Aws::EC2::Client.new
  active = group.instances.reject { |instance| TERMINATING_STATES.include?(instance.lifecycle_state) }
  instances =
    active.map(&:instance_id).each_slice(EC2_FILTER_VALUE_LIMIT).flat_map do |ids|
      with_network_retries("reading the AMIs of #{group.auto_scaling_group_name}") { client.describe_instances({ filters: [{ name: 'instance-id', values: ids }] }).flat_map(&:reservations).flat_map(&:instances) }
    end
  instances.to_h { |instance| [instance.instance_id, instance.image_id] }
end

def stale_instance_ids(group, ami_id)
  instance_images(group).reject { |_id, image| image == ami_id }
                        .keys
end

def in_service_ids(group)
  group.instances.filter_map { |instance| instance.instance_id if instance.lifecycle_state == 'InService' }
end

def instance_ids_on(group, ami_id)
  instance_images(group).select { |_id, image| image == ami_id }
                        .keys
end

def rollout_capacity_plan(asg, group, stale, factors)
  plan = compute_asg_capacity_plan(asg, **factors)
  return plan if factors[:asg_multiplier] == 1

  capacity = [plan[:new_capacity], stale.size + asg[:desired_capacity] + factors[:asg_increase], group.desired_capacity].max
  { new_capacity: capacity, new_max: asg[:max_size] < capacity ? [plan[:new_max], capacity].compact.max : nil }
end

def plan_instance_rollout(asg_client, deploy, factors)
  asg = deploy.asg
  name = asg[:name]
  group = describe_asg(asg_client, name)
  stale = stale_instance_ids(group, deploy.ami_id)
  unfinished = !asg_baseline(group.tags, group.min_size).nil?

  if stale.empty?
    log("Every instance of #{name} runs #{deploy.ami_id}.")
    return unfinished ? { new_capacity: asg[:desired_capacity], new_max: nil } : nil
  end

  log("#{name} still has #{stale.size} instance(s) on a previous AMI: #{stale.join(', ')}.")
  rollout_capacity_plan(asg, group, stale, factors)
end

def warn_about_stale_instances(asg_client, deploy)
  name = deploy.asg[:name]
  stale = stale_instance_ids(describe_asg(asg_client, name), deploy.ami_id)
  log_warn("WARNING: #{name} still has #{stale.size} instance(s) on a previous AMI after the scale-down: #{stale.join(', ')}.") unless stale.empty?
end

def roll_out_instance(asg_client, deploy, target, mixed_params, factors)
  asg = deploy.asg
  plan = plan_instance_rollout(asg_client, deploy, factors)
  return if plan.nil?

  rollout = RollingDeploy.new(asg_client: asg_client, asg: asg, mixed_params: mixed_params, elb: target[:elb], target_group_arn: target[:target_group_arn], options: deploy.options, ami_id: deploy.ami_id)
  groups = [{ name: asg[:name], from: asg[:desired_capacity], to: plan[:new_capacity] }]
  notify(:rollout_started, groups: groups)
  scale_up_for_rollout(rollout, plan)
  run_rolling_deploy_with_capacity_rollback(rollout, plan)
  clear_asg_baseline(asg_client, asg[:name])
  warn_about_stale_instances(asg_client, deploy) unless deploy.options[:skip_scale_down]
  notify(:rollout_done, groups: groups)

  log("Update completed successfully for Auto scaling group #{asg[:name]}.")
end

def healthcheck_urls(config, options)
  by_environment = config.dig('profiles', options[:profile], 'healthchecks') || {}
  environment = options[:environment]
  urls = by_environment[environment] || by_environment[environment.tr('0-9', '')] || []
  raise(PreflightError, "The health checks of #{options[:profile]}/#{environment} must be a list of URLs.") unless urls.is_a?(Array) && urls.all?(String)

  urls
rescue TypeError
  raise(PreflightError, 'The profiles section of the deploy config is malformed.')
end

def healthcheck_setting(retries, key, default, minimum)
  value = retries.fetch(key, default)
  raise(PreflightError, "healthcheck_retries.#{key} must be a whole number of seconds, at least #{minimum}.") unless value.is_a?(Integer) && value >= minimum

  value
end

def healthcheck_plan(options)
  config = deploy_config
  retries = config['healthcheck_retries'] || {}
  raise(PreflightError, 'healthcheck_retries must be a mapping.') unless retries.is_a?(Hash)

  { urls: healthcheck_urls(config, options), interval: healthcheck_setting(retries, 'interval', HEALTHCHECK_INTERVAL, 1), give_up_after: healthcheck_setting(retries, 'give_up_after', HEALTHCHECK_GIVE_UP_AFTER, 0) }
end

def redacted_url(url)
  uri = URI.parse(url)
  raise(URI::InvalidURIError, 'not http') unless uri.is_a?(URI::HTTP)

  uri.class.build(host: uri.host, port: uri.port, path: uri.path).to_s
rescue URI::Error
  '<unparsable URL>'
end

def healthcheck_failure(url)
  out, err, status = Open3.capture3('curl', '--silent', '--show-error', '--globoff', '--proto', '=http,https', '--output', File::NULL, '--write-out', CURL_STATUS_FORMAT, '--max-time', HEALTHCHECK_TIMEOUT.to_s, '--url', url)
  return "curl failed: #{err.strip.gsub(url, redacted_url(url))}" unless status.success?

  out.start_with?('2') ? nil : "HTTP #{out}"
rescue SystemCallError => e
  "curl could not run: #{e.message}"
end

def check_urls(urls)
  failures = urls.to_h { |url| [url, healthcheck_failure(url)] }
  failures.compact!
  (urls - failures.keys).each { |url| log("Health check OK: #{redacted_url(url)}") }
  failures
end

def retry_healthchecks(healthchecks, failures, started)
  deadline = started + healthchecks[:give_up_after]

  until failures.empty? || Time.now >= deadline
    failures.each { |url, reason| log_warn("Health check failed for #{redacted_url(url)}: #{reason}, retrying in #{healthchecks[:interval]} s...") }
    sleep(healthchecks[:interval])
    remaining = check_urls(failures.keys)
    (failures.keys - remaining.keys).each { |url| notify(:healthcheck_recovered, url: redacted_url(url), after: (Time.now - started).round) }
    failures = remaining
  end

  failures
end

def run_healthchecks(healthchecks, strict: false)
  return if healthchecks.nil? || healthchecks[:urls].empty?

  log('Running health checks...')
  started = Time.now
  urls = healthchecks[:urls]
  failures = check_urls(urls)
  failures.each { |url, reason| notify(:healthcheck_failing, url: redacted_url(url), reason: reason) }
  failures = retry_healthchecks(healthchecks, failures, started)

  failures.each do |url, reason|
    log_warn("WARNING: giving up on health check #{redacted_url(url)}: #{reason}")
    notify(:healthcheck_gave_up, url: redacted_url(url), reason: reason)
  end

  notify(:healthchecks_done, passed: (urls - failures.keys).map { |url| redacted_url(url) }, failed: failures.map { |url, reason| { url: redacted_url(url), reason: reason } })
  return unless strict && !failures.empty?

  failed_urls = failures.keys.map { |url| redacted_url(url) }
  raise("Health checks failed: #{failed_urls.join(', ')}")
end

def reset_option_error(options, names)
  return unless options[:'reset-instances']
  return '--reset-instances cannot be used with --lambda_publish_version' if options[:lambda_publish_version]
  return if names.empty? || options[:'redeploy-latest'] || requested_amis(options, names).values.all?

  '--reset-instances leaves blank standalone instances: add --redeploy-latest, or --ami for every instance'
end

def instance_required?(options)
  !options[:'reset-instances'] || options[:'redeploy-latest'] || options[:resize]
end

def plugin_option_error(options)
  unknown = Array(options[:'disable-plugins']) - Plugins.available - ['all']
  "--disable-plugins: unknown #{unknown.join(', ')} (available: all, #{Plugins.available.join(', ')})" unless unknown.empty?
end

def instance_list_error(options, names)
  return 'missing argument: instance' if names.empty? && instance_required?(options)
  return "--ami has #{parse_ami_list(options[:ami]).length} value(s) but --instance has #{names.length}; use none to build an AMI for an instance" if options[:ami] && parse_ami_list(options[:ami]).length != names.length
  return '--type cannot be used with more than one instance' if names.length > 1 && options[:type]

  reset_option_error(options, names) || plugin_option_error(options)
end

def validate_instance_list!(options)
  error = instance_list_error(options, instance_names(options))
  return if error.nil?

  warn(error)
  exit(1)
end

def parse_deploy_options(argv = ARGV)
  mandatory = argv.include?('--reset-instances') ? %i[environment profile] : %i[environment instance profile]
  options =
    CliMain.parse_options!(mandatory: mandatory, argv: argv) do |opts|
      opts.on('--ami ami1,none,ami2', String, 'AMI per instance, in --instance order; none builds one')
      opts.on('--create_ami_only')
      opts.on('--disable-plugins [all,plugin]', Array, 'Turn off every plugin, or the ones listed')
      opts.on('--dry-run', 'Run discovery and read-only checks, then print the planned changes')
      opts.on('--environment environment', String)
      opts.on('--instance instance1,instance2', String)
      opts.on('--type instance_type', String)
      opts.on('--lambda_publish_version function_name', String)
      opts.on('--profile profile', String)
      opts.on('--preserve_desired_capacity')
      opts.on('--redeploy-latest', 'Rerun the latest successful user-triggered CodeDeploy deployment on each standalone instance before its AMI')
      opts.on('--reset-instances', 'Recreate the standalone instances first; --instance is then optional')
      opts.on('--resize instance_type', String, 'Resize the standalone instances for the redeploy and AMI, then put them back')
      opts.on('--sequential_rollout')
      opts.on('--non-interactive', 'Never prompt: every question is answered no and the run stops')
      opts.on('--skip-lock', 'Run alongside another deploy of the same profile and environment')
      opts.on('--skip-other-deploy-check', 'Do not look for signs of another deploy')
      opts.on('--skip-permission-check', 'Do not check the IAM permissions this run needs')
      opts.on('--skip-rollback', 'Leave a failed rollout as it is instead of rolling back to the previous AMIs')
      opts.on('--skip_scale_down')
      opts.on('--sms', 'Send texts through the sms plugin for this run')
      opts.on('--spot_target_capacity spot_target_capacity', Integer)
    end
  options[:'disable-plugins'] ||= ['all'] if options.key?(:'disable-plugins')
  validate_instance_list!(options)
  options
end

def run_log_settings
  settings = deploy_config['log'] || {}
  raise(PreflightError, 'The log section of the deploy config must be a mapping.') unless settings.is_a?(Hash)

  settings
end

def run_log_path(options, settings)
  name = "#{Time.now.strftime('%Y-%m-%d-%H%M%S')}-#{Process.pid}-#{options[:profile]}-#{options[:environment]}.log".gsub(/[^\w.-]/, '_')
  File.join(File.expand_path(settings['directory'] || File.join(deploy_directory, 'logs')), name)
end

def start_run_log(options)
  settings = run_log_settings
  return if dry_run?(options) || settings['enabled'] == false

  @run_log = RunLog.new(run_log_path(options, settings))
  $stdout = TeeOutput.new($stdout, @run_log)
  $stderr = TeeOutput.new($stderr, @run_log)
  log("Log: #{@run_log.path}")
rescue SystemCallError => e
  log_warn("WARNING: no run log: #{e.message}")
end

def stop_run_log
  return if @run_log.nil?

  log("Log: #{@run_log.path}")
  $stdout = $stdout.console if $stdout.is_a?(TeeOutput)
  $stderr = $stderr.console if $stderr.is_a?(TeeOutput)
  @run_log.close
  @run_log = nil
end

def start_plugins(options)
  return if dry_run?(options)

  context = { profile: options[:profile], environment: options[:environment], instances: instance_names(options) }
  @plugins = PluginManager.load(File.join(deploy_directory, PLUGINS_FILE), options, context, method(:start_thread))
  log("Plugins: #{@plugins.names.join(', ')}") unless @plugins.names.empty?
end

def stop_plugins
  @plugins&.shutdown
  @plugins = nil
end

def deploy_from_cli(options)
  @non_interactive = options[:'non-interactive'] == true
  start_run_log(options)
  start_plugins(options)
  log('Starting deployment...')
  notify(:deploy_started)
  run_deployment(options)
rescue PreflightError => e
  log_warn(e.message)
  notify(:deploy_aborted, reason: e.message)
  exit(EXIT_FAILED)
rescue DeployErrors::RolledBack => e
  log_warn(e.message)
  notify(:deploy_failed, error: e.message, outcome: 'rolled_back')
  exit(EXIT_ROLLED_BACK)
rescue DeployErrors::NeedsHuman => e
  log_warn(e.full_message)
  notify(:deploy_failed, error: e.message, outcome: 'needs_human')
  exit(EXIT_NEEDS_HUMAN)
rescue StandardError => e
  notify(:deploy_failed, error: e.message)
  raise
rescue SignalException
  notify(:deploy_interrupted)
  raise
ensure
  stop_plugins
  stop_run_log
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  CliMain.run! do
    deploy_from_cli(parse_deploy_options)
  end
end
# :nocov:
