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

RSpec.describe('deploy.rb') do
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

    it 'defines LOAD_BALANCED_INSTANCES as frozen array' do
      expect(LOAD_BALANCED_INSTANCES).to(eq(%w[api grpc]))
      expect(LOAD_BALANCED_INSTANCES).to(be_frozen)
    end

    it 'defines ACTIVE_STACK_STATUSES as frozen array' do
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

  describe '#find_standalone_instance' do
    let(:ec2) { Aws::EC2::Resource.new(stub_responses: true) }
    let(:options) { { instance: 'api', environment: 'beta' } }

    it 'finds a matching standalone instance' do
      ec2.client.stub_responses(
        :describe_instances,
        {
          reservations: [
            {
              instances: [
                {
                  instance_id: 'i-abc123',
                  state: { code: 16, name: 'running' },
                  tags: [{ key: 'Name', value: 'api-beta1-standalone' }]
                }
              ]
            }
          ]
        }
      )
      instance_id, instance_name = find_standalone_instance(ec2, options)
      expect(instance_id).to(eq('i-abc123'))
      expect(instance_name).to(eq('api-beta1-standalone'))
    end

    it 'raises when no matching instance found' do
      ec2.client.stub_responses(
        :describe_instances,
        {
          reservations: [
            {
              instances: [
                {
                  instance_id: 'i-xyz789',
                  state: { code: 16, name: 'running' },
                  tags: [{ key: 'Name', value: 'worker-prod1-standalone' }]
                }
              ]
            }
          ]
        }
      )
      expect { find_standalone_instance(ec2, options) }
        .to(raise_error(RuntimeError, 'Unable to find standalone instance'))
    end

    it 'skips terminated instances' do
      ec2.client.stub_responses(
        :describe_instances,
        {
          reservations: [
            {
              instances: [
                {
                  instance_id: 'i-abc123',
                  state: { code: 48, name: 'terminated' },
                  tags: [{ key: 'Name', value: 'api-beta1-standalone' }]
                }
              ]
            }
          ]
        }
      )
      expect { find_standalone_instance(ec2, options) }
        .to(raise_error(RuntimeError, 'Unable to find standalone instance'))
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

    it 'uses max_attempts 1024 for worker instances' do
      worker_options = { instance: 'worker' }
      allow(Aws::EC2::Waiters::ImageAvailable).to(receive(:new).and_call_original)
      create_ami(ec2, 'i-abc123', 'worker-beta1-standalone', worker_options)
      expect(Aws::EC2::Waiters::ImageAvailable).to(have_received(:new).with(hash_including(max_attempts: 1024)))
    end

    it 'uses max_attempts 256 for non-worker instances' do
      allow(Aws::EC2::Waiters::ImageAvailable).to(receive(:new).and_call_original)
      create_ami(ec2, 'i-abc123', 'api-beta1-standalone', options)
      expect(Aws::EC2::Waiters::ImageAvailable).to(have_received(:new).with(hash_including(max_attempts: 256)))
    end
  end

  describe '#find_auto_scaling_group' do
    let(:asg_resources) { Aws::AutoScaling::Resource.new(stub_responses: true) }
    let(:options) { { environment: 'beta', instance: 'api' } }

    it 'finds a matching ASG' do
      asg_resources.client.stub_responses(
        :describe_auto_scaling_groups,
        {
          auto_scaling_groups: [
            {
              auto_scaling_group_name: 'beta1-api-asg',
              min_size: 1,
              max_size: 4,
              desired_capacity: 2,
              default_cooldown: 300,
              availability_zones: ['us-east-1a'],
              health_check_type: 'EC2',
              created_time: Time.now
            }
          ]
        }
      )
      result = find_auto_scaling_group(asg_resources, options)
      expect(result[:name]).to(eq('beta1-api-asg'))
      expect(result[:desired_capacity]).to(eq(2))
      expect(result[:min_size]).to(eq(1))
      expect(result[:max_size]).to(eq(4))
    end

    it 'raises when no ASG found' do
      asg_resources.client.stub_responses(
        :describe_auto_scaling_groups,
        {
          auto_scaling_groups: [
            {
              auto_scaling_group_name: 'prod1-worker-asg',
              min_size: 1,
              max_size: 4,
              desired_capacity: 2,
              default_cooldown: 300,
              availability_zones: ['us-east-1a'],
              health_check_type: 'EC2',
              created_time: Time.now
            }
          ]
        }
      )
      expect { find_auto_scaling_group(asg_resources, options) }
        .to(raise_error(RuntimeError, 'Unable to find auto scaling group'))
    end
  end

  describe '#find_target_group' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    it 'finds target group for api instance' do
      options = { environment: 'beta', instance: 'api' }
      elb.stub_responses(
        :describe_target_groups,
        {
          target_groups: [
            { target_group_name: 'beta1-443', target_group_arn: 'arn:aws:tg/beta1-443' }
          ]
        }
      )
      result = find_target_group(elb, options)
      expect(result).to(eq('arn:aws:tg/beta1-443'))
    end

    it 'finds target group for grpc instance' do
      options = { environment: 'beta', instance: 'grpc' }
      elb.stub_responses(
        :describe_target_groups,
        {
          target_groups: [
            { target_group_name: 'beta1-8443-HTTP2', target_group_arn: 'arn:aws:tg/beta1-8443' }
          ]
        }
      )
      result = find_target_group(elb, options)
      expect(result).to(eq('arn:aws:tg/beta1-8443'))
    end

    it 'raises when no target group found' do
      options = { environment: 'beta', instance: 'api' }
      elb.stub_responses(:describe_target_groups, { target_groups: [] })
      expect { find_target_group(elb, options) }
        .to(raise_error(RuntimeError, 'Unable to find load balancer target group'))
    end
  end

  describe '#find_cloudformation_stack' do
    let(:cfn)     { Aws::CloudFormation::Client.new(stub_responses: true) }
    let(:options) { { environment: 'beta' }                               }

    it 'finds a matching stack' do
      cfn.stub_responses(
        :list_stacks,
        {
          stack_summaries: [
            { stack_name: 'beta1-StackInstances-abc', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }
          ]
        }
      )
      result = find_cloudformation_stack(cfn, options)
      expect(result).to(eq('beta1-StackInstances-abc'))
    end

    it 'raises when no stack found' do
      cfn.stub_responses(:list_stacks, { stack_summaries: [] })
      expect { find_cloudformation_stack(cfn, options) }
        .to(raise_error(RuntimeError, 'Unable to find cloudformation stack'))
    end
  end

  describe '#find_matching_distribution' do
    let(:cloudfront) { Aws::CloudFront::Client.new(stub_responses: true) }

    it 'finds a distribution matching the environment' do
      cloudfront.stub_responses(
        :list_distributions,
        {
          distribution_list: {
            marker: '',
            max_items: 100,
            is_truncated: false,
            quantity: 1,
            items: [build_distribution_item]
          }
        }
      )
      result = find_matching_distribution(cloudfront, 'beta')
      expect(result.id).to(eq('DIST123'))
    end

    it 'returns nil when no distribution matches' do
      cloudfront.stub_responses(
        :list_distributions,
        {
          distribution_list: {
            marker: '',
            max_items: 100,
            is_truncated: false,
            quantity: 1,
            items: [
              build_distribution_item(
                id: 'DIST456',
                arn: 'arn:aws:cloudfront::123:distribution/DIST456',
                domain_name: 'd456.cloudfront.net',
                aliases: { quantity: 1, items: ['prod.example.com'] }
              )
            ]
          }
        }
      )
      result = find_matching_distribution(cloudfront, 'beta')
      expect(result).to(be_nil)
    end
  end

  describe '#update_ssm_parameters' do
    let(:ssm)     { Aws::SSM::Client.new(stub_responses: true)        }
    let(:prefix)  { 'API'                                             }
    let(:ami_id)  { 'ami-12345678'                                    }
    let(:asg)     { { min_size: 1, max_size: 4, desired_capacity: 2 } }
    let(:options) { { type: 't3.micro' }                              }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:put_parameter).and_call_original)
    end

    it 'updates matching parameters via SSM' do
      parameter = double('parameter', parameter_key: 'APIImageId', parameter_value: nil, use_previous_value: nil)
      allow(parameter).to(receive(:parameter_value=))
      allow(parameter).to(receive(:use_previous_value=))
      update_ssm_parameters([parameter], prefix, ami_id, asg, options, 'beta', 1)
      expect(ssm).to(have_received(:put_parameter).with(hash_including(value: 'ami-12345678')))
    end

    it 'marks ignored parameters with use_previous_value' do
      parameter = double('parameter', parameter_key: 'DbPassword')
      allow(parameter).to(receive(:parameter_value=))
      allow(parameter).to(receive(:use_previous_value=))
      update_ssm_parameters([parameter], prefix, ami_id, asg, options, 'beta', 1)
      expect(parameter).to(have_received(:parameter_value=).with(nil))
      expect(parameter).to(have_received(:use_previous_value=).with(true))
    end
  end

  describe '#wait_for_healthy_instances' do
    let(:elb) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

    before do
      allow(self).to(receive(:sleep))
    end

    it 'waits until all targets are healthy' do
      unhealthy_response = {
        target_health_descriptions: [
          { target: { id: 'i-1' }, target_health: { state: 'healthy' } },
          { target: { id: 'i-2' }, target_health: { state: 'unhealthy' } }
        ]
      }
      healthy_response = {
        target_health_descriptions: [
          { target: { id: 'i-1' }, target_health: { state: 'healthy' } },
          { target: { id: 'i-2' }, target_health: { state: 'healthy' } }
        ]
      }
      elb.stub_responses(:describe_target_health, [unhealthy_response, healthy_response])
      wait_for_healthy_instances(elb, 'arn:aws:tg/test')
      expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
    end
  end

  describe '#wait_for_asg_instance_count' do
    let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true) }

    before do
      allow(self).to(receive(:sleep))
    end

    it 'waits until instance count matches target' do
      first_response = {
        auto_scaling_groups: [
          {
            auto_scaling_group_name: 'test-asg',
            min_size: 1,
            max_size: 4,
            desired_capacity: 2,
            default_cooldown: 300,
            availability_zones: ['us-east-1a'],
            health_check_type: 'EC2',
            created_time: Time.now,
            instances: [{ instance_id: 'i-1', lifecycle_state: 'InService', availability_zone: 'us-east-1a', health_status: 'Healthy', protected_from_scale_in: false }]
          }
        ]
      }
      second_response = {
        auto_scaling_groups: [
          {
            auto_scaling_group_name: 'test-asg',
            min_size: 1,
            max_size: 4,
            desired_capacity: 2,
            default_cooldown: 300,
            availability_zones: ['us-east-1a'],
            health_check_type: 'EC2',
            created_time: Time.now,
            instances: [
              { instance_id: 'i-1', lifecycle_state: 'InService', availability_zone: 'us-east-1a', health_status: 'Healthy', protected_from_scale_in: false },
              { instance_id: 'i-2', lifecycle_state: 'InService', availability_zone: 'us-east-1a', health_status: 'Healthy', protected_from_scale_in: false }
            ]
          }
        ]
      }
      asg_client.stub_responses(:describe_auto_scaling_groups, [first_response, second_response])
      wait_for_asg_instance_count(asg_client, 'test-asg', 2)
      expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
    end

    it 'raises when ASG cannot be described' do
      asg_client.stub_responses(:describe_auto_scaling_groups, { auto_scaling_groups: [] })
      expect { wait_for_asg_instance_count(asg_client, 'missing-asg', 2) }
        .to(raise_error(RuntimeError, /Unable to describe ASG/))
    end
  end

  describe '#wait_for_stack_update' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true) }

    before do
      allow(self).to(receive(:sleep))
    end

    it 'waits until stack update is complete' do
      cfn.stub_responses(
        :describe_stacks,
        [
          { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_IN_PROGRESS', creation_time: Time.now }] },
          { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }
        ]
      )
      wait_for_stack_update(cfn, 'test')
      expect(self).to(have_received(:sleep).with(POLL_INTERVAL).twice)
    end

    it 'raises when stack update fails' do
      cfn.stub_responses(
        :describe_stacks,
        { stacks: [{ stack_name: 'test', stack_status: 'UPDATE_FAILED', creation_time: Time.now }] }
      )
      expect { wait_for_stack_update(cfn, 'test') }
        .to(raise_error(RuntimeError, 'Stack update failed'))
    end

    it 'raises when stack cannot be described' do
      cfn.stub_responses(:describe_stacks, { stacks: [] })
      expect { wait_for_stack_update(cfn, 'test') }
        .to(raise_error(RuntimeError, /Unable to describe stack/))
    end
  end

  describe '#update_cloudformation_stack' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true) }

    before do
      allow(self).to(receive(:sleep))
      allow(cfn).to(receive(:update_stack).and_call_original)
      cfn.stub_responses(
        :describe_stacks,
        { stacks: [{ stack_name: 'test-stack', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }
      )
    end

    it 'updates the stack and waits for completion' do
      update_cloudformation_stack(cfn, 'test-stack', [], 'API', 'ami-123')
      expect(cfn).to(have_received(:update_stack).with(hash_including(stack_name: 'test-stack')))
    end

    it 'exits gracefully on ValidationError' do
      allow(cfn).to(receive(:update_stack).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'No updates')))
      expect { update_cloudformation_stack(cfn, 'test-stack', [], 'API', 'ami-123') }
        .to(raise_error(SystemExit))
    end
  end

  describe '#fetch_asg_mixed_parameters' do
    let(:ssm) { Aws::SSM::Client.new(stub_responses: true) }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
    end

    it 'returns percent_above and base_capacity' do
      ssm.stub_responses(
        :get_parameters,
        {
          parameters: [
            { name: '/beta/1/OnDemandPercentAbove', value: '100' },
            { name: '/beta/1/OnDemandBaseCapacity', value: '2' }
          ]
        }
      )
      result = fetch_asg_mixed_parameters('beta', 1)
      expect(result[:percent_above]).to(eq('100'))
      expect(result[:base_capacity]).to(eq('2'))
    end

    it 'raises when OnDemandPercentAbove is missing' do
      ssm.stub_responses(
        :get_parameters,
        {
          parameters: [
            { name: '/beta/1/OnDemandBaseCapacity', value: '2' }
          ]
        }
      )
      expect { fetch_asg_mixed_parameters('beta', 1) }
        .to(raise_error(RuntimeError, /OnDemandPercentAbove/))
    end

    it 'raises when OnDemandBaseCapacity is missing' do
      ssm.stub_responses(
        :get_parameters,
        {
          parameters: [
            { name: '/beta/1/OnDemandPercentAbove', value: '100' }
          ]
        }
      )
      expect { fetch_asg_mixed_parameters('beta', 1) }
        .to(raise_error(RuntimeError, /OnDemandBaseCapacity/))
    end
  end

  describe '#update_asg_capacity' do
    let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true) }

    before do
      allow(asg_client).to(receive(:update_auto_scaling_group).and_call_original)
    end

    it 'updates ASG with base_capacity and percent_above' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100')
      expect(asg_client).to(
        have_received(:update_auto_scaling_group).with(
          hash_including(
            auto_scaling_group_name: 'test-asg',
            mixed_instances_policy: {
              instances_distribution: {
                on_demand_base_capacity: '2',
                on_demand_percentage_above_base_capacity: '100'
              }
            }
          )
        )
      )
    end

    it 'includes desired_capacity when provided' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100', desired_capacity: 4)
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(desired_capacity: 4)))
    end

    it 'includes max_size when provided' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100', max_size: 8)
      expect(asg_client).to(have_received(:update_auto_scaling_group).with(hash_including(max_size: 8)))
    end

    it 'excludes desired_capacity and max_size when nil' do
      update_asg_capacity(asg_client, 'test-asg', base_capacity: '2', percent_above: '100')
      expect(asg_client).to(have_received(:update_auto_scaling_group)) do |params|
        expect(params).not_to(have_key(:desired_capacity))
        expect(params).not_to(have_key(:max_size))
      end
    end
  end

  describe '#publish_lambda_and_update_cloudfront' do
    let(:lambda_client) { Aws::Lambda::Client.new(stub_responses: true) }
    let(:cloudfront) { Aws::CloudFront::Client.new(stub_responses: true)              }
    let(:options)    { { environment: 'beta', lambda_publish_version: 'my-function' } }

    before do
      allow(Aws::Lambda::Client).to(receive(:new).and_return(lambda_client))
      allow(Aws::CloudFront::Client).to(receive(:new).and_return(cloudfront))
      allow(lambda_client).to(receive(:publish_version).and_call_original)
      allow(cloudfront).to(receive(:update_distribution).and_call_original)
      lambda_client.stub_responses(:publish_version, { function_arn: 'arn:aws:lambda:us-east-1:123:function:my-function:1' })
    end

    it 'publishes lambda version and updates matching distribution' do
      cloudfront.stub_responses(
        :list_distributions,
        {
          distribution_list: {
            marker: '',
            max_items: 100,
            is_truncated: false,
            quantity: 1,
            items: [
              build_distribution_item(
                default_cache_behavior: {
                  target_origin_id: 'origin1',
                  viewer_protocol_policy: 'redirect-to-https',
                  allowed_methods: { quantity: 2, items: %w[GET HEAD] },
                  forwarded_values: { query_string: false, cookies: { forward: 'none' } },
                  min_ttl: 0,
                  lambda_function_associations: { quantity: 0, items: [] }
                }
              )
            ]
          }
        }
      )
      cloudfront.stub_responses(
        :get_distribution_config,
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
              lambda_function_associations: { quantity: 0, items: [] }
            },
            comment: '',
            enabled: true
          }
        }
      )
      publish_lambda_and_update_cloudfront(options)
      expect(lambda_client).to(have_received(:publish_version))
      expect(cloudfront).to(have_received(:update_distribution))
    end

    it 'raises when no distribution matches' do
      cloudfront.stub_responses(
        :list_distributions,
        {
          distribution_list: {
            marker: '',
            max_items: 100,
            is_truncated: false,
            quantity: 0,
            items: []
          }
        }
      )
      expect { publish_lambda_and_update_cloudfront(options) }
        .to(raise_error(RuntimeError, 'Unable to find cloudfront distribution'))
    end
  end

  describe '#update_distribution_lambda' do
    let(:cloudfront) { Aws::CloudFront::Client.new(stub_responses: true) }
    let(:function_arn) { 'arn:aws:lambda:us-east-1:123:function:test:1' }

    before do
      allow(cloudfront).to(receive(:get_distribution_config).and_call_original)
      allow(cloudfront).to(receive(:update_distribution).and_call_original)
    end

    it 'skips update when ARN already matches' do
      distribution = double(
        'distribution',
        id: 'DIST123',
        default_cache_behavior: double(
          'cache_behavior',
          lambda_function_associations: double(
            'associations',
            quantity: 1,
            items: [double('item', lambda_function_arn: function_arn)]
          )
        )
      )
      update_distribution_lambda(cloudfront, distribution, function_arn)
      expect(cloudfront).not_to(have_received(:get_distribution_config))
    end

    it 'updates existing association with new ARN' do
      distribution = double(
        'distribution',
        id: 'DIST123',
        default_cache_behavior: double(
          'cache_behavior',
          lambda_function_associations: double(
            'associations',
            quantity: 1,
            items: [double('item', lambda_function_arn: 'arn:aws:lambda:us-east-1:123:function:old:1')]
          )
        )
      )
      cloudfront.stub_responses(
        :get_distribution_config,
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
              lambda_function_associations: {
                quantity: 1,
                items: [{ event_type: 'viewer-request', include_body: false, lambda_function_arn: 'arn:aws:lambda:old:1' }]
              }
            },
            comment: '',
            enabled: true
          }
        }
      )
      update_distribution_lambda(cloudfront, distribution, function_arn)
      expect(cloudfront).to(have_received(:update_distribution))
    end

    it 'updates when no existing association' do
      distribution = double(
        'distribution',
        id: 'DIST123',
        default_cache_behavior: double(
          'cache_behavior',
          lambda_function_associations: double(
            'associations',
            quantity: 0,
            items: []
          )
        )
      )
      cloudfront.stub_responses(
        :get_distribution_config,
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
              lambda_function_associations: { quantity: 0, items: [] }
            },
            comment: '',
            enabled: true
          }
        }
      )
      update_distribution_lambda(cloudfront, distribution, function_arn)
      expect(cloudfront).to(have_received(:update_distribution))
    end
  end
end
