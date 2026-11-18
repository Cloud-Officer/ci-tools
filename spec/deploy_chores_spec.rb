# frozen_string_literal: true

module DeployChores; end

RSpec.describe(DeployChores) do
  let(:ec2)        { Aws::EC2::Client.new(stub_responses: true)               }
  let(:codedeploy) { Aws::CodeDeploy::Client.new(stub_responses: true)        }
  let(:ssm)        { Aws::SSM::Client.new(stub_responses: true)               }
  let(:cfn)        { Aws::CloudFormation::Client.new(stub_responses: true)    }

  before do
    allow(Aws::EC2::Client).to(receive(:new).and_return(ec2))
    allow(Aws::CodeDeploy::Client).to(receive(:new).and_return(codedeploy))
    allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
    allow(Aws::CloudFormation::Client).to(receive(:new).and_return(cfn))
    allow(self).to(receive(:sleep))
    allow($stdin).to(receive(:tty?).and_return(false))
  end

  def options
    { profile: 'dev', environment: 'beta1', instance: 'api' }
  end

  def string_keys(**pairs)
    pairs.transform_keys(&:to_s)
  end

  def interrupt_and_wait(thread, reached, gate = nil)
    reached.pop
    thread.raise(Interrupt)
    gate&.push(true)
    join_quietly(thread)
  end

  def dry_options
    options.merge('dry-run': true)
  end

  def standalone
    %w[i-api api-beta1-standalone]
  end

  def standalones
    string_keys(api: standalone)
  end

  def clients
    { codedeploy: codedeploy, ec2: ec2 }
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
    $stderr.string
  ensure
    $stderr = original
  end

  def answer(text)
    allow($stdin).to(receive_messages(tty?: true, gets: text))
  end

  def requests(client, operation)
    client.api_requests.select { |request| request[:operation_name] == operation }
  end

  def ec2_instance(id, name: "#{id}-name", state: 'running', type: 't3.small')
    { instance_id: id, instance_type: type, architecture: 'x86_64', state: { name: state }, tags: [{ key: 'Name', value: name }, { key: 'CodeDeploy', value: 'api' }] }
  end

  def ec2_page(*ids)
    { reservations: [{ instances: ids.map { |id| ec2_instance(id) } }] }
  end

  def stub_instances(*instances)
    ec2.stub_responses(:describe_instances, { reservations: [{ instances: instances }] })
  end

  def stub_group(**info)
    codedeploy.stub_responses(:get_deployment_group, { deployment_group_info: { ec2_tag_filters: [{ key: 'CodeDeploy', value: 'api', type: 'KEY_AND_VALUE' }] }.merge(info) })
  end

  def check_targets(check_options = options)
    check_deployment_group_targets(clients, 'api', 'beta', standalone, check_options)
  end

  def deployment(id, creator: 'user', created: Time.at(100))
    { deployment_id: id, creator: creator, create_time: created, application_name: 'api', deployment_group_name: 'beta', revision: { revision_type: 'S3' } }
  end

  def resize_job(**resize)
    AmiJob.new('api', standalone.last, resize: { from: 't3.small', to: 'm5.large', running: true }.merge(resize))
  end

  def stack_parameter(key)
    Aws::CloudFormation::Types::Parameter.new(parameter_key: key, parameter_value: "/beta/1/#{key}")
  end

  def reset_ctx(keys = RESET_PARAMETERS)
    { stack_name: 'beta1-StackInstances-X', parameters: keys.map { |key| stack_parameter(key) }, secret_parameter_keys: [], ssm_prefix: '/beta/1' }
  end

  def stub_reset_values(value = '1')
    ssm.stub_responses(:get_parameters, { parameters: RESET_PARAMETERS.map { |key| { name: "/beta/1/#{key}", value: value } } })
  end

  def written_values
    requests(ssm, :put_parameter).map { |request| request[:params][:value] }
  end

  describe '#ec2_filter_for' do
    {
      KEY_ONLY: { name: 'tag-key', values: ['k'] },
      VALUE_ONLY: { name: 'tag-value', values: ['v'] },
      KEY_AND_VALUE: { name: 'tag:k', values: ['v'] }
    }.each do |type, expected|
      it "translates #{type}" do
        expect(ec2_filter_for(Aws::CodeDeploy::Types::EC2TagFilter.new(key: 'k', value: 'v', type: type.to_s))).to(eq(expected))
      end
    end
  end

  describe '#tag_matches_filter?' do
    let(:tag) { Aws::EC2::Types::Tag.new(key: 'Role', value: 'api-beta') }

    { KEY_ONLY: %w[Role x], VALUE_ONLY: %w[x api-*], KEY_AND_VALUE: %w[Role api-*] }.each do |type, (key, value)|
      it "matches #{type}" do
        expect(tag_matches_filter?(tag, Aws::CodeDeploy::Types::EC2TagFilter.new(key: key, value: value, type: type.to_s))).to(be(true))
      end
    end

    it 'requires the whole value to match' do
      expect(tag_matches_filter?(tag, Aws::CodeDeploy::Types::EC2TagFilter.new(key: 'Role', value: 'api', type: 'KEY_AND_VALUE'))).to(be(false))
    end
  end

  describe '#target_tag_groups' do
    it 'uses the tag set when the group has no plain filters' do
      filter = Aws::CodeDeploy::Types::EC2TagFilter.new(key: 'k', value: 'v', type: 'KEY_AND_VALUE')
      info = Aws::CodeDeploy::Types::DeploymentGroupInfo.new(ec2_tag_filters: [], ec2_tag_set: Aws::CodeDeploy::Types::EC2TagSet.new(ec2_tag_set_list: [[filter], []]))
      expect(target_tag_groups(info)).to(eq([[filter]]))
    end
  end

  describe '#check_deployment_group_targets' do
    before { stub_group }

    it 'accepts a group reaching only the standalone instance' do
      stub_instances(ec2_instance('i-api'))
      expect(requests(ec2, :delete_tags).tap { check_targets }).to(be_empty)
    end

    it 'refuses a group targeting auto scaling groups' do
      stub_group(auto_scaling_groups: [{ name: 'asg' }])
      expect { check_targets }
        .to(raise_error(PreflightError, /auto scaling groups/))
    end

    it 'refuses a group without tag filters' do
      stub_group(ec2_tag_filters: [])
      expect { check_targets }
        .to(raise_error(PreflightError, /no EC2 tag filters/))
    end

    it 'refuses a group that misses the standalone instance' do
      stub_instances(ec2_instance('i-other'))
      expect { check_targets }
        .to(raise_error(PreflightError, /expected only api-beta1-standalone/))
    end

    it "refuses to touch another environment's standalone instance" do
      stub_instances(ec2_instance('i-api'), ec2_instance('i-rc', name: 'api-beta2-standalone'))
      expect { check_targets }
        .to(raise_error(PreflightError, /another environment's standalone/))
    end

    context 'with an extra target' do
      before { stub_instances(ec2_instance('i-api'), ec2_instance('i-extra')) }

      it 'stops without a terminal' do
        expect { quietly { check_targets } }
          .to(raise_error(PreflightError, /would deploy to i-api, i-extra/))
      end

      it 'only reports with --dry-run' do
        expect(quietly { check_targets(dry_options) }).to(include('DRY RUN'))
      end

      it 'continues without removing tags when told to' do
        answer('1')
        quietly { check_targets }
        expect(requests(ec2, :delete_tags)).to(be_empty)
      end

      it 'stops when cancelled' do
        answer('')
        expect { quietly { check_targets } }
          .to(raise_error(PreflightError, /aborted/))
      end

      it 'removes only the matching tags of the extra instance when confirmed' do
        answer('2')
        ec2.stub_responses(:describe_instances, [ec2_page('i-api', 'i-extra'), ec2_page('i-extra'), ec2_page('i-api')])
        quietly { check_targets }
        expect(requests(ec2, :delete_tags).first[:params]).to(eq({ resources: ['i-extra'], tags: [{ key: 'CodeDeploy', value: 'api' }] }))
      end

      it 'stops when the tags keep matching' do
        answer('2')
        expect { quietly { check_targets } }
          .to(raise_error(PreflightError, /still targets/))
      end
    end
  end

  describe '#remove_codedeploy_tags' do
    it 'never calls delete_tags without tags, which would delete them all' do
      extras = string_keys('i-extra': { name: 'x', tags: [] })
      expect { remove_codedeploy_tags(ec2, extras) }
        .to(raise_error(PreflightError, /No CodeDeploy tag/))
    end
  end

  describe '#find_redeployments' do
    before do
      stub_group
      stub_instances(ec2_instance('i-api'))
      codedeploy.stub_responses(:list_deployments, { deployments: %w[d-1 d-2 d-3] })
    end

    it 'picks the newest user-triggered deployment' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [deployment('d-1'), deployment('d-2', created: Time.at(200)), deployment('d-3', creator: 'autoscaling', created: Time.at(300))] })
      redeployments = nil
      capture_stdout { redeployments = find_redeployments(standalones, options) }
      expect(redeployments['api'].deployment_id).to(eq('d-2'))
    end

    it 'stops when no deployment is eligible' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [deployment('d-1', creator: 'autoscaling')] })
      expect { find_redeployments(standalones, options) }
        .to(raise_error(PreflightError, /No successful user-triggered/))
    end

    it 'leaves the instance out of a dry run when no deployment is eligible' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [] })
      redeployments = nil
      quietly { redeployments = find_redeployments(standalones, dry_options) }
      expect(redeployments).to(be_empty)
    end

    it 'stops on a missing deployment group' do
      codedeploy.stub_responses(:get_deployment_group, 'DeploymentGroupDoesNotExistException')
      expect { find_redeployments(standalones, options) }
        .to(raise_error(PreflightError, %r{api/beta}))
    end
  end

  describe '#standalone_environment' do
    it 'reads the exact environment from the instance name' do
      expect(standalone_environment('api', 'api-beta1-standalone')).to(eq('beta1'))
    end
  end

  describe '#wait_for_environment_stacks' do
    def stacks(status, name: 'beta1-StackInstances-X')
      { stack_summaries: [{ stack_name: name, stack_status: status, creation_time: Time.at(0) }] }
    end

    it 'waits for a busy stack' do
      cfn.stub_responses(:list_stacks, [stacks('UPDATE_IN_PROGRESS'), stacks('UPDATE_COMPLETE')])
      expect { |block| wait_for_environment_stacks('beta1', &block) }
        .to(yield_control.once)
    end

    it 'stops on a failed stack' do
      cfn.stub_responses(:list_stacks, stacks('UPDATE_ROLLBACK_FAILED'))
      expect { wait_for_environment_stacks('beta1') }
        .to(raise_error(/fix it before CodeDeploy runs/))
    end

    it 'ignores the stacks of a longer environment name' do
      cfn.stub_responses(:list_stacks, stacks('UPDATE_ROLLBACK_FAILED', name: 'beta11-StackInstances-X'))
      expect { wait_for_environment_stacks('beta1') }
        .not_to(raise_error)
    end

    it 'gives up after the timeout' do
      cfn.stub_responses(:list_stacks, stacks('UPDATE_IN_PROGRESS'))
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(STACK_WAIT_TIMEOUT + 1)))
      expect { wait_for_environment_stacks('beta1') { nil } }
        .to(raise_error(/Timed out waiting/))
    end
  end

  describe '#check_environment_stacks' do
    it 'stops before any AMI on a failed stack' do
      cfn.stub_responses(:list_stacks, { stack_summaries: [{ stack_name: 'beta1-X', stack_status: 'UPDATE_FAILED', creation_time: Time.at(0) }] })
      expect { check_environment_stacks(standalones, options) }
        .to(raise_error(PreflightError, /beta1-X is UPDATE_FAILED/))
    end
  end

  describe '#start_deployment' do
    let(:request) { { application_name: 'api', deployment_group_name: 'beta', description: 'run 1' } }

    before { codedeploy.stub_responses(:list_deployments, { deployments: ['d-old'] }) }

    it 'creates the deployment' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [] })
      codedeploy.stub_responses(:create_deployment, { deployment_id: 'd-new' })
      expect(start_deployment(codedeploy, request)).to(eq('d-new'))
    end

    it 'finds a deployment an earlier attempt already started' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [deployment('d-old').merge(description: 'run 1')] })
      expect(start_deployment(codedeploy, request)).to(eq('d-old'))
    end

    it 'finds the deployment after CodeDeploy refuses a repeat' do
      codedeploy.stub_responses(:batch_get_deployments, [{ deployments_info: [] }, { deployments_info: [deployment('d-old').merge(description: 'run 1')] }])
      codedeploy.stub_responses(:create_deployment, 'DeploymentLimitExceededException')
      expect(start_deployment(codedeploy, request)).to(eq('d-old'))
    end

    it 'raises the refusal when nothing was started' do
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [] })
      codedeploy.stub_responses(:create_deployment, 'DeploymentLimitExceededException')
      expect { start_deployment(codedeploy, request) }
        .to(raise_error(Aws::CodeDeploy::Errors::DeploymentLimitExceededException))
    end

    it 'lets a transient refusal go through the retries' do
      allow(self).to(receive(:transient_error?).and_return(true))
      codedeploy.stub_responses(:batch_get_deployments, { deployments_info: [] })
      codedeploy.stub_responses(:create_deployment, ['ThrottlingException', { deployment_id: 'd-new' }])
      expect(quietly { start_deployment(codedeploy, request) }).to(include('retrying'))
    end
  end

  describe '#wait_for_deployment' do
    it 'returns once the deployment succeeds' do
      codedeploy.stub_responses(:get_deployment, [{ deployment_info: { status: 'InProgress' } }, { deployment_info: { status: 'Succeeded' } }])
      wait_for_deployment(codedeploy, 'd-1')
      expect(requests(codedeploy, :get_deployment).size).to(eq(2))
    end

    it 'raises with the reason of a failed deployment' do
      codedeploy.stub_responses(:get_deployment, { deployment_info: { status: 'Failed', error_information: { message: 'script failed' } } })
      expect { wait_for_deployment(codedeploy, 'd-1') }
        .to(raise_error(/d-1 is Failed: script failed/))
    end

    it 'gives up after the timeout' do
      codedeploy.stub_responses(:get_deployment, { deployment_info: { status: 'InProgress' } })
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0), Time.at(CODEDEPLOY_TIMEOUT + 1)))
      expect { wait_for_deployment(codedeploy, 'd-1') }
        .to(raise_error(/Timed out waiting for CodeDeploy/))
    end
  end

  describe '#redeploy_and_check' do
    let(:job) { AmiJob.new('api', standalone.last, redeployment: Aws::CodeDeploy::Types::DeploymentInfo.new(deployment('d-1').merge(revision: Aws::CodeDeploy::Types::RevisionLocation.new(revision_type: 'S3'))), log_marker: 'done') }

    before do
      allow(self).to(receive(:wait_for_environment_stacks).and_yield(string_keys('beta1-X': 'UPDATE_IN_PROGRESS')))
      allow(self).to(receive_messages(start_deployment: 'd-2', wait_for_deployment: nil))
    end

    it 'reruns the previous revision and checks the log' do
      allow(self).to(receive(:codedeploy_log_failures).and_return([]))
      redeploy_and_check(standalone, job)
      expect(self).to(have_received(:start_deployment).with(codedeploy, hash_including(application_name: 'api', description: /redeploy d-1 \(run /)))
    end

    it 'fails the build when the log check fails' do
      allow(self).to(receive(:codedeploy_log_failures).and_return(['api: no marker']))
      expect { redeploy_and_check(standalone, job) }
        .to(raise_error(/CodeDeploy check failed: api: no marker/))
    end
  end

  describe '#plan_resizes' do
    before do
      ec2.stub_responses(:describe_instance_types, { instance_types: [{ processor_info: { supported_architectures: ['x86_64'] } }] })
      stub_instances(ec2_instance('i-api', state: 'stopped'))
    end

    def resizes(type, plan_options = options)
      plan = nil
      capture_stdout { plan = plan_resizes(standalones, plan_options.merge(resize: type)) }
      plan
    end

    it 'does nothing without --resize' do
      expect(plan_resizes(standalones, options)).to(eq({}))
    end

    it 'records the type and power state to restore' do
      expect(resizes('m5.large')['api']).to(eq({ from: 't3.small', to: 'm5.large', running: false }))
    end

    it 'skips an instance already of that type' do
      expect(resizes('t3.small')).to(be_empty)
    end

    it 'stops on another architecture' do
      ec2.stub_responses(:describe_instance_types, { instance_types: [{ processor_info: { supported_architectures: ['arm64'] } }] })
      expect { resizes('m6g.large') }
        .to(raise_error(PreflightError, /is x86_64, m6g.large is arm64/))
    end

    it 'stops on an unknown type' do
      ec2.stub_responses(:describe_instance_types, 'InvalidInstanceType')
      expect { resizes('nope') }
        .to(raise_error(PreflightError, /--resize nope/))
    end

    it 'stops when AWS lists no such type' do
      ec2.stub_responses(:describe_instance_types, { instance_types: [] })
      expect { resizes('nope') }
        .to(raise_error(PreflightError, /no such instance type/))
    end

    it 'only reports an unknown type with --dry-run' do
      ec2.stub_responses(:describe_instance_types, { instance_types: [] })
      expect(quietly { resizes('nope', dry_options) }).to(include('DRY RUN'))
    end
  end

  describe '#resize_instance' do
    before do
      ec2.stub_responses(:describe_instances, [{ reservations: [{ instances: [ec2_instance('i-api', state: 'stopping')] }] }, { reservations: [{ instances: [ec2_instance('i-api', state: 'stopped')] }] }, { reservations: [{ instances: [ec2_instance('i-api')] }] }])
      ssm.stub_responses(:describe_instance_information, { instance_information_list: [{ ping_status: 'Online', last_ping_date_time: Time.now + 60 }] })
    end

    def operations
      ec2.api_requests.map { |request| request[:operation_name] } - [:describe_instances]
    end

    it 'stops, changes the type and starts the instance' do
      resize_instance('i-api', 'm5.large', start: true)
      expect(operations).to(eq(%i[stop_instances modify_instance_attribute start_instances]))
    end

    it 'leaves the instance stopped when asked' do
      resize_instance('i-api', 't3.small', start: false)
      expect(operations).not_to(include(:start_instances))
    end

    it 'retries the stop while the instance is still starting' do
      ec2.stub_responses(:stop_instances, ['IncorrectInstanceState', {}])
      resize_instance('i-api', 't3.small', start: false)
      expect(requests(ec2, :stop_instances).size).to(eq(2))
    end

    it 'gives up on a stop that stays refused' do
      ec2.stub_responses(:stop_instances, 'IncorrectInstanceState')
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(RESIZE_TIMEOUT + 1)))
      expect { resize_instance('i-api', 't3.small', start: false) }
        .to(raise_error(Aws::EC2::Errors::IncorrectInstanceState))
    end
  end

  describe '#wait_for_instance_state' do
    it 'gives up after the deadline' do
      stub_instances(ec2_instance('i-api', state: 'stopping'))
      expect { wait_for_instance_state(ec2, 'i-api', 'stopped', Time.now - 1) }
        .to(raise_error(/Timed out waiting for i-api to be stopped/))
    end
  end

  describe '#wait_for_ssm_online' do
    it 'ignores a ping from before the restart' do
      ssm.stub_responses(:describe_instance_information, [{ instance_information_list: [{ ping_status: 'Online', last_ping_date_time: Time.at(5) }] }, { instance_information_list: [{ ping_status: 'Online', last_ping_date_time: Time.at(20) }] }])
      wait_for_ssm_online('i-api', Time.at(10), Time.now + 60)
      expect(requests(ssm, :describe_instance_information).size).to(eq(2))
    end

    it 'gives up after the deadline' do
      ssm.stub_responses(:describe_instance_information, { instance_information_list: [] })
      expect { wait_for_ssm_online('i-api', Time.at(10), Time.now - 1) }
        .to(raise_error(/back online in SSM/))
    end
  end

  describe '#restore_standalone_size' do
    let(:job) { resize_job }

    before { allow(self).to(receive(:resize_instance)) }

    it 'does nothing when the instance was not resized' do
      restore_standalone_size(standalone, job)
      expect(self).not_to(have_received(:resize_instance))
    end

    it 'restores the type and the power state' do
      job.update(resized: true)
      restore_standalone_size(standalone, resize_job(running: false).tap { |stopped| stopped.update(resized: true) })
      expect(self).to(have_received(:resize_instance).with('i-api', 't3.small', start: false))
    end

    it 'keeps the state the build ended in' do
      job.update(resized: true, state: 'available')
      restore_standalone_size(standalone, job)
      expect(job.snapshot).to(include(state: 'available', resized: false))
    end

    it 'prints the manual commands when the restore fails' do
      job.update(resized: true)
      allow(self).to(receive(:resize_instance).and_raise('stuck'))
      expect(quietly { restore_standalone_size(standalone, job) }).to(match(/modify-instance-attribute .*--instance-id i-api --instance-type t3\.small/))
    end

    it 'records the failed restore on the job' do
      job.update(resized: true)
      allow(self).to(receive(:resize_instance).and_raise('stuck'))
      quietly { restore_standalone_size(standalone, job) }
      expect(job.snapshot[:error]).to(include('Could not put api-beta1-standalone back'))
    end
  end

  describe '#manual_resize_commands' do
    it 'names the profile and restarts an instance that was running' do
      allow(Aws).to(receive(:config).and_return({ profile: 'dev' }))
      expect(manual_resize_commands('i-api', { from: 't3.small', running: true })).to(end_with('aws ec2 start-instances --profile dev --instance-ids i-api'))
    end
  end

  describe '#build_ami' do
    let(:job) { resize_job }

    before { allow(self).to(receive_messages(resize_instance: nil, create_ami: 'ami-new')) }

    def image_builder
      Aws::EC2::Resource.new(client: ec2)
    end

    def hold_restore(entered, gate)
      allow(self).to(receive(:resize_standalone)) { job.update(resized: true) }
      allow(self).to(receive(:resize_instance)) { entered.push(true) && gate.pop }
    end

    def attempt_build
      build_ami(image_builder, standalone, options, job)
    rescue RuntimeError
      nil
    end

    def restore_call
      have_received(:resize_instance).with('i-api', 't3.small', start: true)
    end

    it 'resizes before the image and restores after it' do
      build_ami(image_builder, standalone, options, job)
      expect(self).to(have_received(:resize_instance).with('i-api', 't3.small', start: true))
    end

    it 'returns the new AMI' do
      expect(build_ami(image_builder, standalone, options, job)).to(eq('ami-new'))
    end

    it 'restores the size after a failed build' do
      allow(self).to(receive(:create_ami).and_raise('no image'))
      attempt_build
      expect(self).to(restore_call)
    end

    it 'marks a failed build' do
      allow(self).to(receive(:create_ami).and_raise('no image'))
      attempt_build
      expect(job.snapshot[:error]).to(eq('no image'))
    end

    it 'restores the size when the build is interrupted' do
      started = Queue.new
      allow(self).to(receive(:create_ami)) { started.push(true) && Queue.new.pop }
      interrupt_and_wait(start_thread { build_ami(image_builder, standalone, options, job) }, started)
      expect(self).to(restore_call)
    end

    it 'finishes a restore already under way when interrupted' do
      entered = Queue.new
      gate = Queue.new
      hold_restore(entered, gate)
      interrupt_and_wait(start_thread { build_ami(image_builder, standalone, options, job) }, entered, gate)
      expect(job.snapshot[:resized]).to(be(false))
    end

    it 'redeploys when the job has a redeployment' do
      allow(self).to(receive(:redeploy_and_check))
      redeploying = AmiJob.new('api', standalone.last, redeployment: :previous)
      build_ami(image_builder, standalone, options, redeploying)
      expect(self).to(have_received(:redeploy_and_check).with(standalone, redeploying))
    end
  end

  describe '#join_quietly' do
    it 'keeps waiting through a second signal while the thread runs' do
      thread = instance_double(Thread, alive?: true)
      calls = 0
      allow(thread).to(receive(:join)) { (calls += 1) == 1 ? raise(Interrupt) : thread }
      quietly { join_quietly(thread) }
      expect(calls).to(eq(2))
    end
  end

  describe '#plan_standalone_chores' do
    before { allow(self).to(receive(:deploy_config).and_return({})) }

    it 'plans nothing without the options' do
      expect(plan_standalone_chores(standalones, options)).to(eq({}))
    end

    it 'warns when there is no AMI to build' do
      expect { plan_standalone_chores({}, options.merge(resize: 'm5.large')) }
        .to(output(/only apply to the AMIs/).to_stderr)
    end

    it 'gives each job its redeployment, size and log marker' do
      allow(self).to(receive_messages(plan_resizes: {}, check_environment_stacks: nil, refuse_stopped_redeploys: nil, find_redeployments: string_keys(api: :previous)))
      expect(plan_standalone_chores(standalones, options.merge('redeploy-latest': true))['api']).to(eq({ resize: nil, redeployment: :previous, log_marker: DEFAULT_LOG_MARKER }))
    end

    it 'refuses to redeploy on a stopped instance' do
      stub_instances(ec2_instance('i-api', state: 'stopped'))
      expect { plan_standalone_chores(standalones, options.merge('redeploy-latest': true)) }
        .to(raise_error(PreflightError, /needs a running instance/))
    end

    it 'allows a stopped instance that --resize starts' do
      expect(refuse_stopped_redeploys(standalones, standalones, options)).to(be_nil)
    end
  end

  describe '#check_standalones with --redeploy-latest' do
    it 'leaves the log check to the redeploy' do
      allow(self).to(receive_messages(running_standalones: standalones, wait_for_standalones: nil, verify_codedeploy_logs: nil))
      check_standalones(standalones, options.merge('redeploy-latest': true))
      expect(self).not_to(have_received(:verify_codedeploy_logs))
    end
  end

  describe '#wait_for_standalones with --reset-instances' do
    it 'waits for the new instances without asking' do
      allow($stdin).to(receive(:tty?).and_return(true))
      ec2.stub_responses(:describe_tags, [{ tags: [] }, { tags: [{ resource_id: 'i-api' }] }])
      allow(self).to(receive(:wait_for_unready?))
      quietly { wait_for_standalones(ec2, standalones, options.merge('reset-instances': true)) }
      expect(self).not_to(have_received(:wait_for_unready?))
    end
  end

  describe '#reset_standalone_instances' do
    before do
      stub_reset_values
      allow(self).to(receive_messages(discover_cfn_stack_context: reset_ctx, apply_stack_update: :updated))
    end

    def attempt_reset
      capture_stdout { reset_standalone_instances(options) }
    rescue Aws::SSM::Errors::AccessDeniedException
      nil
    end

    it 'disables then enables the instances with one waited update each' do
      capture_stdout { reset_standalone_instances(options) }
      expect(written_values).to(eq(%w[0 0 1 1]))
    end

    it 'updates the stack twice' do
      capture_stdout { reset_standalone_instances(options) }
      expect(self).to(have_received(:apply_stack_update).twice)
    end

    it 'accepts a stack already at the wanted value' do
      allow(self).to(receive(:apply_stack_update).and_return(:no_updates))
      expect(capture_stdout { reset_standalone_instances(options) }).to(include('already has them at 1'))
    end

    it 'changes nothing with --dry-run' do
      capture_stdout { reset_standalone_instances(dry_options) }
      expect(written_values).to(be_empty)
    end

    it 'stops when the stack lacks the parameters' do
      allow(self).to(receive(:discover_cfn_stack_context).and_return(reset_ctx(['InstanceEnabled'])))
      expect { reset_standalone_instances(options) }
        .to(raise_error(PreflightError, /no WorkerInstanceEnabled parameter/))
    end

    it 'stops before writing when an SSM parameter is missing' do
      ssm.stub_responses(:get_parameters, { parameters: [{ name: '/beta/1/InstanceEnabled', value: '1' }] })
      expect { capture_stdout { reset_standalone_instances(options) } }
        .to(raise_error(PreflightError, /Missing SSM parameters/))
    end

    it 'restores SSM when a write fails' do
      ssm.stub_responses(:put_parameter, [{}, 'AccessDeniedException', {}, {}])
      attempt_reset
      expect(written_values.last(2)).to(eq(%w[1 1]))
    end

    context 'when the second update fails' do
      before do
        calls = 0
        allow(self).to(receive(:apply_stack_update)) { (calls += 1) == 2 ? raise('stack failed') : :updated }
        ssm.stub_responses(:get_parameters, [{ parameters: RESET_PARAMETERS.map { |key| { name: "/beta/1/#{key}", value: '1' } } }, { parameters: RESET_PARAMETERS.map { |key| { name: "/beta/1/#{key}", value: '0' } } }])
      end

      def failed_reset
        quietly { reset_standalone_instances(options) }
      rescue RuntimeError => e
        e
      end

      it 'raises the failure' do
        expect(failed_reset.message).to(eq('stack failed'))
      end

      it 'rolls SSM back to the disabled value' do
        failed_reset
        expect(written_values.last(2)).to(eq(%w[0 0]))
      end

      it 'says the instances may still be disabled' do
        allow(self).to(receive(:log_warn))
        failed_reset
        expect(self).to(have_received(:log_warn).with(/may still be disabled/))
      end
    end
  end

  describe '#deploy_instances with --reset-instances' do
    before { allow(self).to(receive_messages(check_for_other_deploys: nil, reset_standalone_instances: nil)) }

    it 'stops after the reset without an instance' do
      expect(capture_stdout { deploy_instances({ environment: 'beta1', profile: 'dev', 'reset-instances': true }) }).to(include('No instance to deploy'))
    end

    it 'checks for other deploys before destroying anything' do
      capture_stdout { deploy_instances({ environment: 'beta1', profile: 'dev', 'reset-instances': true }) }
      expect(self).to(have_received(:check_for_other_deploys).ordered.with([], {}, nil, anything))
    end
  end

  describe '#print_dry_run_plan with chores' do
    it 'shows the resize and the redeploy' do
      chores = string_keys(api: { resize: { from: 't3.small', to: 'm5.large' }, redeployment: Aws::CodeDeploy::Types::DeploymentInfo.new(deployment_id: 'd-1') })
      expect(capture_stdout { print_dry_run_plan(['api'], standalones, nil, options, chores) }).to(include('resized to m5.large (then back to t3.small) after redeploying d-1'))
    end
  end

  describe '#parse_deploy_options' do
    def base
      %w[--environment beta1 --profile dev]
    end

    def usage_error(*extra)
      output = StringIO.new
      original = $stderr
      $stderr = output
      begin
        parse_deploy_options(base + extra)
      rescue SystemExit
        output.string
      ensure
        $stderr = original
      end
    end

    it 'allows --reset-instances without an instance' do
      expect(parse_deploy_options(base + %w[--reset-instances])).to(include('reset-instances': true))
    end

    it 'still requires an instance otherwise' do
      expect(usage_error).to(include('missing argument: instance'))
    end

    it 'requires an instance for --redeploy-latest with --reset-instances' do
      expect(usage_error('--reset-instances', '--redeploy-latest')).to(include('missing argument: instance'))
    end

    it 'requires a redeploy or AMIs after a reset' do
      expect(usage_error('--reset-instances', '--instance', 'api')).to(include('leaves blank standalone instances'))
    end

    it 'accepts AMIs for every instance after a reset' do
      expect(parse_deploy_options(base + %w[--reset-instances --instance api --ami ami-1])).to(include(ami: 'ami-1'))
    end

    it 'refuses a reset with a lambda publish' do
      expect(usage_error('--reset-instances', '--lambda_publish_version', 'fn')).to(include('cannot be used with --lambda_publish_version'))
    end

    it 'keeps --type alongside --resize' do
      expect(parse_deploy_options(base + %w[--instance api --type t3.large --resize m5.large])).to(include(type: 't3.large', resize: 'm5.large'))
    end
  end

  describe 'DeployPermissions.required' do
    def required(extra, building: true)
      DeployPermissions.required(options.merge(extra), load_balanced: false, building: building).values.flatten
    end

    it 'lists the CodeDeploy write access of a redeploy' do
      expect(required({ 'redeploy-latest': true })).to(include('codedeploy:CreateDeployment'))
    end

    it 'lists the EC2 access of a resize' do
      expect(required({ resize: 'm5.large' })).to(include('ec2:StopInstances', 'ec2:StartInstances', 'ec2:ModifyInstanceAttribute'))
    end

    it 'needs neither without a build' do
      expect(required({ 'redeploy-latest': true, resize: 'm5.large' }, building: false)).not_to(include('codedeploy:CreateDeployment', 'ec2:StopInstances'))
    end

    it 'needs only the stack access for a reset without an instance' do
      expect(required({ 'reset-instances': true, instance: nil }, building: false)).not_to(include('autoscaling:UpdateAutoScalingGroup'))
    end
  end
end
