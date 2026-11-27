# frozen_string_literal: true

module DeployRollout; end

RSpec.describe(DeployRollout) do
  let(:asg_client) { Aws::AutoScaling::Client.new(stub_responses: true)                 }
  let(:ec2)        { Aws::EC2::Client.new(stub_responses: true)                         }
  let(:asg)        { { name: 'asg-api', desired_capacity: 2, min_size: 1, max_size: 4 } }
  let(:factors)    { { asg_increase: 1, asg_multiplier: 2 }                             }

  before do
    allow(Aws::EC2::Client).to(receive(:new).and_return(ec2))
    allow(self).to(receive(:sleep))
  end

  def baseline_tag(value = 'desired=2,max=4')
    { resource_id: 'asg-api', resource_type: 'auto-scaling-group', key: ASG_BASELINE_TAG, value: value, propagate_at_launch: false }
  end

  def group_data(ids, desired: 2, max: 4, tags: [], state: 'InService')
    instances = ids.map { |id| { instance_id: id, lifecycle_state: state, availability_zone: 'a', health_status: 'Healthy', protected_from_scale_in: false } }
    { auto_scaling_groups: [{ auto_scaling_group_name: 'asg-api', min_size: 1, max_size: max, desired_capacity: desired, default_cooldown: 300, availability_zones: ['a'], health_check_type: 'EC2', created_time: Time.at(0), instances: instances, tags: tags }] }
  end

  def stub_group(*ids, **attributes)
    asg_client.stub_responses(:describe_auto_scaling_groups, group_data(ids, **attributes))
  end

  def images(**by_id)
    { reservations: [{ instances: by_id.map { |id, ami| { instance_id: id.to_s, image_id: ami } } }] }
  end

  def deploy(options = {})
    DeployContext.new(options: { instance: 'worker' }.merge(options), asg: asg, ami_id: 'ami-new', stack: {})
  end

  def rollout(options = {})
    RollingDeploy.new(asg_client: asg_client, asg: asg, mixed_params: { base_capacity: '1', percent_above: '50' }, elb: nil, target_group_arn: nil, options: { instance: 'worker' }.merge(options))
  end

  def plan_rollout(attempt_factors = factors)
    result = nil
    capture_stdout { result = plan_instance_rollout(asg_client, deploy, attempt_factors) }
    result
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
    $stderr.string
  ensure
    $stderr = original
  end

  def requests(client, operation)
    client.api_requests.select { |request| request[:operation_name] == operation }
  end

  def capacity_updates
    requests(asg_client, :update_auto_scaling_group).map { |request| request[:params] }
  end

  describe '#asg_baseline' do
    it 'reads the capacity from before an unfinished rollout' do
      tag = Aws::AutoScaling::Types::TagDescription.new(baseline_tag)
      expect(asg_baseline([tag], 1)).to(eq({ desired_capacity: 2, max_size: 4 }))
    end

    it 'is nil without the tag' do
      expect(asg_baseline(nil, 1)).to(be_nil)
    end

    it 'stops on a tag it cannot read' do
      tag = Aws::AutoScaling::Types::TagDescription.new(baseline_tag('desired=2'))
      expect { asg_baseline([tag], 1) }
        .to(raise_error(PreflightError, /is invalid/))
    end

    %w[desired=0,max=4 desired=3,max=2].each do |value|
      it "refuses the impossible capacity #{value}" do
        tag = Aws::AutoScaling::Types::TagDescription.new(baseline_tag(value))
        expect { asg_baseline([tag], 1) }
          .to(raise_error(PreflightError, /is invalid/))
      end
    end
  end

  describe '#find_auto_scaling_group' do
    let(:resources) { Aws::AutoScaling::Resource.new(client: asg_client) }

    def stub_named_group(**attributes)
      data = group_data([], **attributes)
      data[:auto_scaling_groups].first[:auto_scaling_group_name] = 'stack-api-X'
      asg_client.stub_responses(:describe_auto_scaling_groups, data)
    end

    def found
      result = nil
      quietly { result = find_auto_scaling_group(resources, 'stack', { instance: 'api' }) }
      result
    end

    it 'does not take an inflated capacity as the new baseline' do
      stub_named_group(desired: 5, max: 5, tags: [baseline_tag])
      expect(found).to(include(desired_capacity: 2, max_size: 4))
    end

    it 'uses the live capacity without an unfinished rollout' do
      stub_named_group(desired: 3, max: 6)
      expect(found).to(include(desired_capacity: 3, max_size: 6))
    end
  end

  describe '#describe_asg' do
    it 'raises when the group is gone' do
      asg_client.stub_responses(:describe_auto_scaling_groups, { auto_scaling_groups: [] })
      expect { describe_asg(asg_client, 'asg-api') }
        .to(raise_error(/Unable to describe ASG asg-api/))
    end
  end

  describe '#stale_instance_ids' do
    def group(state: 'InService')
      Aws::AutoScaling::Types::AutoScalingGroup.new(auto_scaling_group_name: 'asg-api', instances: [Aws::AutoScaling::Types::Instance.new(instance_id: 'i-1', lifecycle_state: state)])
    end

    it 'lists the instances on another AMI' do
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old'))
      expect(stale_instance_ids(group, 'ami-new')).to(eq(['i-1']))
    end

    it 'skips the instances on the new AMI' do
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-new'))
      expect(stale_instance_ids(group, 'ami-new')).to(be_empty)
    end

    it 'ignores instances on their way out' do
      stale_instance_ids(group(state: 'Terminating'), 'ami-new')
      expect(ec2.api_requests).to(be_empty)
    end
  end

  describe '#plan_instance_rollout' do
    it 'leaves alone a group CloudFormation already replaced' do
      stub_group('i-1', 'i-2')
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-new', 'i-2': 'ami-new'))
      expect(plan_rollout).to(be_nil)
    end

    it 'doubles a group left on the old AMI, plus the increase' do
      stub_group('i-1', 'i-2')
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old', 'i-2': 'ami-old'))
      expect(plan_rollout).to(eq({ new_capacity: 5, new_max: 9 }))
    end

    it 'adds new capacity on top of an inflated group on another AMI' do
      stub_group('i-1', 'i-2', 'i-3', 'i-4', 'i-5', desired: 5, max: 5, tags: [baseline_tag])
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old', 'i-2': 'ami-old', 'i-3': 'ami-old', 'i-4': 'ami-old', 'i-5': 'ami-old'))
      expect(plan_rollout).to(eq({ new_capacity: 8, new_max: 9 }))
    end

    it 'never plans below the capacity already running' do
      stub_group('i-1', 'i-2', desired: 7, max: 9, tags: [baseline_tag])
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old', 'i-2': 'ami-new'))
      expect(plan_rollout[:new_capacity]).to(eq(7))
    end

    it 'only scales down an unfinished rollout whose instances are all new' do
      stub_group('i-1', desired: 5, max: 5, tags: [baseline_tag])
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-new'))
      expect(plan_rollout).to(eq({ new_capacity: 2, new_max: nil }))
    end

    it 'adds nothing with --preserve_desired_capacity' do
      stub_group('i-1', 'i-2')
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old', 'i-2': 'ami-old'))
      expect(plan_rollout({ asg_increase: 0, asg_multiplier: 1 })).to(eq({ new_capacity: 2, new_max: nil }))
    end
  end

  describe '#scale_up_for_rollout' do
    let(:plan) { { new_capacity: 5, new_max: 9 } }

    before { allow(self).to(receive_messages(wait_for_asg_instance_count: nil, warm_up_after_scale_up: nil)) }

    def attempt_failed_scale_up(attempt_rollout = rollout)
      capture_stdout { scale_up_for_rollout(attempt_rollout, plan) }
    rescue RuntimeError
      nil
    end

    it 'records the capacity before changing it' do
      capture_stdout { scale_up_for_rollout(rollout, plan) }
      expect(asg_client.api_requests.map { |request| request[:operation_name] }).to(eq(%i[create_or_update_tags update_auto_scaling_group]))
    end

    it 'scales up fully on demand' do
      capture_stdout { scale_up_for_rollout(rollout, plan) }
      expect(capacity_updates.first).to(include(desired_capacity: 5, max_size: 9))
    end

    it 'does not wait or record anything without extra capacity' do
      capture_stdout { scale_up_for_rollout(rollout, { new_capacity: 2, new_max: nil }) }
      expect(requests(asg_client, :create_or_update_tags)).to(be_empty)
    end

    [RuntimeError.new('timed out'), Interrupt.new, SignalException.new('TERM')].each do |failure|
      context "when the wait ends with #{failure.class}" do
        before { allow(self).to(receive(:wait_for_asg_instance_count).and_raise(failure)) }

        def attempt
          quietly { scale_up_for_rollout(rollout, plan) }
        rescue StandardError, SignalException
          nil
        end

        it 'leaves the group scaled up' do
          attempt
          expect(capacity_updates.size).to(eq(1))
        end

        it 'keeps the recorded capacity for a rerun' do
          attempt
          expect(requests(asg_client, :delete_tags)).to(be_empty)
        end

        it 're-raises' do
          expect { quietly { scale_up_for_rollout(rollout, plan) } }
            .to(raise_error(failure.class))
        end
      end
    end

    it 'prints the commands and the cost when it fails with --skip-rollback' do
      allow(self).to(receive(:wait_for_asg_instance_count).and_raise('timed out'))
      allow(self).to(receive(:print_scale_down_commands))
      attempt_failed_scale_up(rollout('skip-rollback': true))
      expect(self).to(have_received(:print_scale_down_commands))
    end

    it 'leaves the group to the rollback when it fails' do
      allow(self).to(receive(:wait_for_asg_instance_count).and_raise('timed out'))
      allow(self).to(receive(:print_scale_down_commands))
      attempt_failed_scale_up
      expect(self).not_to(have_received(:print_scale_down_commands))
    end
  end

  describe '#print_scale_down_commands' do
    def printed
      quietly_output = StringIO.new
      original = $stderr
      $stderr = quietly_output
      print_scale_down_commands(rollout)
      quietly_output.string
    ensure
      $stderr = original
    end

    it 'restores the capacity' do
      expect(printed).to(include('--auto-scaling-group-name asg-api --desired-capacity 2 --max-size 4'))
    end

    it 'restores the on-demand setting from SSM, not the temporary 100%' do
      expect(printed).to(include('OnDemandPercentageAboveBaseCapacity\\":50'))
    end

    it 'clears the rollout tag' do
      expect(printed).to(include('delete-tags'))
    end
  end

  describe '#roll_out_instance' do
    let(:plan) { { new_capacity: 5, new_max: 9 } }

    before do
      allow(self).to(receive_messages(plan_instance_rollout: plan, scale_up_for_rollout: nil, run_rolling_deploy_with_capacity_rollback: nil, warn_about_stale_instances: nil))
    end

    def roll_out(options = {})
      capture_stdout { roll_out_instance(asg_client, deploy(options), {}, {}, factors) }
    end

    it 'does nothing for a group needing no rollout' do
      allow(self).to(receive(:plan_instance_rollout).and_return(nil))
      roll_out
      expect(self).not_to(have_received(:scale_up_for_rollout))
    end

    it 'clears the recorded capacity after a finished rollout' do
      roll_out
      expect(requests(asg_client, :delete_tags).size).to(eq(1))
    end

    context 'when the scale-up fails' do
      before do
        allow(self).to(receive(:scale_up_for_rollout).and_raise('failed'))
        begin
          roll_out
        rescue RuntimeError
          nil
        end
      end

      it 'keeps the recorded capacity' do
        expect(requests(asg_client, :delete_tags)).to(be_empty)
      end

      it 'does not start the scale-down' do
        expect(self).not_to(have_received(:run_rolling_deploy_with_capacity_rollback))
      end
    end

    it 'looks for instances left behind' do
      roll_out
      expect(self).to(have_received(:warn_about_stale_instances))
    end

    it 'expects old instances with --skip_scale_down' do
      roll_out(skip_scale_down: true)
      expect(self).not_to(have_received(:warn_about_stale_instances))
    end
  end

  describe '#warn_about_stale_instances' do
    before { stub_group('i-1') }

    it 'warns about instances left on an old AMI' do
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-old'))
      expect { warn_about_stale_instances(asg_client, deploy) }
        .to(output(/still has 1 instance\(s\) on a previous AMI after the scale-down: i-1/).to_stderr)
    end

    it 'stays quiet when every instance is new' do
      ec2.stub_responses(:describe_instances, images('i-1': 'ami-new'))
      expect { warn_about_stale_instances(asg_client, deploy) }
        .not_to(output.to_stderr)
    end
  end

  describe '#run_rolling_deploy_with_capacity_rollback after the scale-up' do
    before { allow(self).to(receive(:scale_down_after_deploy).and_raise('scale-down failed')) }

    def attempt(attempt_rollout = rollout('skip-rollback': true))
      quietly { run_rolling_deploy_with_capacity_rollback(attempt_rollout, { new_capacity: 5, new_max: nil }) }
    rescue RuntimeError
      nil
    end

    it 'restores the baseline capacity with --skip-rollback' do
      attempt
      expect(capacity_updates).to(include(hash_including(desired_capacity: 2, max_size: 4)))
    end

    it 'clears the recorded capacity once restored with --skip-rollback' do
      attempt
      expect(requests(asg_client, :delete_tags).size).to(eq(1))
    end

    it 'leaves the capacity to the rollback, which must not end the old instances first' do
      attempt(rollout)
      expect(capacity_updates).not_to(include(hash_including(desired_capacity: 2)))
    end
  end

  describe '#healthcheck_plan' do
    def options
      { profile: 'dev', environment: 'rc2' }
    end

    def config(healthchecks: nil, retries: nil)
      JSON.parse(JSON.generate({ profiles: { dev: { healthchecks: healthchecks } }, healthcheck_retries: retries }))
    end

    def plan_with(**settings)
      allow(self).to(receive(:deploy_config).and_return(config(**settings)))
      healthcheck_plan(options)
    end

    it 'prefers the exact environment' do
      expect(plan_with(healthchecks: { rc: ['u-family'], rc2: ['u-exact'] })[:urls]).to(eq(['u-exact']))
    end

    it 'falls back to the environment family' do
      expect(plan_with(healthchecks: { rc: ['u-family'] })[:urls]).to(eq(['u-family']))
    end

    it 'has defaults' do
      expect(plan_with).to(eq({ urls: [], interval: HEALTHCHECK_INTERVAL, give_up_after: HEALTHCHECK_GIVE_UP_AFTER }))
    end

    it 'reads the retry settings' do
      expect(plan_with(retries: { interval: 2, give_up_after: 0 })).to(include(interval: 2, give_up_after: 0))
    end

    it 'refuses a zero interval' do
      expect { plan_with(retries: { interval: 0 }) }
        .to(raise_error(PreflightError, /interval/))
    end

    it 'refuses retry settings that are not a mapping' do
      expect { plan_with(retries: 'often') }
        .to(raise_error(PreflightError, /must be a mapping/))
    end

    it 'refuses URLs that are not a list' do
      expect { plan_with(healthchecks: { rc2: 'url' }) }
        .to(raise_error(PreflightError, /list of URLs/))
    end

    it 'refuses a malformed profiles section' do
      allow(self).to(receive(:deploy_config).and_return(JSON.parse(JSON.generate({ profiles: 'x' }))))
      expect { healthcheck_plan(options) }
        .to(raise_error(PreflightError, /malformed/))
    end
  end

  describe '#healthcheck_failure' do
    def curl(out, success: true, err: '')
      allow(Open3).to(receive(:capture3).and_return([out, err, instance_double(Process::Status, success?: success)]))
    end

    it 'accepts a 2xx answer' do
      curl('204')
      expect(healthcheck_failure('https://x')).to(be_nil)
    end

    it 'reports another status' do
      curl('503')
      expect(healthcheck_failure('https://x')).to(eq('HTTP 503'))
    end

    it 'reports a curl failure' do
      curl('000', success: false, err: 'timed out')
      expect(healthcheck_failure('https://x')).to(eq('curl failed: timed out'))
    end

    it 'keeps URL secrets out of a curl error' do
      curl('000', success: false, err: 'bad https://me:pw@x/health?token=abc')
      expect(healthcheck_failure('https://me:pw@x/health?token=abc')).to(eq('curl failed: bad https://x/health'))
    end

    it 'reports a missing curl' do
      allow(Open3).to(receive(:capture3).and_raise(Errno::ENOENT))
      expect(healthcheck_failure('https://x')).to(start_with('curl could not run'))
    end

    it 'passes the URL as a value and limits the protocols' do
      curl('200')
      healthcheck_failure('-x')
      expect(Open3).to(have_received(:capture3).with('curl', '--silent', '--show-error', '--globoff', '--proto', '=http,https', '--output', File::NULL, '--write-out', CURL_STATUS_FORMAT, '--max-time', '15', '--url', '-x'))
    end
  end

  describe '#redacted_url' do
    it 'removes the credentials and the query' do
      expect(redacted_url('https://me:pw@x/health?token=abc')).to(eq('https://x/health'))
    end

    it 'hides a URL it cannot parse' do
      expect(redacted_url('https://bad host/?token=abc')).to(eq('<unparsable URL>'))
    end
  end

  describe '#run_healthchecks' do
    let(:settings) { { urls: %w[https://u1 https://u2], interval: 5, give_up_after: 60 } }

    it 'does nothing without URLs' do
      allow(self).to(receive(:healthcheck_failure))
      run_healthchecks({ urls: [], interval: 5, give_up_after: 60 })
      expect(self).not_to(have_received(:healthcheck_failure))
    end

    it 'retries only the failing URL until it recovers' do
      answers = JSON.parse(JSON.generate({ 'https://u1': [nil], 'https://u2': ['HTTP 503', nil] }))
      allow(self).to(receive(:healthcheck_failure)) { |url| answers[url].shift }
      quietly { run_healthchecks(settings) }
      expect(self).to(have_received(:healthcheck_failure).with('https://u2').twice)
    end

    it 'gives up with a warning without failing the deploy' do
      allow(self).to(receive(:healthcheck_failure).and_return('HTTP 503'))
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0), Time.at(61)))
      expect(quietly { run_healthchecks(settings) }).to(include('giving up on health check https://u1'))
    end
  end

  describe 'DeployPermissions.required' do
    it 'lists the rollout tag and instance access' do
      needs = DeployPermissions.required({ instance: 'api' }, load_balanced: false, building: false).values.flatten
      expect(needs).to(include('autoscaling:CreateOrUpdateTags', 'autoscaling:DeleteTags', 'ec2:DescribeInstances'))
    end
  end
end
