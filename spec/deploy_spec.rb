# frozen_string_literal: true

CLOUDFRONT_DISTRIBUTION_DEFAULTS = {
  custom_error_responses: { quantity: 0 },
  price_class: 'PriceClass_All',
  web_acl_id: '',
  http_version: 'http2',
  is_ipv6_enabled: true,
  staging: false
}.freeze

def build_distribution_item(overrides = {})
  {
    id: 'DIST123',
    arn: 'arn:aws:cloudfront::123:distribution/DIST123',
    status: 'Deployed',
    last_modified_time: Time.now,
    domain_name: 'd123.cloudfront.net',
    comment: '',
    aliases: { quantity: 1, items: ['beta.example.com'] },
    origins: { quantity: 1, items: [{ id: 'origin1', domain_name: 'origin.example.com' }] },
    default_cache_behavior: {
      target_origin_id: 'origin1',
      viewer_protocol_policy: 'redirect-to-https',
      allowed_methods: { quantity: 2, items: %w[GET HEAD] },
      forwarded_values: { query_string: false, cookies: { forward: 'none' } },
      min_ttl: 0
    },
    cache_behaviors: { quantity: 0 },
    restrictions: { geo_restriction: { restriction_type: 'none', quantity: 0 } },
    viewer_certificate: {},
    enabled: true
  }.merge(CLOUDFRONT_DISTRIBUTION_DEFAULTS).merge(overrides)
end

module Deploy; end

