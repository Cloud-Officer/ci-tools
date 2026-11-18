# frozen_string_literal: true

module DeployResilience; end

RSpec.describe(DeployResilience) do
  let(:ec2) { Aws::EC2::Resource.new(stub_responses: true, retry_limit: 0) }

  before do
    allow(self).to(receive(:sleep))
    allow($stdin).to(receive(:tty?).and_return(false))
  end

  def options
    { profile: 'dev', environment: 'beta1', instance: 'api,grpc' }
  end

  def string_keys(**pairs)
    pairs.transform_keys(&:to_s)
  end

  def standalones
    string_keys(api: %w[i-api api-beta1-standalone], grpc: %w[i-grpc grpc-beta1-standalone])
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
  ensure
    $stderr = original
  end

  def networking_error
    Seahorse::Client::NetworkingError.new(StandardError.new('connection reset'))
  end

  def failing_then(failures)
    attempts = 0
    lambda do
      attempts += 1
      raise(networking_error) if attempts <= failures

      :done
    end
  end

  def request_context(status)
    Seahorse::Client::RequestContext.new.tap { |context| context.http_response.status_code = status }
  end

  def answer(text)
    allow($stdin).to(receive_messages(tty?: true, gets: text))
  end

  describe '#transient_error?' do
    it 'accepts network errors' do
      expect(transient_error?(networking_error)).to(be(true))
    end

    it 'accepts throttling' do
      expect(transient_error?(Aws::EC2::Errors::RequestLimitExceeded.new(request_context(400), 'slow down'))).to(be(true))
    end

    it 'accepts AWS server errors' do
      expect(transient_error?(Aws::EC2::Errors::InternalError.new(request_context(503), 'unavailable'))).to(be(true))
    end

    it 'rejects AWS client errors' do
      expect(transient_error?(Aws::EC2::Errors::UnauthorizedOperation.new(request_context(403), 'denied'))).to(be(false))
    end

    it 'rejects other errors' do
      expect(transient_error?(StandardError.new('boom'))).to(be(false))
    end
  end

  describe '#with_network_retries' do
    it 'retries until the call succeeds', :aggregate_failures do
      result = nil
      expect { result = with_network_retries('testing', &failing_then(2)) }
        .to(output(/Network problem testing/).to_stderr)
      expect(result).to(eq(:done))
    end

    it 'backs off up to the maximum delay' do
      quietly { with_network_retries('testing', &failing_then(6)) }
      expect(self).to(have_received(:sleep).with(NETWORK_RETRY_MAX_DELAY).twice)
    end

    it 'gives up at the deadline' do
      expect { with_network_retries('testing', deadline: Time.now - 1) { raise(networking_error) } }
        .to(raise_error(Seahorse::Client::NetworkingError))
    end

    it 'does not retry other errors', :aggregate_failures do
      call = instance_double(Proc)
      allow(call).to(receive(:call).and_raise('boom'))
      expect { with_network_retries('testing') { call.call } }
        .to(raise_error(RuntimeError, 'boom'))
      expect(call).to(have_received(:call).once)
    end
  end

  describe '#create_image' do
    it 'retries a lost response with the same image name' do
      ec2.client.stub_responses(:create_image, ['RequestLimitExceeded', { image_id: 'ami-1' }])
      allow(ec2.client).to(receive(:create_image).and_call_original)
      quietly { create_image(ec2.client, 'i-api', 'api-beta1-1') }
      expect(ec2.client).to(have_received(:create_image).with({ instance_id: 'i-api', name: 'api-beta1-1' }).twice)
    end

    it 'finds the image when the first call went through' do
      ec2.client.stub_responses(:create_image, 'InvalidAMIName.Duplicate')
      ec2.client.stub_responses(:describe_images, { images: [{ image_id: 'ami-existing' }] })
      expect(create_image(ec2.client, 'i-api', 'api-beta1-1')).to(eq('ami-existing'))
    end

    it 'raises the duplicate error when no image has that name' do
      ec2.client.stub_responses(:create_image, 'InvalidAMIName.Duplicate')
      ec2.client.stub_responses(:describe_images, { images: [] })
      expect { create_image(ec2.client, 'i-api', 'api-beta1-1') }
        .to(raise_error(Aws::EC2::Errors::InvalidAMINameDuplicate))
    end
  end

  describe '#snapshot_progress' do
    let(:volumes) do
      [
        { device_name: '/dev/xvda', ebs: { snapshot_id: 'snap-big', volume_size: 200 } },
        { device_name: '/dev/xvdb', ebs: { snapshot_id: 'snap-small', volume_size: 16 } },
        { device_name: '/dev/xvdc', virtual_name: 'ephemeral0' }
      ]
    end
    let(:image) do
      ec2.client.stub_data(:describe_images, { images: [{ image_id: 'ami-1', block_device_mappings: volumes }] }).images.first
    end

    it 'weighs each snapshot by its volume size' do
      ec2.client.stub_responses(:describe_snapshots, { snapshots: [{ snapshot_id: 'snap-big', progress: '10%', volume_size: 200 }, { snapshot_id: 'snap-small', progress: '100%', volume_size: 16 }] })
      expect(snapshot_progress(ec2.client, image)).to(eq('16%'))
    end

    it 'counts a snapshot that is not listed yet as zero' do
      ec2.client.stub_responses(:describe_snapshots, { snapshots: [{ snapshot_id: 'snap-small', progress: '100%', volume_size: 16 }] })
      expect(snapshot_progress(ec2.client, image)).to(eq('7%'))
    end

    it 'has no progress before the image lists a snapshot' do
      bare = ec2.client.stub_data(:describe_images, { images: [{ image_id: 'ami-1', block_device_mappings: [] }] }).images.first
      expect(snapshot_progress(ec2.client, bare)).to(be_nil)
    end

    it 'ignores a permanent error reading the snapshots' do
      ec2.client.stub_responses(:describe_snapshots, 'InvalidSnapshot.NotFound')
      expect(snapshot_progress(ec2.client, image)).to(be_nil)
    end

    it 'lets a transient error be retried' do
      allow(self).to(receive(:transient_error?).and_return(true))
      ec2.client.stub_responses(:describe_snapshots, 'RequestLimitExceeded')
      expect { snapshot_progress(ec2.client, image) }
        .to(raise_error(Aws::EC2::Errors::RequestLimitExceeded))
    end

    it 'weighs volumes equally when none reports a size' do
      expect(weighted_progress([[20, 0], [40, 0]])).to(eq(30))
    end
  end

  describe '#create_ami with a job' do
    let(:job) { AmiJob.new('api', 'api-beta1-standalone') }

    before { ec2.client.stub_responses(:create_image, { image_id: 'ami-1' }) }

    it 'keeps polling until the image is visible and available', :aggregate_failures do
      ec2.client.stub_responses(:describe_images, ['InvalidAMIID.NotFound', { images: [] }, { images: [{ image_id: 'ami-1', state: 'pending' }] }, { images: [{ image_id: 'ami-1', state: 'available' }] }])
      expect(create_ami(ec2, 'i-api', 'api-beta1-standalone', { instance: 'api', ami_job: job })).to(eq('ami-1'))
      expect(self).to(have_received(:sleep).with(AMI_POLL_INTERVAL).exactly(3).times)
    end

    it 'records the image on the job and logs nothing', :aggregate_failures do
      ec2.client.stub_responses(:describe_images, { images: [{ image_id: 'ami-1', state: 'available' }] })
      output = capture_stdout { create_ami(ec2, 'i-api', 'api-beta1-standalone', { instance: 'api', ami_job: job }) }
      expect(job.snapshot).to(include(ami_id: 'ami-1', state: 'available'))
      expect(output).to(eq(''))
    end
  end

  describe AmiJob do
    let(:job) { described_class.new('api', 'api-beta1-standalone') }

    it 'is available once finished', :aggregate_failures do
      job.finish('ami-1')
      expect(job).to(be_available)
      expect(job).not_to(be_pending)
    end

    it 'is pending while its image exists and is unfinished' do
      job.update(state: 'pending', ami_id: 'ami-1')
      expect(job).to(be_pending)
    end

    it 'is not pending before it has an image' do
      expect(job).not_to(be_pending)
    end

    it 'is not pending after a failure' do
      job.update(ami_id: 'ami-1')
      job.mark_failed('boom')
      expect(job).not_to(be_pending)
    end

    it 'formats the elapsed time' do
      expect(job.elapsed).to(match(/\A\d\d:\d\d\z/))
    end
  end

  describe AmiStatusTable do
    let(:job) { AmiJob.new('api', 'api-beta1-standalone') }
    let(:out)   { StringIO.new                    }
    let(:table) { described_class.new([job], out) }

    it 'prints one line per change without a terminal', :aggregate_failures do
      2.times { table.render }
      job.update(state: 'pending', ami_id: 'ami-1', progress: '42%')
      table.render
      expect(out.string.lines.size).to(eq(2))
      expect(out.string).to(match(/api\s+pending\s+42%\s+ami-1/))
    end

    it 'shows the error of a failed build' do
      job.mark_failed('snapshot failed')
      table.render
      expect(out.string).to(include('snapshot failed'))
    end

    it 'redraws in place on a terminal', :aggregate_failures do
      allow(out).to(receive(:tty?).and_return(true))
      2.times { table.render }
      expect(out.string.scan("\e[2A").size).to(eq(1))
      expect(out.string).to(include('INSTANCE'))
    end
  end

  describe '#requested_amis' do
    it 'maps values to instances, with none and empty values building', :aggregate_failures do
      amis = requested_amis({ ami: 'ami-1, none,,ami-4' }, %w[api grpc worker bre])
      expect(amis.values).to(eq(['ami-1', nil, nil, 'ami-4']))
      expect(amis.keys).to(eq(%w[api grpc worker bre]))
    end

    it 'accepts NONE in any case' do
      expect(requested_amis({ ami: 'NONE' }, %w[api]).values).to(eq([nil]))
    end

    it 'builds everything without --ami' do
      expect(requested_amis({}, %w[api grpc]).values).to(eq([nil, nil]))
    end
  end

  describe '#resolve_ami_ids' do
    before { allow(self).to(receive(:create_ami)) { |_ec2, instance_id, _name, _options| instance_id == 'i-grpc' ? raise('snapshot failed') : "ami-#{instance_id}" } }

    it 'builds only the instances without a supplied AMI', :aggregate_failures do
      allow(self).to(receive(:create_ami).and_return('ami-built'))
      ami_ids = nil
      capture_stdout { ami_ids = resolve_ami_ids(ec2, %w[api grpc], standalones, options.merge(ami: 'ami-given,none')) }
      expect(ami_ids).to(eq(string_keys(api: 'ami-given', grpc: 'ami-built')))
      expect(self).to(have_received(:create_ami).once)
    end

    it 'stops without a terminal when an AMI fails' do
      expect { quietly { resolve_ami_ids(ec2, %w[api grpc], standalones, options) } }
        .to(raise_error(RuntimeError, 'AMI creation failed for: grpc'))
    end

    it 'deploys the others when the user accepts' do
      answer("y\n")
      ami_ids = nil
      quietly { ami_ids = resolve_ami_ids(ec2, %w[api grpc], standalones, options) }
      expect(ami_ids).to(eq(string_keys(api: 'ami-i-api')))
    end

    it 'keeps a supplied AMI when the only build fails' do
      answer("y\n")
      ami_ids = nil
      quietly { ami_ids = resolve_ami_ids(ec2, %w[api grpc], standalones, options.merge(ami: 'ami-given,none')) }
      expect(ami_ids).to(eq(string_keys(api: 'ami-given')))
    end

    it 'stops when the user declines' do
      answer("n\n")
      expect { quietly { resolve_ami_ids(ec2, %w[api grpc], standalones, options) } }
        .to(raise_error(RuntimeError, 'AMI creation failed for: grpc'))
    end

    it 'does not ask when every AMI failed', :aggregate_failures do
      answer("y\n")
      allow(self).to(receive(:create_ami).and_raise('snapshot failed'))
      expect { quietly { resolve_ami_ids(ec2, %w[api grpc], standalones, options) } }
        .to(raise_error(RuntimeError, 'AMI creation failed for: api, grpc'))
      expect($stdin).not_to(have_received(:gets))
    end

    it 'does not ask on an AMI-only run' do
      answer("y\n")
      expect { quietly { resolve_ami_ids(ec2, %w[api grpc], standalones, options.merge(create_ami_only: true)) } }
        .to(raise_error(RuntimeError, 'AMI creation failed for: grpc'))
    end

    it 'marks the failed job', :aggregate_failures do
      jobs = ami_jobs(%w[api grpc], standalones, options)
      expect { quietly { resolve_ami_ids(ec2, %w[api grpc], standalones, options, jobs) } }
        .to(raise_error(RuntimeError))
      expect(jobs['grpc'].snapshot).to(include(state: 'failed', error: 'snapshot failed'))
    end
  end

  describe '#with_resume_command' do
    let(:jobs) { ami_jobs(%w[api grpc], standalones, options) }

    def stderr_of(error = RuntimeError.new('boom'), run_options = options)
      original = $stderr
      $stderr = StringIO.new
      begin
        with_resume_command(%w[api grpc], jobs, run_options) { raise(error) }
      rescue RuntimeError, Interrupt
        $stderr.string
      end
    ensure
      $stderr = original
    end

    it 'prints the command for the AMIs already built', :aggregate_failures do
      jobs['api'].finish('ami-1')
      output = stderr_of
      expect(output).to(include('--instance api --ami ami-1'))
      expect(output).to(include('--environment beta1 --profile dev'))
    end

    it 'prints it on Ctrl-C and names images still being created', :aggregate_failures do
      jobs['api'].finish('ami-1')
      jobs['grpc'].update(state: 'pending', ami_id: 'ami-2')
      output = stderr_of(Interrupt.new)
      expect(output).to(include('--ami ami-1'))
      expect(output).to(include('Still being created: grpc (ami-2)'))
    end

    it 'prints nothing before an AMI is built' do
      expect(stderr_of).to(eq(''))
    end

    it 'includes supplied AMIs and the options that change the deploy', :aggregate_failures do
      supplied = ami_jobs(%w[api grpc], standalones, options.merge(ami: 'ami-given,none'))
      supplied['grpc'].finish('ami-2')
      command = resume_command(%w[api grpc], string_keys(api: 'ami-given', grpc: 'ami-2'), options.merge(spot_target_capacity: 2, sequential_rollout: true, 'skip-lock': true, type: 't3.large'))
      expect(command).to(include('--instance api,grpc --ami ami-given,ami-2'))
      expect(command).to(include('--type t3.large --spot_target_capacity 2 --sequential_rollout --skip-lock'))
    end

    it 'returns the block value when nothing fails' do
      expect(with_resume_command(%w[api grpc], jobs, options) { :done }).to(eq(:done))
    end
  end

  describe '#update_cloudformation_stack' do
    let(:cfn)    { Aws::CloudFormation::Client.new(stub_responses: true, retry_limit: 0)                                                                               }
    let(:deploy) { DeployContext.new(options: {}, asg: {}, ami_id: 'ami-1', stack: { stack_name: 'test-stack', parameters: [], prefix: 'API', ssm_prefix: '/beta/1' }) }

    before { cfn.stub_responses(:describe_stacks, { stacks: [{ stack_name: 'test-stack', stack_status: 'UPDATE_COMPLETE', creation_time: Time.now }] }) }

    def record_tokens(tokens)
      allow(cfn).to(receive(:update_stack)) do |update|
        tokens << update[:client_request_token]
        raise(networking_error) if tokens.one?
      end
    end

    it 'retries the update with the same token', :aggregate_failures do
      tokens = []
      record_tokens(tokens)
      quietly { update_cloudformation_stack(cfn, [deploy]) }
      expect(tokens.size).to(eq(2))
      expect(tokens.uniq.size).to(eq(1))
    end
  end

  describe '#update_stack_with_ssm_rollback' do
    let(:cfn) { Aws::CloudFormation::Client.new(stub_responses: true, retry_limit: 0) }
    let(:ssm)    { Aws::SSM::Client.new(stub_responses: true, retry_limit: 0)                                                                                          }
    let(:deploy) { DeployContext.new(options: {}, asg: {}, ami_id: 'ami-1', stack: { stack_name: 'test-stack', parameters: [], prefix: 'API', ssm_prefix: '/beta/1' }) }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(ssm).to(receive(:put_parameter).and_call_original)
      allow(cfn).to(receive(:update_stack).and_raise(networking_error))
      allow(self).to(receive(:with_network_retries)) { |_description, **_kwargs, &block| block.call }
    end

    it 'keeps the new values and prints the restore commands when the outcome is unknown', :aggregate_failures do
      expect { update_stack_with_ssm_rollback(cfn, [deploy], string_keys('/beta/1/APIImageId': 'ami-old')) }
        .to(raise_error(Seahorse::Client::NetworkingError).and(output(/may still be running.*put-parameter.*ami-old/m).to_stderr))
      expect(ssm).not_to(have_received(:put_parameter))
    end

    it 'says nothing about restoring when SSM did not change' do
      expect { update_stack_with_ssm_rollback(cfn, [deploy], {}) }
        .to(raise_error(Seahorse::Client::NetworkingError).and(output(/\A(?!.*restore them).*may still be running/m).to_stderr))
    end
  end

  describe '#restore_ssm_parameters' do
    let(:ssm) { Aws::SSM::Client.new(stub_responses: true, retry_limit: 0) }

    before do
      allow(Aws::SSM::Client).to(receive(:new).and_return(ssm))
      allow(Aws.config).to(receive(:[]).and_call_original)
      allow(Aws.config).to(receive(:[]).with(:profile).and_return('dev'))
    end

    it 'prints the commands instead of raising when the restore fails', :aggregate_failures do
      ssm.stub_responses(:put_parameter, 'AccessDeniedException')
      expect { capture_stdout { restore_ssm_parameters(string_keys('/beta/1/APIImageId': 'ami old')) } }
        .to(output(%r{Could not restore.*aws ssm put-parameter --profile dev --overwrite --type String --name /beta/1/APIImageId --value ami\\ old}m).to_stderr)
    end
  end

  describe '#deploy_to_targets' do
    it 'deploys only the instances that have an AMI' do
      allow(self).to(receive(:build_deploys).and_return({}))
      allow(self).to(receive_messages(update_stack_with_ssm_rollback: :no_updates, mark_cfn_secrets_for_previous_value!: nil, update_ssm_parameters_with_rollback: nil, fetch_asg_mixed_parameters: {}))
      targets = { ctx: { parameters: [], secret_parameter_keys: [] }, cfn: nil, asg_resources: instance_double(Aws::AutoScaling::Resource, client: nil), instances: string_keys(api: {}, grpc: {}) }
      deploy_to_targets(targets, string_keys(api: 'ami-1'), options)
      expect(self).to(have_received(:build_deploys).with(hash_including(instances: string_keys(api: {})), anything, anything))
    end
  end

  describe '#configure_aws_retries' do
    it 'uses standard retries' do
      allow(Aws.config).to(receive(:update))
      configure_aws_retries
      expect(Aws.config).to(have_received(:update).with({ retry_mode: 'standard', max_attempts: AWS_MAX_ATTEMPTS }))
    end
  end
end
