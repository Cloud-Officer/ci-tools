# frozen_string_literal: true

module DeployRollback; end

RSpec.describe(DeployRollback) do
  let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true)            }
  let(:ec2)        { Aws::EC2::Client.new(stub_responses: true)                    }
  let(:ssm)        { Aws::SSM::Client.new(stub_responses: true, retry_limit: 0)    }
  let(:elb)        { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

  before do
    allow(Aws::EC2::Client).to(receive(:new).and_return(ec2))
    allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
    allow(self).to(receive(:sleep))
  end

  def asg
    { name: 'asg-api', desired_capacity: 2, min_size: 1, max_size: 4 }
  end

  def mixed
    { base_capacity: '1', percent_above: '50' }
  end

  def by_name(**pairs)
    pairs.transform_keys(&:to_s)
  end

  def group_data(states, desired:, max: 4)
    instances = states.map { |id, state| { instance_id: id.to_s, lifecycle_state: state, availability_zone: 'a', health_status: 'Healthy', protected_from_scale_in: false } }
    { auto_scaling_groups: [{ auto_scaling_group_name: 'asg-api', min_size: 1, max_size: max, desired_capacity: desired, default_cooldown: 300, availability_zones: ['a'], health_check_type: 'EC2', created_time: Time.at(0), instances: instances, tags: [] }] }
  end

  def images(**by_id)
    { reservations: [{ instances: by_id.map { |id, ami| { instance_id: id.to_s, image_id: ami } } }] }
  end

  def deploy(instance: 'worker', **options)
    DeployContext.new(options: { instance: instance, profile: 'dev', environment: 'beta1' }.merge(options), asg: asg, ami_id: 'ami-new', stack: { stack_name: 'beta1-Instances', parameters: [] })
  end

  def rollout(instance: 'worker', **options)
    RollingDeploy.new(asg_client: asg_client, asg: asg, mixed_params: mixed, elb: elb, target_group_arn: 'arn:tg', options: { instance: instance, profile: 'dev', environment: 'beta1' }.merge(options), ami_id: 'ami-new')
  end

  def requests(client, operation)
    client.api_requests.filter_map { |request| request[:params] if request[:operation_name] == operation }
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
    $stderr.string
  ensure
    $stderr = original
  end

  describe '#roll_back_instance' do
    def target
      { elb: nil, target_group_arn: nil }
    end

    context 'with instances on the failed AMI' do
      before do
        asg_client.stub_responses(:describe_auto_scaling_groups, [group_data({ 'i-old1': 'InService', 'i-old2': 'InService', 'i-bad': 'InService' }, desired: 3), group_data({ 'i-old1': 'InService', 'i-old2': 'InService', 'i-bad': 'InService', 'i-rep': 'InService' }, desired: 4), group_data({ 'i-old1': 'InService', 'i-rep': 'InService' }, desired: 2)])
        ec2.stub_responses(:describe_instances, images('i-old1': 'ami-old', 'i-old2': 'ami-old', 'i-bad': 'ami-new'))
        quietly { roll_back_instance(asg_client, deploy, target, mixed) }
      end

      it 'adds one replacement per failed instance on demand before removing any' do
        expect(requests(asg_client, :update_auto_scaling_group).first).to(include(desired_capacity: 4, max_size: 4, mixed_instances_policy: { instances_distribution: { on_demand_base_capacity: 1, on_demand_percentage_above_base_capacity: 100 } }))
      end

      it 'terminates only the instances on the failed AMI, lowering the capacity with them' do
        expect(requests(asg_client, :terminate_instance_in_auto_scaling_group)).to(eq([{ instance_id: 'i-bad', should_decrement_desired_capacity: true }]))
      end

      it 'puts the baseline capacity and mixed-instances policy back' do
        expect(requests(asg_client, :update_auto_scaling_group).last).to(include(desired_capacity: 2, max_size: 4, mixed_instances_policy: { instances_distribution: { on_demand_base_capacity: 1, on_demand_percentage_above_base_capacity: 50 } }))
      end

      it 'clears the recorded rollout capacity' do
        expect(requests(asg_client, :delete_tags).size).to(eq(1))
      end
    end

    context 'without instances on the failed AMI' do
      before do
        asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-old1': 'InService', 'i-old2': 'InService' }, desired: 2))
        ec2.stub_responses(:describe_instances, images('i-old1': 'ami-old', 'i-old2': 'ami-old'))
        quietly { roll_back_instance(asg_client, deploy, target, mixed) }
      end

      it 'terminates nothing' do
        expect(requests(asg_client, :terminate_instance_in_auto_scaling_group)).to(be_empty)
      end

      it 'only puts the baseline capacity back' do
        expect(requests(asg_client, :update_auto_scaling_group)).to(contain_exactly(include(desired_capacity: 2, max_size: 4)))
      end
    end

    it 'waits for healthy targets on a load-balanced group' do
      asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-old1': 'InService', 'i-old2': 'InService' }, desired: 2))
      ec2.stub_responses(:describe_instances, images('i-old1': 'ami-old', 'i-old2': 'ami-old'))
      allow(self).to(receive(:wait_for_healthy_instances))
      quietly { roll_back_instance(asg_client, deploy(instance: 'api'), { elb: elb, target_group_arn: 'arn:tg' }, mixed) }
      expect(self).to(have_received(:wait_for_healthy_instances).with(elb, 'arn:tg'))
    end
  end

  describe '#replace_failed_instances' do
    it 'grows max size when the replacements need it' do
      allow(self).to(receive(:wait_for_replacements))
      group = Aws::AutoScaling::Types::AutoScalingGroup.new(desired_capacity: 4, max_size: 4)
      quietly { replace_failed_instances(rollout, group, %w[i-1 i-2]) }
      expect(requests(asg_client, :update_auto_scaling_group).first).to(include(desired_capacity: 6, max_size: 6))
    end

    it 'waits for no more healthy instances than the group had' do
      allow(self).to(receive(:wait_for_replacements))
      group = Aws::AutoScaling::Types::AutoScalingGroup.new(desired_capacity: 1, max_size: 4)
      quietly { replace_failed_instances(rollout, group, %w[i-1]) }
      expect(self).to(have_received(:wait_for_replacements).with(anything, %w[i-1], 1))
    end
  end

  describe '#wait_for_replacements' do
    it 'counts in-service instances that did not fail' do
      asg_client.stub_responses(:describe_auto_scaling_groups, [group_data({ 'i-bad': 'InService', 'i-rep': 'Pending' }, desired: 2), group_data({ 'i-bad': 'InService', 'i-rep': 'InService' }, desired: 2)])
      quietly { wait_for_replacements(rollout, %w[i-bad], 1) }
      expect(asg_client.api_requests.size).to(eq(2))
    end

    it 'counts only healthy targets on a load-balanced group' do
      asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-bad': 'InService', 'i-rep': 'InService' }, desired: 2))
      elb.stub_responses(:describe_target_health, [{ target_health_descriptions: [{ target: { id: 'i-rep' }, target_health: { state: 'initial' } }] }, { target_health_descriptions: [{ target: { id: 'i-rep' }, target_health: { state: 'healthy' } }] }])
      quietly { wait_for_replacements(rollout(instance: 'api'), %w[i-bad], 1) }
      expect(elb.api_requests.size).to(eq(2))
    end

    it 'times out when the replacements never come' do
      stub_const('MAX_POLL_ATTEMPTS', 2)
      asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-bad': 'InService' }, desired: 2))
      expect { quietly { wait_for_replacements(rollout, %w[i-bad], 1) } }
        .to(raise_error(/Timed out waiting for 1 healthy instance/))
    end
  end

  describe '#terminate_failed_instance' do
    it 'carries on when the instance is already gone' do
      asg_client.stub_responses(:terminate_instance_in_auto_scaling_group, 'ValidationError')
      expect(quietly { terminate_failed_instance(asg_client, 'i-gone') }).to(include('Could not terminate i-gone'))
    end
  end

  describe '#roll_back_deploy' do
    let(:cfn) { instance_double(Aws::CloudFormation::Client) }

    def targets
      { cfn: cfn, ctx: { parameters: [:params] }, asg_resources: instance_double(Aws::AutoScaling::Resource, client: asg_client), instances: by_name(api: :target_api, worker: :target_worker) }
    end

    def deploys
      by_name(api: deploy(instance: 'api'), worker: deploy)
    end

    before do
      allow(self).to(receive(:apply_stack_update).and_return(:updated))
      allow(self).to(receive(:roll_back_instance))
    end

    it 'puts the previous SSM values back' do
      quietly { roll_back_deploy(targets, deploys, by_name('/beta/1/APIImageId': 'ami-old'), mixed) }
      expect(requests(ssm, :put_parameter)).to(eq([{ name: '/beta/1/APIImageId', value: 'ami-old', type: 'String', overwrite: true }]))
    end

    it 'updates the stack so the launch templates use them' do
      quietly { roll_back_deploy(targets, deploys, {}, mixed) }
      expect(self).to(have_received(:apply_stack_update).with(cfn, 'beta1-Instances', [:params]))
    end

    it 'rolls back every group of the stack', :aggregate_failures do
      quietly { roll_back_deploy(targets, deploys, {}, mixed) }
      expect(self).to(have_received(:roll_back_instance).with(asg_client, deploy(instance: 'api'), :target_api, mixed))
      expect(self).to(have_received(:roll_back_instance).with(asg_client, deploy, :target_worker, mixed))
    end

    it 'stops before the stack when the SSM values cannot be put back', :aggregate_failures do
      ssm.stub_responses(:put_parameter, 'AccessDeniedException')
      expect { quietly { roll_back_deploy(targets, deploys, by_name('/beta/1/APIImageId': 'ami-old'), mixed) } }
        .to(raise_error(Aws::SSM::Errors::AccessDeniedException))
      expect(self).not_to(have_received(:apply_stack_update))
    end
  end

  describe '#roll_back_after' do
    let(:events) { [] }

    before { allow(self).to(receive(:notify)) { |event, **payload| events << [event, payload] } }

    it 'reports a clean rollback', :aggregate_failures do
      allow(self).to(receive(:roll_back_deploy))
      expect { quietly { roll_back_after(RuntimeError.new('unhealthy'), {}, {}, {}, mixed) } }
        .to(raise_error(DeployErrors::RolledBack, 'Deploy failed and was rolled back to the previous AMIs: unhealthy'))
      expect(events).to(eq([[:rollback_started, { error: 'unhealthy' }], [:rollback_done, { error: 'unhealthy' }]]))
    end

    it 'needs a human when the rollback fails', :aggregate_failures do
      allow(self).to(receive(:roll_back_deploy).and_raise('stack failed'))
      expect { quietly { roll_back_after(RuntimeError.new('unhealthy'), {}, {}, {}, mixed) } }
        .to(raise_error(DeployErrors::NeedsHuman, /Deploy failed \(unhealthy\) and so did its rollback \(stack failed\)/))
      expect(events.last).to(eq([:rollback_failed, { error: 'unhealthy', rollback_error: 'stack failed' }]))
    end
  end

  describe '#update_stack_or_escalate' do
    def deploys
      [deploy]
    end

    it 'needs a human when the stack outcome is unknown' do
      allow(self).to(receive(:update_stack_with_ssm_rollback).and_raise(Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new)))
      expect { update_stack_or_escalate(nil, deploys, {}) }
        .to(raise_error(DeployErrors::NeedsHuman, /beta1-Instances may still be running/))
    end

    it 're-raises a stack failure' do
      allow(self).to(receive(:update_stack_with_ssm_rollback).and_raise('UPDATE_ROLLBACK_COMPLETE'))
      expect { update_stack_or_escalate(nil, deploys, {}) }
        .to(raise_error(RuntimeError, 'UPDATE_ROLLBACK_COMPLETE'))
    end

    it 'returns the stack result' do
      allow(self).to(receive(:update_stack_with_ssm_rollback).and_return(:updated))
      expect(update_stack_or_escalate(nil, deploys, {})).to(eq(:updated))
    end
  end

  describe '#run_healthchecks' do
    let(:plan) { { urls: ['https://api.example.com/health'], interval: 1, give_up_after: 0 } }

    before do
      allow(self).to(receive(:notify))
      allow(self).to(receive(:healthcheck_failure).and_return('HTTP 503'))
    end

    it 'fails a strict run when a URL keeps failing' do
      expect { quietly { run_healthchecks(plan, strict: true) } }
        .to(raise_error(RuntimeError, %r{Health checks failed: https://api.example.com/health}))
    end

    it 'only warns otherwise' do
      expect(quietly { run_healthchecks(plan) }).to(include('giving up on health check'))
    end
  end

  describe 'instance health checks' do
    def config(command)
      YAML.safe_load(<<~CONFIG)
        profiles:
          dev:
            instance_healthchecks:
              worker: #{command.to_json}
      CONFIG
    end

    describe '#instance_healthcheck_command' do
      it 'reads the command of the profile and instance' do
        allow(self).to(receive(:deploy_config).and_return(config('systemctl is-active app')))
        expect(instance_healthcheck_command({ profile: 'dev', instance: 'worker' })).to(eq('systemctl is-active app'))
      end

      it 'is nil without one' do
        allow(self).to(receive(:deploy_config).and_return({}))
        expect(instance_healthcheck_command({ profile: 'dev', instance: 'worker' })).to(be_nil)
      end

      [['', 'an empty command'], [['x'], 'a list']].each do |value, label|
        it "refuses #{label}" do
          allow(self).to(receive(:deploy_config).and_return(config(value)))
          expect { instance_healthcheck_command({ profile: 'dev', instance: 'worker' }) }
            .to(raise_error(PreflightError, %r{dev/worker must be a shell command}))
        end
      end

      it 'refuses a malformed profiles section' do
        allow(self).to(receive(:deploy_config).and_return(YAML.safe_load("profiles:\n  dev: x\n")))
        expect { instance_healthcheck_command({ profile: 'dev', instance: 'worker' }) }
          .to(raise_error(PreflightError, /malformed/))
      end
    end

    describe '#check_new_instances' do
      before do
        allow(self).to(receive(:deploy_config).and_return(config('check')))
        allow(self).to(receive(:run_instance_healthcheck))
      end

      it 'checks the in-service instances on the new AMI only' do
        asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-old': 'InService', 'i-new': 'InService', 'i-late': 'Pending' }, desired: 3))
        ec2.stub_responses(:describe_instances, images('i-old': 'ami-old', 'i-new': 'ami-new', 'i-late': 'ami-new'))
        check_new_instances(rollout)
        expect(self).to(have_received(:run_instance_healthcheck).with(ssm, 'asg-api', ['i-new'], 'check', hash_including(:interval, :give_up_after)))
      end

      it 'fails when no instance runs the new AMI' do
        asg_client.stub_responses(:describe_auto_scaling_groups, group_data({ 'i-old': 'InService' }, desired: 1))
        ec2.stub_responses(:describe_instances, images('i-old': 'ami-old'))
        expect { check_new_instances(rollout) }
          .to(raise_error(/No instance of asg-api runs ami-new/))
      end

      it 'does nothing without a configured command' do
        allow(self).to(receive(:deploy_config).and_return({}))
        check_new_instances(rollout)
        expect(asg_client.api_requests).to(be_empty)
      end
    end

    describe '#run_instance_healthcheck' do
      let(:plan) { { interval: 15, give_up_after: 60 } }

      before { ssm.stub_responses(:send_command, { command: { command_id: 'cmd-1' } }) }

      it 'passes once every instance answers success' do
        ssm.stub_responses(:get_command_invocation, [{ status: 'Failed', response_code: 1, standard_error_content: 'inactive' }, { status: 'Success', response_code: 0 }])
        expect(quietly { run_instance_healthcheck(ssm, 'asg-worker', ['i-1'], 'check', plan) }).to(include('i-1: Failed (1) inactive, retrying in 15 s'))
      end

      it 'runs the command with Run Command on the instances' do
        ssm.stub_responses(:get_command_invocation, { status: 'Success', response_code: 0 })
        quietly { run_instance_healthcheck(ssm, 'asg-worker', %w[i-1 i-2], 'check', plan) }
        expect(requests(ssm, :send_command).first).to(include(instance_ids: %w[i-1 i-2], document_name: 'AWS-RunShellScript', parameters: JSON.parse('{"commands":["check"]}')))
      end

      it 'gives up after the configured time' do
        ssm.stub_responses(:get_command_invocation, { status: 'Failed', response_code: 3 })
        expect { quietly { run_instance_healthcheck(ssm, 'asg-worker', ['i-1'], 'check', { interval: 15, give_up_after: 0 }) } }
          .to(raise_error(/Instance health check failed on asg-worker: i-1: Failed \(3\)/))
      end

      it 'keeps trying while SSM cannot reach a new instance' do
        ssm.stub_responses(:send_command, ['InvalidInstanceId', { command: { command_id: 'cmd-1' } }])
        ssm.stub_responses(:get_command_invocation, { status: 'Success', response_code: 0 })
        expect(quietly { run_instance_healthcheck(ssm, 'asg-worker', ['i-1'], 'check', plan) }).to(include('SSM cannot reach it'))
      end
    end
  end

  describe '#deploy_from_cli' do
    let(:events) { [] }

    before do
      allow(self).to(receive_messages(start_run_log: nil, start_plugins: nil, stop_plugins: nil, stop_run_log: nil))
      allow(self).to(receive(:notify)) { |event, **payload| events << [event, payload] }
    end

    def exit_status(error)
      allow(self).to(receive(:run_deployment).and_raise(error))
      quietly { deploy_from_cli({ profile: 'dev', environment: 'beta1' }) }
    rescue SystemExit => e
      e.status
    end

    it 'exits 2 after a clean rollback', :aggregate_failures do
      expect(exit_status(DeployErrors::RolledBack.new('rolled back'))).to(eq(2))
      expect(events.last).to(eq([:deploy_failed, { error: 'rolled back', outcome: 'rolled_back' }]))
    end

    it 'exits 3 when a human must look', :aggregate_failures do
      expect(exit_status(DeployErrors::NeedsHuman.new('stuck'))).to(eq(3))
      expect(events.last).to(eq([:deploy_failed, { error: 'stuck', outcome: 'needs_human' }]))
    end

    it 'exits 1 when it stops before changing anything' do
      expect(exit_status(PreflightError.new('nope'))).to(eq(1))
    end
  end

  describe '#interactive?' do
    before { allow($stdin).to(receive(:tty?).and_return(true)) }

    after { @non_interactive = nil }

    it 'follows the terminal' do
      expect(interactive?).to(be(true))
    end

    it 'never prompts with --non-interactive' do
      @non_interactive = true
      expect(interactive?).to(be(false))
    end

    it 'fails closed on a question with --non-interactive' do
      @non_interactive = true
      expect { quietly { confirm_unchecked_permissions({}, 'no policy') } }
        .to(raise_error(PreflightError, /Could not check your permissions/))
    end
  end

  describe '#parse_deploy_options' do
    it 'reads --non-interactive and --skip-rollback' do
      expect(parse_deploy_options(%w[--profile dev --environment beta1 --instance api --non-interactive --skip-rollback])).to(include('non-interactive': true, 'skip-rollback': true))
    end
  end

  describe 'DeployPermissions.required' do
    def required(options, **)
      DeployPermissions.required({ instance: 'api' }.merge(options), load_balanced: false, building: false, **)
    end

    it 'needs the lock and rollback permissions by default', :aggregate_failures do
      expect(required({})[:'holding the deploy lock']).to(include('ssm:PutParameter', 'ssm:DeleteParameter'))
      expect(required({})[:'rolling back a failed rollout']).to(eq(['autoscaling:TerminateInstanceInAutoScalingGroup']))
    end

    it 'drops them with --skip-lock and --skip-rollback' do
      expect(required({ 'skip-lock': true, 'skip-rollback': true }).keys).not_to(include(:'holding the deploy lock', :'rolling back a failed rollout'))
    end

    it 'needs Run Command for instance health checks' do
      expect(required({}, instance_checks: true)[:'checking the new instances']).to(eq(%w[ssm:SendCommand ssm:GetCommandInvocation]))
    end
  end
end