RSpec.describe(Deploy) do
  def build_instance_response(id, name, state_code: 16, state_name: 'running')
    { reservations: [{ instances: [{ instance_id: id, state: { code: state_code, name: state_name }, tags: [{ key: 'Name', value: name }] }] }] }
  end

  def build_asg_data(name, min: 1, max: 4, desired: 2, instances: [])
    { auto_scaling_groups: [{ auto_scaling_group_name: name, min_size: min, max_size: max, desired_capacity: desired, default_cooldown: 300, availability_zones: ['us-east-1a'], health_check_type: 'EC2', created_time: Time.now, instances: instances }] }
  end

  def build_asg_instance(id)
    { instance_id: id, lifecycle_state: 'InService', availability_zone: 'us-east-1a', health_status: 'Healthy', protected_from_scale_in: false }
  end

  def build_distribution_list(items)
    { distribution_list: { marker: '', max_items: 100, is_truncated: false, quantity: items.length, items: items } }
  end

  def build_cf_config(lambda_assoc = { quantity: 0, items: [] })
    {
      etag: 'E123',
      distribution_config: {
        caller_reference: 'ref',
        origins: { quantity: 1, items: [{ id: 'origin1', domain_name: 'origin.example.com' }] },
        default_cache_behavior: {
          target_origin_id: 'origin1',
          viewer_protocol_policy: 'redirect-to-https',
          allowed_methods: { quantity: 2, items: %w[GET HEAD] },
          forwarded_values: { query_string: false, cookies: { forward: 'none' } },
          min_ttl: 0,
          lambda_function_associations: lambda_assoc
        },
        comment: '',
        enabled: true
      }
    }
  end

  def build_distribution_double(dist_id, _arn, quantity, items)
    associations = instance_double(Aws::CloudFront::Types::LambdaFunctionAssociations, quantity: quantity, items: items)
    cache_behavior = instance_double(Aws::CloudFront::Types::DefaultCacheBehavior, lambda_function_associations: associations)
    instance_double(Aws::CloudFront::Types::DistributionSummary, id: dist_id, default_cache_behavior: cache_behavior)
  end

  def build_lambda_item(arn)
    instance_double(Aws::CloudFront::Types::LambdaFunctionAssociation, lambda_function_arn: arn)
  end

  describe 'constants' do
    it 'defines POLL_INTERVAL as 15' do
      expect(POLL_INTERVAL).to(eq(15))
    end

    it 'defines WARMUP_SHORT as 60' do
      expect(WARMUP_SHORT).to(eq(60))
    end

    it 'defines WARMUP_LONG as 180' do
      expect(WARMUP_LONG).to(eq(180))
    end

    it 'defines LOAD_BALANCED_INSTANCES as frozen array', :aggregate_failures do
      expect(LOAD_BALANCED_INSTANCES).to(eq(%w[api grpc]))
      expect(LOAD_BALANCED_INSTANCES).to(be_frozen)
    end

    it 'defines ACTIVE_STACK_STATUSES as frozen array', :aggregate_failures do
      expect(ACTIVE_STACK_STATUSES).to(include('CREATE_COMPLETE', 'UPDATE_COMPLETE'))
      expect(ACTIVE_STACK_STATUSES).to(be_frozen)
    end
  end

  describe '#load_balanced_instance?' do
    it 'returns true for api' do
      expect(load_balanced_instance?('api')).to(be(true))
    end

    it 'returns true for grpc' do
      expect(load_balanced_instance?('grpc')).to(be(true))
    end

    it 'returns false for worker' do
      expect(load_balanced_instance?('worker')).to(be(false))
    end

    it 'returns false for scheduler' do
      expect(load_balanced_instance?('scheduler')).to(be(false))
    end
  end

  describe '#parameter_prefix_for' do
    it 'returns API in uppercase' do
      expect(parameter_prefix_for('api')).to(eq('API'))
    end

    it 'returns GRPC in uppercase' do
      expect(parameter_prefix_for('grpc')).to(eq('GRPC'))
    end

    it 'returns Worker capitalized' do
      expect(parameter_prefix_for('worker')).to(eq('Worker'))
    end

    it 'returns Scheduler capitalized' do
      expect(parameter_prefix_for('scheduler')).to(eq('Scheduler'))
    end
  end

  describe '#resolve_parameter_value' do
    let(:prefix)  { 'API'                                             }
    let(:ami_id)  { 'ami-12345678'                                    }
    let(:asg)     { { min_size: 1, max_size: 4, desired_capacity: 2 } }
    let(:options) { { type: 't3.micro', spot_target_capacity: 50 }    }

    it 'resolves ImageId' do
      expect(resolve_parameter_value('APIImageId', prefix, ami_id, asg, options)).to(eq('ami-12345678'))
    end

    it 'resolves MinSize' do
      expect(resolve_parameter_value('APIMinSize', prefix, ami_id, asg, options)).to(eq('1'))
    end

    it 'resolves MaxSize' do
      expect(resolve_parameter_value('APIMaxSize', prefix, ami_id, asg, options)).to(eq('4'))
    end

    it 'resolves DesiredCapacity' do
      expect(resolve_parameter_value('APIDesiredCapacity', prefix, ami_id, asg, options)).to(eq('2'))
    end

    it 'resolves InstanceType' do
      expect(resolve_parameter_value('APIInstanceType', prefix, ami_id, asg, options)).to(eq('t3.micro'))
    end

    it 'resolves SpotTargetCapacity' do
      expect(resolve_parameter_value('SpotTargetCapacity', prefix, ami_id, asg, options)).to(eq('50'))
    end

    it 'returns nil for unknown key' do
      expect(resolve_parameter_value('Unknown', prefix, ami_id, asg, options)).to(be_nil)
    end

    it 'returns nil for SpotTargetCapacity when not set' do
      expect(resolve_parameter_value('SpotTargetCapacity', prefix, ami_id, asg, {})).to(be_nil)
    end
  end

  describe '#extract_subnet_number' do
    it 'extracts subnet number from stack name' do
      expect(extract_subnet_number('beta1-StackInstances-abc')).to(eq(1))
    end

    it 'extracts subnet number from DR environment stack name' do
      expect(extract_subnet_number('beta3-StackInstances-abc')).to(eq(3))
    end

    it 'extracts multi-digit subnet number' do
      expect(extract_subnet_number('prod12-StackInstances-abc')).to(eq(12))
    end

    it 'raises error when no digits in first segment' do
      expect { extract_subnet_number('beta-StackInstances-abc') }
        .to(raise_error(RuntimeError, "Unable to extract subnet number from stack name 'beta-StackInstances-abc'"))
    end
  end

  describe '#find_standalone_instance' do
    let(:ec2) { Aws::EC2::Resource.new(stub_responses: true) }
    let(:options) { { instance: 'api', environment: 'beta' } }

    context 'when matching instance found' do
      before { ec2.client.stub_responses(:describe_instances, build_instance_response('i-abc123', 'api-beta1-standalone')) }

      it 'returns instance id and name', :aggregate_failures do
        instance_id, instance_name = find_standalone_instance(ec2, options)
        expect(instance_id).to(eq('i-abc123'))
        expect(instance_name).to(eq('api-beta1-standalone'))
      end
    end

    context 'when no matching instance found' do
      before { ec2.client.stub_responses(:describe_instances, build_instance_response('i-xyz789', 'worker-prod1-standalone')) }

      it 'raises an error' do
        expect { find_standalone_instance(ec2, options) }
          .to(raise_error(RuntimeError, 'Unable to find standalone instance'))
      end
    end

    context 'when instance is terminated' do
      before { ec2.client.stub_responses(:describe_instances, build_instance_response('i-abc123', 'api-beta1-standalone', state_code: 48, state_name: 'terminated')) }

      it 'raises an error' do
        expect { find_standalone_instance(ec2, options) }
          .to(raise_error(RuntimeError, 'Unable to find standalone instance'))
      end
    end
  end

  describe '#create_ami' do
    let(:ec2) { Aws::EC2::Resource.new(stub_responses: true) }
    let(:options) { { instance: 'api' } }

    before do
      ec2.client.stub_responses(:create_image, { image_id: 'ami-new123' })
      ec2.client.stub_responses(:describe_images, { images: [{ state: 'available', image_id: 'ami-new123' }] })
    end

    it 'creates an AMI and returns image_id' do
      result = create_ami(ec2, 'i-abc123', 'api-beta1-standalone', options)
      expect(result).to(eq('ami-new123'))
    end

    context 'with worker instance' do
      before { allow(Aws::EC2::Waiters::ImageAvailable).to(receive(:new).and_call_original) }

      it 'uses max_attempts 1024' do
        create_ami(ec2, 'i-abc123', 'worker-beta1-standalone', { instance: 'worker' })
        expect(Aws::EC2::Waiters::ImageAvailable).to(have_received(:new).with(hash_including(max_attempts: 1024)))
      end
    end

    context 'with non-worker instance' do
      before { allow(Aws::EC2::Waiters::ImageAvailable).to(receive(:new).and_call_original) }

      it 'uses max_attempts 256' do
        create_ami(ec2, 'i-abc123', 'api-beta1-standalone', options)
        expect(Aws::EC2::Waiters::ImageAvailable).to(have_received(:new).with(hash_including(max_attempts: 256)))
      end
    end
  end

  describe '#find_auto_scaling_group' do
    let(:asg_resources) { Aws::AutoScaling::Resource.new(stub_responses: true) }
    let(:options) { { environment: 'beta', instance: 'api' } }

    context 'when matching ASG exists' do
      before { asg_resources.client.stub_responses(:describe_auto_scaling_groups, build_asg_data('beta1-api-asg')) }

      it 'returns ASG details', :aggregate_failures do
        result = find_auto_scaling_group(asg_resources, options)
        expect(result[:name]).to(eq('beta1-api-asg'))
        expect(result[:desired_capacity]).to(eq(2))
        expect(result[:min_size]).to(eq(1))
        expect(result[:max_size]).to(eq(4))
      end
    end

    context 'when matching DR ASG exists' do
      before { asg_resources.client.stub_responses(:describe_auto_scaling_groups, build_asg_data('beta3-api-asg')) }

      it 'returns ASG details for DR environment' do
        result = find_auto_scaling_group(asg_resources, { environment: 'beta3', instance: 'api' })
        expect(result[:name]).to(eq('beta3-api-asg'))
      end
    end

    context 'when no matching ASG exists' do
      before { asg_resources.client.stub_responses(:describe_auto_scaling_groups, build_asg_data('prod1-worker-asg')) }

      it 'raises an error' do
        expect { find_auto_scaling_group(asg_resources, options) }
          .to(raise_error(RuntimeError, 'Unable to find auto scaling group'))
      end
    end
  end

  describe '#find_target_group' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    context 'with api instance' do
      before { elb.stub_responses(:describe_target_groups, { target_groups: [{ target_group_name: 'beta1-443', target_group_arn: 'arn:aws:tg/beta1-443' }] }) }

      it 'finds target group' do
        result = find_target_group(elb, { environment: 'beta', instance: 'api' })
        expect(result).to(eq('arn:aws:tg/beta1-443'))
      end
    end

    context 'with grpc instance' do
      before { elb.stub_responses(:describe_target_groups, { target_groups: [{ target_group_name: 'beta1-8443-HTTP2', target_group_arn: 'arn:aws:tg/beta1-8443' }] }) }

      it 'finds target group' do
        result = find_target_group(elb, { environment: 'beta', instance: 'grpc' })
        expect(result).to(eq('arn:aws:tg/beta1-8443'))
      end
    end

    context 'with DR environment' do
      before { elb.stub_responses(:describe_target_groups, { target_groups: [{ target_group_name: 'beta3-443', target_group_arn: 'arn:aws:tg/beta3-443' }] }) }

      it 'finds target group for DR environment' do
        result = find_target_group(elb, { environment: 'beta3', instance: 'api' })
        expect(result).to(eq('arn:aws:tg/beta3-443'))
      end
    end

    context 'when no target group found' do
      before { elb.stub_responses(:describe_target_groups, { target_groups: [] }) }

      it 'raises an error' do
        expect { find_target_group(elb, { environment: 'beta', instance: 'api' }) }
          .to(raise_error(RuntimeError, 'Unable to find load balancer target group'))
      end
    end
  end

  describe '#find_cloudformation_stack' do
    let(:cfn)     { Aws::CloudFormation::Client.new(stub_responses: true) }
    let(:options) { { environment: 'beta' }                               }

    context 'when matching stack exists' do
      before { cfn.stub_responses(:list_stacks, { stack_summaries: [{ stack_name: 'beta1-StackInstances-abc', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }) }

      it 'returns stack name' do
        expect(find_cloudformation_stack(cfn, options)).to(eq('beta1-StackInstances-abc'))
      end
    end

    context 'when matching DR stack exists' do
      before { cfn.stub_responses(:list_stacks, { stack_summaries: [{ stack_name: 'beta3-StackInstances-xyz', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }) }

      it 'returns DR stack name' do
        expect(find_cloudformation_stack(cfn, { environment: 'beta3' })).to(eq('beta3-StackInstances-xyz'))
      end
    end

    context 'when no stack found' do
      before { cfn.stub_responses(:list_stacks, { stack_summaries: [] }) }

      it 'raises an error' do
        expect { find_cloudformation_stack(cfn, options) }
          .to(raise_error(RuntimeError, 'Unable to find cloudformation stack'))
      end
    end
  end

  describe '#find_matching_distribution' do
    let(:cloudfront) { Aws::CloudFront::Client.new(stub_responses: true) }

    context 'when matching distribution exists' do
      before { cloudfront.stub_responses(:list_distributions, build_distribution_list([build_distribution_item])) }

      it 'returns the distribution' do
        expect(find_matching_distribution(cloudfront, 'beta').id).to(eq('DIST123'))
      end
    end

    context 'when no distribution matches' do
      before do
        item = build_distribution_item(id: 'DIST456', arn: 'arn:aws:cloudfront::123:distribution/DIST456', domain_name: 'd456.cloudfront.net', aliases: { quantity: 1, items: ['prod.example.com'] })
        cloudfront.stub_responses(:list_distributions, build_distribution_list([item]))
      end

      it 'returns nil' do
        expect(find_matching_distribution(cloudfront, 'beta')).to(be_nil)
      end
    end
  end

  describe '#update_ssm_parameters' do
    let(:ssm) { Aws::SSM::Client.new(stub_responses: true) }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:put_parameter).and_call_original)
    end

    context 'when parameter matches a known key' do
      it 'updates matching parameters via SSM' do
        parameter = instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'APIImageId', parameter_value: nil, use_previous_value: nil)
        allow(parameter).to(receive(:parameter_value=))
        allow(parameter).to(receive(:use_previous_value=))
        update_ssm_parameters([parameter], 'API', 'ami-12345678', { min_size: 1, max_size: 4, desired_capacity: 2 }, { type: 't3.micro' }, '/beta/1')
        expect(ssm).to(have_received(:put_parameter).with(hash_including(value: 'ami-12345678')))
      end
    end

    context 'when parameter is a known CFN secret' do
      it 'does not call put_parameter on the secret' do
        parameter = instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'DbPassword')
        update_ssm_parameters([parameter], 'API', 'ami-12345678', { min_size: 1, max_size: 4, desired_capacity: 2 }, { type: 't3.micro' }, '/beta/1')
        expect(ssm).not_to(have_received(:put_parameter))
      end
    end
  end

  describe '#mark_cfn_secrets_for_previous_value!' do
    let(:secret)     { instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'DbPassword') }
    let(:non_secret) { instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'APIImageId') }

    before do
      allow(secret).to(receive(:parameter_value=))
      allow(secret).to(receive(:use_previous_value=))
      mark_cfn_secrets_for_previous_value!([secret, non_secret])
    end

    it 'marks each known secret for previous-value reuse', :aggregate_failures do
      expect(secret).to(have_received(:parameter_value=).with(nil))
      expect(secret).to(have_received(:use_previous_value=).with(true))
    end
  end

  describe '#wait_for_healthy_instances' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    before { allow(self).to(receive(:sleep)) }

    context 'when targets become healthy' do
      before do
        unhealthy = { target_health_descriptions: [{ target: { id: 'i-1' }, target_health: { state: 'healthy' } }, { target: { id: 'i-2' }, target_health: { state: 'unhealthy' } }] }
        healthy = { target_health_descriptions: [{ target: { id: 'i-1' }, target_health: { state: 'healthy' } }, { target: { id: 'i-2' }, target_health: { state: 'healthy' } }] }
        elb.stub_responses(:describe_target_health, [unhealthy, healthy])
      end

      it 'waits until all targets are healthy' do
        wait_for_healthy_instances(elb, 'arn:aws:tg/test')
        expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
      end
    end

    context 'when targets never become healthy' do
      before do
        unhealthy = { target_health_descriptions: [{ target: { id: 'i-1' }, target_health: { state: 'unhealthy' } }] }
        elb.stub_responses(:describe_target_health, unhealthy)
      end

      it 'raises after max attempts' do
        stub_const('MAX_POLL_ATTEMPTS', 2)
        expect { wait_for_healthy_instances(elb, 'arn:aws:tg/test') }
          .to(raise_error(RuntimeError, /Timed out waiting for healthy instances/))
      end
    end
  end

  describe '#wait_for_asg_instance_count' do
    let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true) }

    before { allow(self).to(receive(:sleep)) }

    context 'when instance count reaches target' do
      before do
        first = build_asg_data('test-asg', instances: [build_asg_instance('i-1')])
        second = build_asg_data('test-asg', instances: [build_asg_instance('i-1'), build_asg_instance('i-2')])
        asg_client.stub_responses(:describe_auto_scaling_groups, [first, second])
      end

      it 'waits until count matches' do
        wait_for_asg_instance_count(asg_client, 'test-asg', 2)
        expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
      end
    end

    context 'when ASG cannot be described' do
      before { asg_client.stub_responses(:describe_auto_scaling_groups, { auto_scaling_groups: [] }) }

      it 'raises an error' do
        expect { wait_for_asg_instance_count(asg_client, 'missing-asg', 2) }
          .to(raise_error(RuntimeError, /Unable to describe ASG/))
      end
    end

    context 'when instance count never reaches target' do
      before do
        stuck = build_asg_data('test-asg', instances: [build_asg_instance('i-1')])
        asg_client.stub_responses(:describe_auto_scaling_groups, stuck)
      end

      it 'raises after max attempts' do
        stub_const('MAX_POLL_ATTEMPTS', 2)
        expect { wait_for_asg_instance_count(asg_client, 'test-asg', 3) }
          .to(raise_error(RuntimeError, /Timed out waiting for ASG/))
      end
    end
  end

  describe '#wait_for_stack_update' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true) }

    before { allow(self).to(receive(:sleep)) }

    context 'when update completes' do
      before do
        cfn.stub_responses(
          :describe_stacks,
          [
            { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_IN_PROGRESS', creation_time: Time.now }] },
            { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }
          ]
        )
      end

      it 'waits until stack update is complete' do
        wait_for_stack_update(cfn, 'test')
        expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
      end
    end

    context 'when update fails' do
      before { cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_FAILED', creation_time: Time.now }] }) }

      it 'raises an error' do
        expect { wait_for_stack_update(cfn, 'test') }
          .to(raise_error(RuntimeError, 'Stack update failed'))
      end
    end

    context 'when stack cannot be described' do
      before { cfn.stub_responses(:describe_stacks, { stacks: [] }) }

      it 'raises an error' do
        expect { wait_for_stack_update(cfn, 'test') }
          .to(raise_error(RuntimeError, /Unable to describe stack/))
      end
    end

    context 'when stack update never completes' do
      before do
        cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_IN_PROGRESS', creation_time: Time.now }] })
      end

      it 'raises after max attempts' do
        stub_const('MAX_POLL_ATTEMPTS', 2)
        expect { wait_for_stack_update(cfn, 'test') }
          .to(raise_error(RuntimeError, /Timed out waiting for stack/))
      end
    end
  end

  describe '#update_cloudformation_stack' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true) }

    before do
      allow(self).to(receive(:sleep))
      allow(cfn).to(receive(:update_stack).and_call_original)
      cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'test-stack', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] })
    end

    it 'updates the stack and waits for completion' do
      update_cloudformation_stack(cfn, 'test-stack', [], 'API', 'ami-123')
      expect(cfn).to(have_received(:update_stack).with(hash_including(stack_name: 'test-stack')))
    end

    context 'when ValidationError is no updates to be performed' do
      before { allow(cfn).to(receive(:update_stack).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'No updates are to be performed'))) }

      it 'exits with code 0', :aggregate_failures do
        expect { update_cloudformation_stack(cfn, 'test-stack', [], 'API', 'ami-123') }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(0)) })
      end
    end

    context 'when ValidationError is a genuine error' do
      before { allow(cfn).to(receive(:update_stack).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'Template validation failed'))) }

      it 'exits with code 1', :aggregate_failures do
        expect { update_cloudformation_stack(cfn, 'test-stack', [], 'API', 'ami-123') }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
      end
    end
  end

  describe '#resolve_capacity_factors' do
    it 'returns asg_increase=1, asg_multiplier=2 for beta', :aggregate_failures do
      result = resolve_capacity_factors({ environment: 'beta' })
      expect(result[:asg_increase]).to(eq(1))
      expect(result[:asg_multiplier]).to(eq(2))
    end

    it 'returns asg_increase=3 for prod environments' do
      expect(resolve_capacity_factors({ environment: 'prod1' })[:asg_increase]).to(eq(3))
    end

    it 'overrides to asg_increase=0, asg_multiplier=1 when preserve_desired_capacity', :aggregate_failures do
      result = resolve_capacity_factors({ environment: 'prod1', preserve_desired_capacity: true })
      expect(result[:asg_increase]).to(eq(0))
      expect(result[:asg_multiplier]).to(eq(1))
    end
  end

  describe '#compute_asg_capacity_plan' do
    it 'computes new_capacity = (desired * multiplier) + increase' do
      asg = { desired_capacity: 4, max_size: 10 }
      expect(compute_asg_capacity_plan(asg, asg_increase: 1, asg_multiplier: 2)[:new_capacity]).to(eq(9))
    end

    it 'returns new_max=nil when max_size already exceeds new_capacity' do
      asg = { desired_capacity: 2, max_size: 20 }
      expect(compute_asg_capacity_plan(asg, asg_increase: 1, asg_multiplier: 2)[:new_max]).to(be_nil)
    end

    it 'returns scaled new_max when current max_size is below new_capacity' do
      asg = { desired_capacity: 4, max_size: 4 }
      expect(compute_asg_capacity_plan(asg, asg_increase: 1, asg_multiplier: 2)[:new_max]).to(eq(9))
    end
  end

  describe '#resolve_ami_id' do
    context 'when --ami is supplied' do
      before { allow(Aws::EC2::Resource).to(receive(:new)) }

      it 'returns it directly' do
        expect(resolve_ami_id({ ami: 'ami-supplied' })).to(eq('ami-supplied'))
      end

      it 'does not call Aws::EC2::Resource.new' do
        resolve_ami_id({ ami: 'ami-supplied' })
        expect(Aws::EC2::Resource).not_to(have_received(:new))
      end
    end

    context 'when --ami is not supplied' do
      let(:ec2) { Aws::EC2::Resource.new(stub_responses: true) }

      before do
        allow(Aws::EC2::Resource).to(receive(:new).and_return(ec2))
        ec2.client.stub_responses(:describe_instances, build_instance_response('i-abc', 'api-beta1-standalone'))
        ec2.client.stub_responses(:create_image, { image_id: 'ami-new' })
        allow(Aws::EC2::Waiters::ImageAvailable).to(receive(:new).and_return(instance_double(Aws::EC2::Waiters::ImageAvailable, wait: nil)))
      end

      it 'discovers standalone and creates an AMI' do
        expect(resolve_ami_id({ instance: 'api', environment: 'beta1' })).to(eq('ami-new'))
      end
    end
  end

  describe '#discover_cfn_stack_context' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true) }

    before do
      cfn.stub_responses(:list_stacks, { stack_summaries: [{ stack_name: 'beta1-StackInstances-x', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] })
      cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'beta1-StackInstances-x', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now, parameters: [{ parameter_key: 'APIImageId', parameter_value: 'ami-old' }] }] })
    end

    it 'returns environment, subnet, prefix and ssm_prefix derived from the stack name' do
      ctx = discover_cfn_stack_context(cfn, { instance: 'api', environment: 'beta1' })
      expect(ctx).to(include(environment: 'beta', subnet: 1, prefix: 'API', ssm_prefix: '/beta/1'))
    end

    it 'returns the stack parameters' do
      ctx = discover_cfn_stack_context(cfn, { instance: 'api', environment: 'beta1' })
      expect(ctx[:parameters].first.parameter_key).to(eq('APIImageId'))
    end

    it 'raises when no stack is found' do
      cfn.stub_responses(:describe_stacks, { stacks: [] })
      expect { discover_cfn_stack_context(cfn, { instance: 'api', environment: 'beta1' }) }
        .to(raise_error(RuntimeError, /Unable to describe stack/))
    end
  end

  describe '#discover_load_balancer' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    context 'when instance is load-balanced' do
      before do
        allow(Aws::ElasticLoadBalancingV2::Client).to(receive(:new).and_return(elb))
        elb.stub_responses(:describe_target_groups, { target_groups: [{ target_group_arn: 'arn:beta1-80', target_group_name: 'beta1-80' }] })
      end

      it 'returns the ELB client and the target group arn', :aggregate_failures do
        client, arn = discover_load_balancer({ instance: 'api', environment: 'beta1' })
        expect(client).to(be(elb))
        expect(arn).to(eq('arn:beta1-80'))
      end
    end

    context 'when instance is not load-balanced' do
      before { allow(Aws::ElasticLoadBalancingV2::Client).to(receive(:new)) }

      it 'returns [nil, nil]' do
        expect(discover_load_balancer({ instance: 'worker' })).to(eq([nil, nil]))
      end

      it 'does not instantiate an ELB client' do
        discover_load_balancer({ instance: 'worker' })
        expect(Aws::ElasticLoadBalancingV2::Client).not_to(have_received(:new))
      end
    end
  end

  describe '#parse_deploy_options' do
    it 'parses mandatory and optional arguments', :aggregate_failures do
      options = parse_deploy_options(%w[--environment beta1 --instance api --profile dev --ami ami-abc])
      expect(options[:environment]).to(eq('beta1'))
      expect(options[:instance]).to(eq('api'))
      expect(options[:profile]).to(eq('dev'))
      expect(options[:ami]).to(eq('ami-abc'))
    end

    it 'raises when a mandatory argument is missing' do
      expect { parse_deploy_options(%w[--environment beta1 --instance api]) }
        .to(raise_error(OptionParser::MissingArgument, /profile/))
    end
  end

  describe '#warm_up_after_scale_up' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    before { allow(self).to(receive(:sleep)) }

    context 'with grpc instance' do
      before { elb.stub_responses(:describe_target_health, { target_health_descriptions: [{ target: { id: 'i-1' }, target_health: { state: 'healthy' } }] }) }

      it 'sleeps WARMUP_SHORT then waits for healthy then sleeps WARMUP_LONG', :aggregate_failures do
        warm_up_after_scale_up(elb, 'arn:tg', { instance: 'grpc' })
        expect(self).to(have_received(:sleep).with(WARMUP_SHORT))
        expect(self).to(have_received(:sleep).with(WARMUP_LONG))
      end
    end

    context 'with worker instance (not load-balanced)' do
      it 'skips ELB checks and sleeps WARMUP_SHORT', :aggregate_failures do
        warm_up_after_scale_up(nil, nil, { instance: 'worker' })
        expect(self).to(have_received(:sleep).with(WARMUP_SHORT))
      end
    end
  end

  describe '#scale_down_after_deploy' do
    let(:asg_resources) { instance_double(Aws::AutoScaling::Resource, client: asg_client) }
    let(:asg_client)    { Aws::AutoScaling::Client.new(stub_responses: true)          }
    let(:asg)           { { name: 'beta1-api-asg', desired_capacity: 2, max_size: 4 } }
    let(:mixed_params)  { { base_capacity: '0', percent_above: '50' }                 }

    before do
      allow(self).to(receive(:sleep))
      allow(asg_client).to(receive(:update_auto_scaling_group).and_call_original)
    end

    context 'when --skip_scale_down' do
      it 'sets max_size and skips scale-down wait', :aggregate_failures do
        scale_down_after_deploy(asg_resources, asg, mixed_params, 6, nil, nil, { instance: 'worker', skip_scale_down: true })
        expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(max_size: 4)))
      end
    end

    context 'with load-balanced instance' do
      before do
        asg_client.stub_responses(:describe_auto_scaling_groups, build_asg_data('beta1-api-asg', instances: [build_asg_instance('i-1'), build_asg_instance('i-2')]))
      end

      it 'restores desired capacity and waits for healthy + count', :aggregate_failures do
        elb = Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true)
        elb.stub_responses(:describe_target_health, { target_health_descriptions: [{ target: { id: 'i-1' }, target_health: { state: 'healthy' } }] })
        scale_down_after_deploy(asg_resources, asg, mixed_params, 6, elb, 'arn:tg', { instance: 'api' })
        expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(desired_capacity: 2, max_size: 4)))
      end
    end
  end

  describe '#run_rolling_deploy' do
    let(:asg_resources) { instance_double(Aws::AutoScaling::Resource, client: asg_client) }
    let(:asg_client)    { Aws::AutoScaling::Client.new(stub_responses: true)          }
    let(:asg)           { { name: 'beta1-api-asg', desired_capacity: 2, max_size: 4 } }
    let(:mixed_params)  { { base_capacity: '0', percent_above: '50' }                 }

    before do
      allow(self).to(receive(:sleep))
      allow(asg_client).to(receive(:update_auto_scaling_group).and_call_original)
      asg_client.stub_responses(:describe_auto_scaling_groups, build_asg_data('beta1-api-asg', instances: [build_asg_instance('i-1'), build_asg_instance('i-2')]))
    end

    it 'always restores the mixed-instances policy via ensure' do
      captured_params = []
      allow(asg_client).to(receive(:update_auto_scaling_group)) { |params| captured_params << params }
      run_rolling_deploy(asg_resources, asg, mixed_params, 2, nil, nil, { instance: 'worker' })
      expect(captured_params.last.dig(:mixed_instances_policy, :instances_distribution, :on_demand_percentage_above_base_capacity)).to(eq('50'))
    end

    it 'still restores policy when scale-up wait raises', :aggregate_failures do
      stub_const('MAX_POLL_ATTEMPTS', 1)
      asg_client.stub_responses(:describe_auto_scaling_groups, build_asg_data('beta1-api-asg', instances: [build_asg_instance('i-1')]))
      expect { run_rolling_deploy(asg_resources, asg, mixed_params, 6, nil, nil, { instance: 'worker' }) }
        .to(raise_error(RuntimeError, /Timed out/))
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(mixed_instances_policy: hash_including(instances_distribution: hash_including(on_demand_percentage_above_base_capacity: '50')))))
    end
  end

  describe '#run_deployment' do
    let(:lambda_client) { Aws::Lambda::Client.new(stub_responses: true)     }
    let(:cloudfront)    { Aws::CloudFront::Client.new(stub_responses: true) }

    context 'with --lambda_publish_version' do
      before do
        allow(Aws::Lambda::Client).to(receive(:new).and_return(lambda_client))
        allow(Aws::CloudFront::Client).to(receive(:new).and_return(cloudfront))
        allow(lambda_client).to(receive(:publish_version).and_call_original)
        lambda_client.stub_responses(:publish_version, { function_arn: 'arn:aws:lambda:us-east-1:123:function:my-function:1' })
        dist_item = build_distribution_item(default_cache_behavior: { target_origin_id: 'origin1', viewer_protocol_policy: 'redirect-to-https', allowed_methods: { quantity: 2, items: %w[GET HEAD] }, forwarded_values: { query_string: false, cookies: { forward: 'none' } }, min_ttl: 0, lambda_function_associations: { quantity: 0, items: [] } })
        cloudfront.stub_responses(:list_distributions, build_distribution_list([dist_item]))
        cloudfront.stub_responses(:get_distribution_config, build_cf_config)
      end

      it 'runs the lambda branch without touching ASG/CFN' do
        run_deployment({ environment: 'beta', instance: 'api', profile: 'dev', lambda_publish_version: 'my-function' })
        expect(lambda_client).to(have_received(:publish_version))
      end
    end
  end

  describe '#update_stack_with_ssm_rollback' do
    let(:cfn)          { Aws::CloudFormation::Client.new(stub_responses: true) }
    let(:ssm)          { Aws::SSM::Client.new(stub_responses: true)            }
    let(:param_name)   { '/beta/1/APIImageId'                                  }
    let(:ssm_snapshot) { { param_name => 'ami-old' }                           }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:put_parameter).and_call_original)
    end

    context 'when CloudFormation update succeeds' do
      before do
        allow(cfn).to(receive(:update_stack).and_call_original)
        allow(self).to(receive(:sleep))
        cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'test-stack', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] })
      end

      it 'does not restore SSM parameters' do
        update_stack_with_ssm_rollback(cfn, 'test-stack', [], 'API', 'ami-123', ssm_snapshot)
        expect(ssm).not_to(have_received(:put_parameter))
      end
    end

    context 'when CloudFormation update fails with a generic error' do
      before { allow(cfn).to(receive(:update_stack).and_raise(StandardError.new('boom'))) }

      it 'restores SSM parameters and re-raises', :aggregate_failures do
        expect { update_stack_with_ssm_rollback(cfn, 'test-stack', [], 'API', 'ami-123', ssm_snapshot) }
          .to(raise_error(StandardError, 'boom'))
        expect(ssm).to(have_received(:put_parameter).with(hash_including(name: param_name, value: 'ami-old')))
      end
    end

    context 'when CloudFormation returns "No updates are to be performed" (SystemExit 0)' do
      before { allow(cfn).to(receive(:update_stack).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'No updates are to be performed'))) }

      it 'does NOT restore SSM parameters (success path)', :aggregate_failures do
        expect { update_stack_with_ssm_rollback(cfn, 'test-stack', [], 'API', 'ami-123', ssm_snapshot) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(0)) })
        expect(ssm).not_to(have_received(:put_parameter))
      end
    end

    context 'when CloudFormation returns a genuine ValidationError (SystemExit 1)' do
      before { allow(cfn).to(receive(:update_stack).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'Template validation failed'))) }

      it 'restores SSM parameters and re-raises SystemExit(1)', :aggregate_failures do
        expect { update_stack_with_ssm_rollback(cfn, 'test-stack', [], 'API', 'ami-123', ssm_snapshot) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
        expect(ssm).to(have_received(:put_parameter).with(hash_including(name: param_name, value: 'ami-old')))
      end
    end

    context 'with empty snapshot' do
      before { allow(cfn).to(receive(:update_stack).and_raise(StandardError.new('boom'))) }

      it 'still re-raises but does not call put_parameter', :aggregate_failures do
        expect { update_stack_with_ssm_rollback(cfn, 'test-stack', [], 'API', 'ami-123', {}) }
          .to(raise_error(StandardError, 'boom'))
        expect(ssm).not_to(have_received(:put_parameter))
      end
    end
  end

  describe '#capture_ssm_snapshot' do
    let(:ssm)        { Aws::SSM::Client.new(stub_responses: true)        }
    let(:asg)        { { min_size: 1, max_size: 4, desired_capacity: 2 } }
    let(:options)    { { type: 't3.micro' }                              }
    let(:param_name) { '/beta/1/APIImageId'                              }

    before { allow(Aws::SSM::Client).to(receive(:new).and_return(ssm)) }

    context 'when SSM parameters exist' do
      before { ssm.stub_responses(:get_parameters, { parameters: [{ name: param_name, value: 'ami-old' }] }) }

      it 'returns a hash of parameter names to values' do
        parameter = instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'APIImageId')
        result = capture_ssm_snapshot([parameter], 'API', 'ami-new', asg, options, '/beta/1')
        expect(result).to(eq(param_name => 'ami-old'))
      end
    end

    context 'when no parameters need updating' do
      it 'returns empty hash' do
        parameter = instance_double(Aws::CloudFormation::Types::Parameter, parameter_key: 'Unknown')
        expect(capture_ssm_snapshot([parameter], 'API', 'ami-new', asg, options, '/beta/1')).to(eq({}))
      end
    end
  end

  describe '#restore_ssm_parameters' do
    let(:ssm)        { Aws::SSM::Client.new(stub_responses: true) }
    let(:param_name) { '/beta/1/APIImageId'                       }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:put_parameter).and_call_original)
    end

    it 'restores each parameter to its previous value' do
      restore_ssm_parameters(param_name => 'ami-old')
      expect(ssm).to(have_received(:put_parameter).with(hash_including(name: param_name, value: 'ami-old')))
    end

    it 'does nothing when snapshot is empty' do
      restore_ssm_parameters({})
      expect(ssm).not_to(have_received(:put_parameter))
    end
  end

  describe '#fetch_asg_mixed_parameters' do
    let(:ssm) { Aws::SSM::Client.new(stub_responses: true) }

    before { allow(Aws::SSM::Client).to(receive(:new).and_return(ssm)) }

    context 'when both parameters exist' do
      before { ssm.stub_responses(:get_parameters, { parameters: [{ name: '/beta/1/OnDemandPercentAbove', value: '100' }, { name: '/beta/1/OnDemandBaseCapacity', value: '2' }] }) }

      it 'returns percent_above and base_capacity', :aggregate_failures do
        result = fetch_asg_mixed_parameters('beta', 1)
        expect(result[:percent_above]).to(eq('100'))
        expect(result[:base_capacity]).to(eq('2'))
      end
    end

    context 'when both parameters exist for DR environment' do
      before { ssm.stub_responses(:get_parameters, { parameters: [{ name: '/beta/3/OnDemandPercentAbove', value: '50' }, { name: '/beta/3/OnDemandBaseCapacity', value: '1' }] }) }

      it 'returns percent_above and base_capacity for DR subnet', :aggregate_failures do
        result = fetch_asg_mixed_parameters('beta', 3)
        expect(result[:percent_above]).to(eq('50'))
        expect(result[:base_capacity]).to(eq('1'))
      end
    end

    context 'when OnDemandPercentAbove is missing' do
      before { ssm.stub_responses(:get_parameters, { parameters: [{ name: '/beta/1/OnDemandBaseCapacity', value: '2' }] }) }

      it 'raises an error' do
        expect { fetch_asg_mixed_parameters('beta', 1) }
          .to(raise_error(RuntimeError, /OnDemandPercentAbove/))
      end
    end

    context 'when OnDemandBaseCapacity is missing' do
      before { ssm.stub_responses(:get_parameters, { parameters: [{ name: '/beta/1/OnDemandPercentAbove', value: '100' }] }) }

      it 'raises an error' do
        expect { fetch_asg_mixed_parameters('beta', 1) }
          .to(raise_error(RuntimeError, /OnDemandBaseCapacity/))
      end
    end
  end

  describe '#update_asg_capacity' do
    let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true) }

    before { allow(asg_client).to(receive(:update_auto_scaling_group).and_call_original) }

    it 'updates ASG with base_capacity and percent_above' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100')
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(auto_scaling_group_name: 'test-asg')))
    end

    it 'includes desired_capacity when provided' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100', desired_capacity: 4)
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(desired_capacity: 4)))
    end

    it 'includes max_size when provided' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100', max_size: 8)
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(max_size: 8)))
    end

    it 'excludes desired_capacity and max_size when nil', :aggregate_failures do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100')
      expect(asg_client).to(have_received(:update_auto_scaling_group)) do |params|
        expect(params).not_to(have_key(:desired_capacity))
        expect(params).not_to(have_key(:max_size))
      end
    end
  end

  describe '#publish_lambda_and_update_cloudfront' do
    let(:lambda_client) { Aws::Lambda::Client.new(stub_responses: true)     }
    let(:cloudfront)    { Aws::CloudFront::Client.new(stub_responses: true) }

    before do
      allow(Aws::Lambda::Client).to(receive(:new).and_return(lambda_client))
      allow(Aws::CloudFront::Client).to(receive(:new).and_return(cloudfront))
      allow(lambda_client).to(receive(:publish_version).and_call_original)
      allow(cloudfront).to(receive(:update_distribution).and_call_original)
      lambda_client.stub_responses(:publish_version, { function_arn: 'arn:aws:lambda:us-east-1:123:function:my-function:1' })
    end

    context 'when distribution matches' do
      before do
        dist_item = build_distribution_item(
          default_cache_behavior: {
            target_origin_id: 'origin1',
            viewer_protocol_policy: 'redirect-to-https',
            allowed_methods: { quantity: 2, items: %w[GET HEAD] },
            forwarded_values: { query_string: false, cookies: { forward: 'none' } },
            min_ttl: 0,
            lambda_function_associations: { quantity: 0, items: [] }
          }
        )
        cloudfront.stub_responses(:list_distributions, build_distribution_list([dist_item]))
        cloudfront.stub_responses(:get_distribution_config, build_cf_config)
      end

      it 'publishes lambda version and updates distribution', :aggregate_failures do
        publish_lambda_and_update_cloudfront({ environment: 'beta', lambda_publish_version: 'my-function' })
        expect(lambda_client).to(have_received(:publish_version))
        expect(cloudfront).to(have_received(:update_distribution))
      end
    end

    context 'when no distribution matches' do
      before { cloudfront.stub_responses(:list_distributions, build_distribution_list([])) }

      it 'raises an error' do
        expect { publish_lambda_and_update_cloudfront({ environment: 'beta', lambda_publish_version: 'my-function' }) }
          .to(raise_error(RuntimeError, 'Unable to find cloudfront distribution'))
      end
    end
  end

  describe '#update_distribution_lambda' do
    let(:cloudfront) { Aws::CloudFront::Client.new(stub_responses: true) }
    let(:function_arn) { 'arn:aws:lambda:us-east-1:123:function:test:1' }

    before do
      allow(cloudfront).to(receive(:get_distribution_config).and_call_original)
      allow(cloudfront).to(receive(:update_distribution).and_call_original)
    end

    context 'when ARN already matches' do
      it 'skips update' do
        distribution = build_distribution_double('DIST123', nil, 1, [build_lambda_item(function_arn)])
        update_distribution_lambda(cloudfront, distribution, function_arn)
        expect(cloudfront).not_to(have_received(:get_distribution_config))
      end
    end

    context 'when existing association has different ARN' do
      before do
        assoc = { quantity: 1, items: [{ event_type: 'viewer-request', include_body: false, lambda_function_arn: 'arn:aws:lambda:old:1' }] }
        cloudfront.stub_responses(:get_distribution_config, build_cf_config(assoc))
      end

      it 'updates with new ARN' do
        distribution = build_distribution_double('DIST123', nil, 1, [build_lambda_item('arn:aws:lambda:us-east-1:123:function:old:1')])
        update_distribution_lambda(cloudfront, distribution, function_arn)
        expect(cloudfront).to(have_received(:update_distribution))
      end
    end

    context 'when no existing association' do
      before { cloudfront.stub_responses(:get_distribution_config, build_cf_config) }

      it 'adds new association' do
        distribution = build_distribution_double('DIST123', nil, 0, [])
        update_distribution_lambda(cloudfront, distribution, function_arn)
        expect(cloudfront).to(have_received(:update_distribution))
      end
    end
  end
end
