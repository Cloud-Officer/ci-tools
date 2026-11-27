# frozen_string_literal: true

require 'tmpdir'

module DeployPreflight; end

RSpec.describe(DeployPreflight) do
  let(:home) { Dir.mktmpdir }

  before do
    allow(self).to(receive(:deploy_directory).and_return(home))
    allow(self).to(receive(:sleep))
    allow($stdin).to(receive(:tty?).and_return(false))
  end

  after { FileUtils.remove_entry(home) }

  def options
    { profile: 'dev', environment: 'beta1', instance: 'api' }
  end

  def dry_options
    options.merge('dry-run': true)
  end

  def string_keys(**pairs)
    pairs.transform_keys(&:to_s)
  end

  def standalones
    string_keys(api: %w[i-api api-beta1-standalone])
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
  ensure
    $stderr = original
  end

  def answer(text)
    allow($stdin).to(receive_messages(tty?: true, gets: text))
  end

  describe '#check_credentials' do
    let(:sts) { Aws::STS::Client.new(stub_responses: true) }

    before { allow(Aws::STS::Client).to(receive(:new).and_return(sts)) }

    it 'returns the caller ARN' do
      sts.stub_responses(:get_caller_identity, { arn: 'arn:aws:iam::1:user/me' })
      expect(check_credentials(options)).to(eq('arn:aws:iam::1:user/me'))
    end

    { InvalidClientTokenId: /refused its credentials/, ExpiredToken: /session has expired/ }.each do |code, message|
      it "stops with one line on #{code}" do
        sts.stub_responses(:get_caller_identity, code.to_s)
        expect { check_credentials(options) }
          .to(raise_error(PreflightError, message))
      end
    end

    it 'stops with one line when the profile is unknown' do
      allow(sts).to(receive(:get_caller_identity).and_raise(Aws::Errors::NoSuchProfileError, 'no profile'))
      expect { check_credentials(options) }
        .to(raise_error(PreflightError, /Cannot use profile 'dev'.*no profile/))
    end

    it 'stops with the sign-in command when the SSO session expired without a terminal' do
      allow(sts).to(receive(:get_caller_identity).and_raise(Aws::Errors::InvalidSSOToken, 'Token is invalid and failed to refresh.'))
      expect { check_credentials(options) }
        .to(raise_error(PreflightError, /Cannot use profile 'dev': its SSO session has expired, sign in with: aws sso login --profile dev/))
    end

    it 'signs in and continues when the SSO session expired with a terminal', :aggregate_failures do
      allow($stdin).to(receive(:tty?).and_return(true))
      allow(AwsSso).to(receive(:system).with('aws', 'sso', 'login', '--profile', 'dev').and_return(true))
      allow(sts).to(receive(:get_caller_identity).and_invoke(->(*) { raise(Aws::Errors::InvalidSSOToken, 'expired') }, ->(*) { Struct.new(:arn).new('arn:aws:sts::1:assumed-role/AWSReservedSSO_Admin_1/me') }))
      expect(quietly { expect(check_credentials(options)).to(eq('arn:aws:sts::1:assumed-role/AWSReservedSSO_Admin_1/me')) }).to(include('signing in'))
      expect(AwsSso).to(have_received(:system).once)
    end

    it 'does not hide unrelated AWS errors' do
      sts.stub_responses(:get_caller_identity, 'InternalFailure')
      expect { check_credentials(options) }
        .to(raise_error(Aws::STS::Errors::ServiceError))
    end
  end

  describe DeployPermissions do
    let(:iam) { Aws::IAM::Client.new(stub_responses: true) }

    it 'needs only lambda and CloudFront actions to publish a lambda' do
      expect(described_class.required({ lambda_publish_version: 'fn' }, load_balanced: true, building: true).values.flatten).to(all(match(/\A(?:lambda|cloudfront):/)))
    end

    it 'covers the stack, rollout and load balancer for a full deploy', :aggregate_failures do
      actions = described_class.required({}, load_balanced: true, building: true).values.flatten
      expect(actions).to(include('ec2:CreateImage', 'ssm:SendCommand', 'codedeploy:ListDeployments', 'cloudformation:UpdateStack', 'autoscaling:UpdateAutoScalingGroup', 'elasticloadbalancing:DescribeTargetHealth'))
    end

    it 'leaves out what an AMI-only run never calls', :aggregate_failures do
      actions = described_class.required({ create_ami_only: true }, load_balanced: true, building: true).values.flatten
      expect(actions).to(include('ec2:CreateImage'))
      expect(actions).not_to(include('cloudformation:UpdateStack', 'elasticloadbalancing:DescribeTargetHealth'))
    end

    it 'leaves out AMI and CodeDeploy actions when they are not used', :aggregate_failures do
      actions = described_class.required({ ami: 'ami-1', 'skip-other-deploy-check': true }, load_balanced: false, building: false).values.flatten
      expect(actions).not_to(include('ec2:CreateImage', 'codedeploy:ListDeployments', 'elasticloadbalancing:DescribeTargetHealth'))
      expect(actions).to(include('cloudformation:UpdateStack'))
    end

    it 'simulates an IAM user directly' do
      expect(described_class.simulation_arn(iam, 'arn:aws:iam::1:user/me')).to(eq('arn:aws:iam::1:user/me'))
    end

    it 'resolves an assumed role to its role ARN' do
      iam.stub_responses(:get_role, { role: { path: '/x/', role_name: 'deploy', role_id: 'AROAEXAMPLE1234567', arn: 'arn:aws:iam::1:role/x/deploy', create_date: Time.now } })
      expect(described_class.simulation_arn(iam, 'arn:aws:sts::1:assumed-role/deploy/session')).to(eq('arn:aws:iam::1:role/x/deploy'))
    end

    it 'builds the role ARN when the role cannot be read' do
      iam.stub_responses(:get_role, 'AccessDenied')
      expect(described_class.simulation_arn(iam, 'arn:aws:sts::1:assumed-role/deploy/session')).to(eq('arn:aws:iam::1:role/deploy'))
    end

    it 'has nothing to simulate for a root or federated caller' do
      expect(described_class.simulation_arn(iam, 'arn:aws:iam::1:root')).to(be_nil)
    end

    it 'returns only the actions that are not allowed' do
      iam.stub_responses(:simulate_principal_policy, { evaluation_results: [{ eval_action_name: 'a:One', eval_decision: 'allowed' }, { eval_action_name: 'a:Two', eval_decision: 'implicitDeny' }] })
      expect(described_class.denied(iam, 'arn', %w[a:One a:Two])).to(eq(%w[a:Two]))
    end
  end

  describe '#check_permissions' do
    let(:iam) { Aws::IAM::Client.new(stub_responses: true) }
    let(:arn) { 'arn:aws:iam::1:user/me' }

    before do
      allow(Aws::IAM::Client).to(receive(:new).and_return(iam))
      iam.stub_responses(:simulate_principal_policy, { evaluation_results: [{ eval_action_name: 'ec2:CreateImage', eval_decision: 'implicitDeny' }] })
    end

    it 'stops and lists what is missing and why' do
      expect { capture_stdout { check_permissions(options, arn) } }
        .to(raise_error(PreflightError, /ec2:CreateImage \(building the AMIs\)/))
    end

    it 'passes when everything is allowed' do
      iam.stub_responses(:simulate_principal_policy, { evaluation_results: [] })
      expect(capture_stdout { check_permissions(options, arn) }).to(include('has the permissions this run needs'))
    end

    it 'only reports missing permissions on a dry run' do
      expect { capture_stdout { check_permissions(dry_options, arn) } }
        .to(output(/DRY RUN: a real run would stop here/).to_stderr)
    end

    it 'skips the simulator with --skip-permission-check', :aggregate_failures do
      expect(capture_stdout { check_permissions(options.merge('skip-permission-check': true), arn) }).to(include('Not checking permissions'))
      expect(Aws::IAM::Client).not_to(have_received(:new))
    end

    context 'when the permissions cannot be simulated' do
      before { iam.stub_responses(:simulate_principal_policy, 'AccessDenied') }

      it 'stops without a terminal and names the flag' do
        expect { quietly { check_permissions(options, arn) } }
          .to(raise_error(PreflightError, /--skip-permission-check/))
      end

      it 'continues when the user accepts' do
        answer("y\n")
        expect { quietly { check_permissions(options, arn) } }
          .not_to(raise_error)
      end

      it 'aborts when the user declines' do
        answer("n\n")
        expect { quietly { check_permissions(options, arn) } }
          .to(raise_error(PreflightError, /aborted/))
      end

      it 'only reports on a dry run' do
        expect { quietly { check_permissions(dry_options, arn) } }
          .not_to(raise_error)
      end
    end

    it 'asks when the caller has no policies to simulate' do
      expect { quietly { check_permissions(options, 'arn:aws:iam::1:root') } }
        .to(raise_error(PreflightError, /no policies to simulate/))
    end
  end

  describe '#with_deploy_lock' do
    let(:ssm)   { Aws::SSM::Client.new(stub_responses: true, retry_limit: 0) }
    let(:store) { {} }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      ssm.stub_responses(:put_parameter, ->(context) { put_lock(context.params) })
      ssm.stub_responses(:get_parameter, ->(context) { store.key?(context.params[:name]) ? { parameter: { name: context.params[:name], value: store[context.params[:name]] } } : 'ParameterNotFound' })
      ssm.stub_responses(:delete_parameter, ->(context) { store.delete(context.params[:name]) ? {} : 'ParameterNotFound' })
    end

    def put_lock(params)
      return 'ParameterAlreadyExists' if store.key?(params[:name]) && !params[:overwrite]

      store[params[:name]] = params[:value]
      { version: 1 }
    end

    def lock_requests(operation)
      ssm.api_requests.select { |request| request[:operation_name] == operation }
    end

    it 'runs the block and returns its value' do
      expect(with_deploy_lock(options) { :done }).to(eq(:done))
    end

    it 'holds an SSM parameter named after the profile and environment while the block runs' do
      with_deploy_lock(options) { expect(store.keys).to(eq(['/deploy-rb/locks/dev/beta1'])) }
    end

    it 'records who holds the lock' do
      with_deploy_lock(options) { expect(store.values.first).to(match(/\Apid #{Process.pid} on .+, started /)) }
    end

    it 'never overwrites a held lock' do
      with_deploy_lock(options) { :done }
      expect(lock_requests(:put_parameter).map { |request| request[:params][:overwrite] }).to(eq([false]))
    end

    it 'releases the lock once the block is done' do
      with_deploy_lock(options) { :done }
      expect(store).to(be_empty)
    end

    it 'releases the lock when the block fails', :aggregate_failures do
      expect { with_deploy_lock(options) { raise('boom') } }
        .to(raise_error('boom'))
      expect(store).to(be_empty)
    end

    it 'refuses a run while another one holds the lock' do
      store['/deploy-rb/locks/dev/beta1'] = 'pid 1 on ci, started earlier'
      expect { with_deploy_lock(options) { :second } }
        .to(raise_error(PreflightError, %r{already running for dev/beta1 \(pid 1 on ci, started earlier\).*delete the SSM parameter /deploy-rb/locks/dev/beta1}))
    end

    it 'leaves the lock of the other run in place', :aggregate_failures do
      store['/deploy-rb/locks/dev/beta1'] = 'pid 1 on ci, started earlier'
      expect { with_deploy_lock(options) { :second } }
        .to(raise_error(PreflightError))
      expect(store['/deploy-rb/locks/dev/beta1']).to(eq('pid 1 on ci, started earlier'))
    end

    it 'names an unreadable holder as unknown' do
      store['/deploy-rb/locks/dev/beta1'] = 'held'
      ssm.stub_responses(:get_parameter, 'AccessDeniedException')
      expect { with_deploy_lock(options) { :second } }
        .to(raise_error(PreflightError, /\(unknown\)/))
    end

    it 'keeps its own lock when a retried put finds it already there' do
      allow(self).to(receive(:log_timestamp).and_return('now'))
      store['/deploy-rb/locks/dev/beta1'] = "pid #{Process.pid} on #{Socket.gethostname}, started now"
      expect(with_deploy_lock(options) { :mine }).to(eq(:mine))
    end

    it 'allows another environment at the same time' do
      with_deploy_lock(options) do
        expect(with_deploy_lock(options.merge(environment: 'rc1')) { :other }).to(eq(:other))
      end
    end

    it 'can be taken again once released' do
      with_deploy_lock(options) { :first }
      expect(with_deploy_lock(options) { :second }).to(eq(:second))
    end

    it 'leaves a lock that is no longer its own' do
      quietly { with_deploy_lock(options) { store['/deploy-rb/locks/dev/beta1'] = 'someone else' } }
      expect(store['/deploy-rb/locks/dev/beta1']).to(eq('someone else'))
    end

    it 'says how to clear the lock when it cannot release it' do
      ssm.stub_responses(:delete_parameter, 'AccessDeniedException')
      expect { capture_stdout { with_deploy_lock(options) { :done } } }
        .to(output(%r{Could not release the deploy lock.*delete the SSM parameter /deploy-rb/locks/dev/beta1}).to_stderr)
    end

    it 'keeps unexpected characters out of the parameter name' do
      expect(deploy_lock_name(options.merge(profile: 'a b', environment: 'beta:1'))).to(eq('/deploy-rb/locks/a_b/beta_1'))
    end

    it 'runs alongside a held lock with --skip-lock' do
      store['/deploy-rb/locks/dev/beta1'] = 'held'
      result = nil
      capture_stdout { result = with_deploy_lock(options.merge('skip-lock': true)) { :alongside } }
      expect(result).to(eq(:alongside))
    end

    it 'takes no lock on a dry run' do
      with_deploy_lock(dry_options) { :planned }
      expect(ssm.api_requests).to(be_empty)
    end
  end

  describe '#log_marker_for' do
    let(:config) do
      YAML.safe_load(<<~CONFIG)
        codedeploy:
          log_marker: Global.
        profiles:
          dev:
            codedeploy:
              worker:
                log_marker: Worker.
              grpc:
                log_marker: false
      CONFIG
    end

    it 'uses the default without a config' do
      expect(log_marker_for({}, 'dev', 'api')).to(eq(DEFAULT_LOG_MARKER))
    end

    it 'prefers the instance marker' do
      expect(log_marker_for(config, 'dev', 'worker')).to(eq('Worker.'))
    end

    it 'falls back to the global marker' do
      expect(log_marker_for(config, 'dev', 'api')).to(eq('Global.'))
    end

    it 'turns the marker off with false' do
      expect(log_marker_for(config, 'dev', 'grpc')).to(be_nil)
    end

    it 'rejects a malformed profiles section' do
      expect { log_marker_for(string_keys(profiles: 'bad'), 'dev', 'api') }
        .to(raise_error(PreflightError, /malformed/))
    end
  end

  describe '#deploy_config' do
    let(:path) { File.join(home, 'config.yaml') }

    it 'is empty without a file' do
      expect(deploy_config).to(eq({}))
    end

    it 'reads the file' do
      File.write(path, "codedeploy:\n  log_marker: Done.\n")
      expect(deploy_config).to(eq(YAML.safe_load("codedeploy:\n  log_marker: Done.\n")))
    end

    it 'treats an empty file as no settings' do
      File.write(path, '')
      expect(deploy_config).to(eq({}))
    end

    it 'rejects anything but a mapping' do
      File.write(path, "- a\n")
      expect { deploy_config }
        .to(raise_error(PreflightError, /must be a mapping/))
    end

    it 'rejects invalid YAML' do
      File.write(path, "a: [\n")
      expect { deploy_config }
        .to(raise_error(PreflightError, /is invalid/))
    end
  end

  describe '#check_for_other_deploys' do
    let(:codedeploy) { Aws::CodeDeploy::Client.new(stub_responses: true)                                  }
    let(:ec2)        { Aws::EC2::Client.new(stub_responses: true)                                         }
    let(:names)      { ['api']                                                                            }
    let(:targets)    { { ctx: { stack_name: 'beta1-StackInstances-x', stack_status: 'UPDATE_COMPLETE' } } }

    before do
      allow(Aws::CodeDeploy::Client).to(receive(:new).and_return(codedeploy))
      allow(Aws::EC2::Client).to(receive(:new).and_return(ec2))
    end

    def deployment_on(*instance_ids)
      codedeploy.stub_responses(:list_deployments, { deployments: ['d-1'] })
      codedeploy.stub_responses(:list_deployment_instances, { instances_list: instance_ids })
    end

    it 'passes when nothing else is happening' do
      expect { check_for_other_deploys(names, standalones, targets, options) }
        .not_to(raise_error)
    end

    it 'queries the deployment group without the environment number' do
      allow(codedeploy).to(receive(:list_deployments).and_call_original)
      check_for_other_deploys(names, standalones, targets, options)
      expect(codedeploy).to(have_received(:list_deployments).with(hash_including(application_name: 'api', deployment_group_name: 'beta')))
    end

    it 'stops when CodeDeploy is deploying to the instance being imaged' do
      deployment_on('i-api')
      expect { check_for_other_deploys(names, standalones, targets, options) }
        .to(raise_error(PreflightError, /api-beta1-standalone \(d-1\)/))
    end

    it 'stops without a terminal on a deployment elsewhere' do
      deployment_on('i-other')
      expect { quietly { check_for_other_deploys(names, standalones, targets, options) } }
        .to(raise_error(PreflightError, /--skip-other-deploy-check/))
    end

    it 'treats a deployment that has not started as running elsewhere' do
      codedeploy.stub_responses(:list_deployments, { deployments: ['d-1'] })
      codedeploy.stub_responses(:list_deployment_instances, 'DeploymentNotStartedException')
      expect { quietly { check_for_other_deploys(names, standalones, targets, options) } }
        .to(raise_error(PreflightError, /CodeDeploy d-1 is running/))
    end

    it 'ignores instances without a CodeDeploy application' do
      codedeploy.stub_responses(:list_deployments, 'ApplicationDoesNotExistException')
      expect { check_for_other_deploys(names, standalones, targets, options) }
        .not_to(raise_error)
    end

    it 'flags an AMI still being created' do
      ec2.stub_responses(:describe_images, { images: [{ image_id: 'ami-1', name: 'api' }] })
      expect { quietly { check_for_other_deploys(names, standalones, targets, options) } }
        .to(raise_error(PreflightError, /AMI ami-1 \(api\) is still being created/))
    end

    it 'flags a stack update in progress' do
      targets[:ctx][:stack_status] = 'UPDATE_IN_PROGRESS'
      expect { quietly { check_for_other_deploys(names, {}, targets, options) } }
        .to(raise_error(PreflightError, /is UPDATE_IN_PROGRESS/))
    end

    it 'works without a stack on an AMI-only run' do
      expect { check_for_other_deploys(names, standalones, nil, options) }
        .not_to(raise_error)
    end

    it 'continues when the user accepts' do
      deployment_on('i-other')
      answer("yes\n")
      expect { quietly { check_for_other_deploys(names, standalones, targets, options) } }
        .not_to(raise_error)
    end

    it 'aborts when the user declines' do
      deployment_on('i-other')
      answer("\n")
      expect { quietly { check_for_other_deploys(names, standalones, targets, options) } }
        .to(raise_error(PreflightError, /aborted/))
    end

    it 'only reports on a dry run', :aggregate_failures do
      deployment_on('i-api')
      expect { check_for_other_deploys(names, standalones, targets, dry_options) }
        .to(output(/a real run would stop here/).to_stderr)
    end

    it 'does nothing with --skip-other-deploy-check', :aggregate_failures do
      expect(capture_stdout { check_for_other_deploys(names, standalones, targets, options.merge('skip-other-deploy-check': true)) }).to(include('Not checking for other deploys'))
      expect(Aws::CodeDeploy::Client).not_to(have_received(:new))
    end
  end

  describe '#check_standalones' do
    let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }
    let(:ssm) { Aws::SSM::Client.new(stub_responses: true) }

    before do
      allow(Aws::EC2::Client).to(receive(:new).and_return(ec2))
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:send_command).and_call_original)
      stub_instance('running')
      stub_tagged
      ssm.stub_responses(:send_command, { command: { command_id: 'c-1' } })
      ssm.stub_responses(:get_command_invocation, { status: 'Success', response_code: 0 })
    end

    def stub_instance(state)
      ec2.stub_responses(:describe_instances, { reservations: [{ instances: [{ instance_id: 'i-api', state: { code: 16, name: state } }] }] })
    end

    def stub_tagged
      ec2.stub_responses(:describe_tags, { tags: [{ resource_id: 'i-api', key: USER_DATA_TAG }] })
    end

    it 'does nothing when an AMI was supplied' do
      check_standalones({}, options)
      expect(Aws::EC2::Client).not_to(have_received(:new))
    end

    it 'passes a ready instance whose log has the marker' do
      expect { check_standalones(standalones, options) }
        .not_to(raise_error)
    end

    it 'skips the checks on a stopped instance and still allows the AMI', :aggregate_failures do
      stub_instance('stopped')
      expect { check_standalones(standalones, options) }
        .to(output(/api-beta1-standalone is not running/).to_stderr)
      expect(ssm).not_to(have_received(:send_command))
    end

    it 'waits without a terminal until the user data tag appears', :aggregate_failures do
      ec2.stub_responses(:describe_tags, [{ tags: [] }, { tags: [] }, { tags: [{ resource_id: 'i-api', key: USER_DATA_TAG }] }])
      expect { check_standalones(standalones, options) }
        .to(output(/No UserDataCompleted tag/).to_stderr)
      expect(self).to(have_received(:sleep).with(READY_POLL_INTERVAL).once)
    end

    it 'continues without waiting when the user says no' do
      ec2.stub_responses(:describe_tags, { tags: [] })
      answer("n\n")
      expect(quietly { check_standalones(standalones, options) }).to(include('Continuing without waiting'))
    end

    it 'waits when the user presses enter' do
      ec2.stub_responses(:describe_tags, [{ tags: [] }, { tags: [{ resource_id: 'i-api', key: USER_DATA_TAG }] }])
      answer("\n")
      expect { quietly { check_standalones(standalones, options) } }
        .not_to(raise_error)
    end

    it 'does not wait on a dry run', :aggregate_failures do
      ec2.stub_responses(:describe_tags, { tags: [] })
      expect { check_standalones(standalones, dry_options) }
        .to(output(/a real run would ask whether to wait/).to_stderr)
      expect(self).not_to(have_received(:sleep))
    end

    { 2 => /does not exist/, 3 => /no 'Validate service end\.'/, 1 => /SSM command Failed \(1\): boom/ }.each do |code, message|
      it "stops the AMI when the log check exits #{code}" do
        ssm.stub_responses(:get_command_invocation, { status: 'Failed', response_code: code, standard_error_content: 'boom' })
        expect { check_standalones(standalones, options) }
          .to(raise_error(PreflightError, message))
      end
    end

    it 'polls until the command finishes' do
      ssm.stub_responses(:get_command_invocation, ['InvocationDoesNotExist', { status: 'InProgress' }, { status: 'Success' }])
      expect { check_standalones(standalones, options) }
        .not_to(raise_error)
    end

    it 'stops when SSM cannot reach the instance' do
      ssm.stub_responses(:send_command, 'InvalidInstanceId')
      expect { check_standalones(standalones, options) }
        .to(raise_error(PreflightError, /SSM cannot reach it/))
    end

    it 'only reports a failed log check on a dry run' do
      ssm.stub_responses(:get_command_invocation, { status: 'Failed', response_code: 3 })
      expect { check_standalones(standalones, dry_options) }
        .to(output(/CodeDeploy check failed/).to_stderr)
    end

    it 'sends the configured marker shell-escaped' do
      File.write(File.join(home, 'config.yaml'), "codedeploy:\n  log_marker: it's done\n")
      check_standalones(standalones, options)
      expect(ssm).to(have_received(:send_command).with(hash_including(parameters: { commands: include(a_string_including("it\\'s\\ done")) })))
    end

    it 'only requires the log to exist when the marker is off' do
      File.write(File.join(home, 'config.yaml'), "codedeploy:\n  log_marker: false\n")
      check_standalones(standalones, options)
      expect(ssm).to(have_received(:send_command).with(hash_including(parameters: { commands: satisfy { |commands| commands.none? { |command| command.include?('grep') } } })))
    end
  end

  describe '#print_dry_run_plan' do
    let(:parameters) do
      [
        Aws::CloudFormation::Types::Parameter.new(parameter_key: 'APIImageId', parameter_value: 'ami-old'),
        Aws::CloudFormation::Types::Parameter.new(parameter_key: 'APIDesiredCapacity', parameter_value: '2'),
        Aws::CloudFormation::Types::Parameter.new(parameter_key: 'DbPassword', parameter_value: '****')
      ]
    end
    let(:targets) do
      {
        ctx: { stack_name: 'beta1-StackInstances-x', parameters: parameters, ssm_prefix: '/beta/1' },
        instances: string_keys(api: { options: options, asg: { min_size: 1, max_size: 4, desired_capacity: 2 } })
      }
    end

    before { allow(self).to(receive(:capture_ssm_snapshot).and_return(string_keys('/beta/1/APIImageId': 'ami-old'))) }

    def plan(standalone_map = standalones, plan_targets = targets, plan_options = dry_options)
      capture_stdout { print_dry_run_plan(['api'], standalone_map, plan_targets, plan_options) }
    end

    it 'shows each SSM change as current -> new', :aggregate_failures do
      output = plan
      expect(output).to(include('/beta/1/APIImageId: ami-old -> <new api AMI>'))
      expect(output).to(include('/beta/1/APIDesiredCapacity: (not set) -> 2'))
    end

    it 'never prints a NoEcho parameter' do
      expect(plan).not_to(include('DbPassword'))
    end

    it 'names the supplied AMI', :aggregate_failures do
      output = plan({}, targets, dry_options.merge(ami: 'ami-new'))
      expect(output).to(include('use ami-new for api'))
      expect(output).to(include('ami-old -> ami-new'))
    end

    it 'stops at the AMI on an AMI-only run', :aggregate_failures do
      output = plan(standalones, nil)
      expect(output).to(include('build an AMI of api-beta1-standalone'))
      expect(output).not_to(include('update stack'))
    end
  end

  describe '#run_deployment' do
    before { allow(self).to(receive_messages(check_credentials: 'arn:aws:iam::1:user/me', check_permissions: nil, configure_aws_retries: nil)) }

    it 'checks credentials before permissions and passes the caller on' do
      run_with = options.merge(lambda_publish_version: 'fn', 'dry-run': true)
      capture_stdout { run_deployment(run_with) }
      expect(self).to(have_received(:check_permissions).with(run_with, 'arn:aws:iam::1:user/me'))
    end

    it 'publishes no lambda on a dry run', :aggregate_failures do
      allow(self).to(receive(:publish_lambda_and_update_cloudfront))
      output = capture_stdout { run_deployment(options.merge(lambda_publish_version: 'fn', 'dry-run': true)) }
      expect(output).to(include('would publish lambda beta1-fn'))
      expect(self).not_to(have_received(:publish_lambda_and_update_cloudfront))
    end

    context 'when the run is a dry run' do
      before do
        allow(Aws::EC2::Resource).to(receive(:new).and_return(instance_double(Aws::EC2::Resource)))
        allow(self).to(receive_messages(find_standalone_instance: %w[i-api api-beta1-standalone], discover_deploy_targets: {}, check_for_other_deploys: nil, check_standalones: nil, print_dry_run_plan: nil))
        allow(self).to(receive(:create_ami))
        allow(self).to(receive(:deploy_to_targets))
      end

      it 'prints the plan and changes nothing', :aggregate_failures do
        capture_stdout { run_deployment(dry_options) }
        expect(self).to(have_received(:print_dry_run_plan))
        expect(self).not_to(have_received(:create_ami))
        expect(self).not_to(have_received(:deploy_to_targets))
      end
    end
  end

  describe '#deploy_from_cli' do
    it 'prints a pre-flight failure on one line and exits 1', :aggregate_failures do
      allow(self).to(receive(:run_deployment).and_raise(PreflightError, 'no credentials'))
      expect { capture_stdout { deploy_from_cli(options) } }
        .to(raise_error(SystemExit) { |error| expect(error.status).to(eq(1)) }
.and(output(/no credentials\n\z/).to_stderr))
    end

    it 'runs the deployment' do
      allow(self).to(receive(:run_deployment))
      capture_stdout { deploy_from_cli(options) }
      expect(self).to(have_received(:run_deployment).with(options))
    end
  end

  describe '#parse_deploy_options' do
    it 'accepts the pre-flight flags', :aggregate_failures do
      parsed = parse_deploy_options(%w[--environment beta1 --instance api --profile dev --dry-run --skip-lock --skip-other-deploy-check --skip-permission-check])
      expect(parsed).to(include('dry-run': true, 'skip-lock': true, 'skip-other-deploy-check': true, 'skip-permission-check': true))
    end
  end

  describe 'the author credit' do
    it 'names both authors at the top of deploy.rb', :aggregate_failures do
      header = File.readlines(File.expand_path('../deploy.rb', __dir__)).first(6).join
      expect(header).to(include('Yves Desgagne'))
      expect(header).to(include('Tommy Lacroix (https://github.com/tlacroix)'))
      expect(header).to(include('MIT License'))
    end
  end
end
