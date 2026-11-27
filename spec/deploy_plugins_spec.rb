# frozen_string_literal: true

require 'tmpdir'
require_relative '../plugins/sns'

module DeployPlugins; end

RSpec.describe(DeployPlugins) do
  let(:home) { Dir.mktmpdir }

  before { allow(self).to(receive(:deploy_directory).and_return(home)) }

  after do
    stop_plugins
    stop_run_log
    FileUtils.remove_entry(home)
  end

  def options
    { profile: 'dev', environment: 'beta1', instance: 'api' }
  end

  def payload(**extra)
    { profile: 'dev', environment: 'beta1', instances: ['api'] }.merge(extra)
  end

  def yaml_settings(settings)
    JSON.parse(JSON.generate(settings))
  end

  def quietly(&)
    original = $stderr
    $stderr = StringIO.new
    capture_stdout(&)
    $stderr.string
  ensure
    $stderr = original
  end

  def write_plugins(settings, mode: 0o600)
    path = File.join(home, PLUGINS_FILE)
    File.write(path, YAML.dump(yaml_settings(settings)))
    File.chmod(mode, path)
    path
  end

  def load_plugins(settings, extra)
    PluginManager.load(write_plugins(settings), options.merge(extra), {}, method(:start_thread))
  end

  def manager(settings, extra = {})
    result = nil
    quietly { result = load_plugins(settings, extra) }
    result
  end

  def load_warnings(settings, extra = {})
    quietly { load_plugins(settings, extra) }
  end

  def plugin(klass, settings = {}, extra = {})
    require_relative("../plugins/#{klass}")
    Plugins.const_get(Plugins.class_name(klass)).new(yaml_settings(settings), options.merge(extra))
  end

  def sms_settings
    { enabled: true, account_sid: "AC#{'a' * 32}", auth_token: 'secret-token', from: '+15555550100', to: '+15555550101' }
  end

  describe 'PluginManager.load' do
    it 'starts without a settings file' do
      expect(PluginManager.load(File.join(home, 'none.yaml'), options, {}, method(:start_thread)).names).to(be_empty)
    end

    it 'loads an enabled plugin' do
      expect(manager({ webhook: { enabled: true, url: 'https://example.com/x' } }).names).to(eq(['webhook']))
    end

    it 'leaves a plugin off by default' do
      expect(manager({ webhook: { url: 'https://example.com/x' } }).names).to(be_empty)
    end

    it 'honours --disable-plugins for one plugin' do
      expect(manager({ webhook: { enabled: true, url: 'https://example.com/x' } }, { 'disable-plugins': ['webhook'] }).names).to(be_empty)
    end

    it 'honours --disable-plugins for all' do
      expect(manager({ webhook: { enabled: true, url: 'https://example.com/x' } }, { 'disable-plugins': ['all'] }).names).to(be_empty)
    end

    it 'turns off an unknown plugin with a warning' do
      expect(load_warnings({ nope: { enabled: true } })).to(include("unknown plugin 'nope'"))
    end

    it 'turns off a misconfigured plugin with a warning' do
      expect(load_warnings({ webhook: { enabled: true, url: 'ftp://x', extra: 1 } })).to(include('url must be an http(s) URL', "unknown key 'extra'"))
    end

    it 'refuses unknown events' do
      expect(load_warnings({ webhook: { enabled: true, url: 'https://x', events: ['nope'] } })).to(include('events must be a list'))
    end

    it 'survives a plugin that fails to load' do
      allow(PluginManager).to(receive(:require).and_raise(LoadError, 'broken'))
      expect(manager({ webhook: { enabled: true, url: 'https://x' } }).names).to(be_empty)
    end

    it 'warns when --sms has no active plugin' do
      expect(load_warnings({}, { sms: true })).to(include('no texts will be sent'))
    end
  end

  describe 'PluginManager.read_settings' do
    it 'warns about a file others can read' do
      path = write_plugins({}, mode: 0o644)
      expect(quietly { PluginManager.read_settings(path) }).to(include('chmod 600'))
    end

    it 'ignores the settings of a file others can read' do
      path = write_plugins({ webhook: { enabled: true } }, mode: 0o644)
      result = nil
      quietly { result = PluginManager.read_settings(path) }
      expect(result).to(eq({}))
    end

    it 'ignores a file owned by someone else' do
      path = write_plugins({ webhook: { enabled: true } })
      allow(File).to(receive(:stat).with(path).and_return(instance_double(File::Stat, owned?: false, mode: 0o100600)))
      expect(quietly { PluginManager.read_settings(path) }).to(include('every plugin is off'))
    end

    it 'turns every plugin off on invalid YAML' do
      path = File.join(home, PLUGINS_FILE)
      File.write(path, "a: [\n", perm: 0o600)
      expect(quietly { PluginManager.read_settings(path) }).to(include('every plugin is off'))
    end

    it 'turns every plugin off when the file is not a mapping' do
      path = File.join(home, PLUGINS_FILE)
      File.write(path, "- a\n", perm: 0o600)
      expect(quietly { PluginManager.read_settings(path) }).to(include('must map plugin names'))
    end
  end

  describe 'PluginManager events' do
    let(:handler) { instance_double(Plugin) }

    def running(events = ['deploy_started'])
      PluginManager.new([['fake', handler, events]], { profile: 'dev' }, method(:start_thread))
    end

    def emit_and_stop
      plugins = running
      plugins.emit(:deploy_started, { extra: 1 })
      plugins.emit(:deploy_failed)
      plugins.shutdown
    end

    it 'delivers the events the plugin handles, with the context' do
      allow(handler).to(receive(:handle))
      emit_and_stop
      expect(handler).to(have_received(:handle).once.with('deploy_started', hash_including(profile: 'dev', extra: 1)))
    end

    [RuntimeError, ScriptError, SystemExit].each do |failure|
      it "only warns when a plugin raises #{failure}" do
        allow(handler).to(receive(:handle).and_raise(failure))
        expect(quietly { emit_and_stop }).to(include('plugin fake failed on deploy_started'))
      end
    end

    def stuck_shutdown_warnings
      plugins = running
      plugins.emit(:deploy_started)
      quietly { plugins.shutdown(0) }
    end

    it 'does not wait for a stuck plugin past the grace period' do
      gate = Queue.new
      allow(handler).to(receive(:handle)) { gate.pop }
      warnings = stuck_shutdown_warnings
      gate.close
      expect(warnings).to(include('still busy'))
    end
  end

  describe Plugin do
    let(:base) { described_class.new({}, {}) }

    it 'requires subclasses to handle events' do
      expect { base.handle('deploy_started', {}) }
        .to(raise_error(NotImplementedError))
    end

    it 'is active by default' do
      expect(base.active?).to(be(true))
    end

    {
      deploy_started: 'Deploying api to dev/beta1',
      stack_updated: 'CloudFormation finished',
      deploy_succeeded: 'Deployed api',
      deploy_interrupted: 'interrupted',
      reset_disabling: 'Disabling',
      reset_disabled: 'disabled',
      reset_enabling: 'Recreating',
      reset_done: 'recreated',
      rollout_done: 'replaced'
    }.each do |event, text|
      it "summarises the plain event #{event}" do
        expect(base.summary(event.to_s, payload)).to(include(text))
      end
    end

    it 'summarises AMIs' do
      expect(base.summary('amis_done', payload(jobs: [{ instance: 'api', ami_id: nil, state: 'failed' }]))).to(include('api - (failed)'))
    end

    it 'summarises AMIs ready' do
      expect(base.summary('amis_ready', payload(jobs: [{ instance: 'api', ami_id: 'ami-1', state: 'available' }]))).to(include('ami-1'))
    end

    it 'summarises a rollout' do
      expect(base.summary('rollout_started', payload(groups: [{ name: 'g', from: 2, to: 5 }]))).to(include('g from 2 to 5'))
    end

    it 'summarises passing checks' do
      expect(base.summary('healthchecks_done', payload(failed: []))).to(include('All health checks'))
    end

    it 'summarises failing checks' do
      expect(base.summary('healthchecks_done', payload(failed: [{ url: 'u', reason: 'r' }]))).to(include('u (r)'))
    end

    { healthcheck_failing: 'retrying', healthcheck_recovered: 'OK again', healthcheck_gave_up: 'giving up' }.each do |event, text|
      it "summarises the health event #{event}" do
        expect(base.summary(event.to_s, payload(url: 'u', reason: 'r', after: 3))).to(include(text))
      end
    end

    { deploy_failed: 'failed: boom', deploy_aborted: 'stopped: boom', lambda_published: 'Lambda fn' }.each do |event, text|
      it "summarises the outcome #{event}" do
        expect(base.summary(event.to_s, payload(error: 'boom', reason: 'boom', function: 'fn'))).to(include(text))
      end
    end

    {
      { kind: 'standalones_not_ready', names: ['n'] } => 'n not ready',
      { kind: 'partial_ami_failure', failed: ['f'] } => 'AMI failed for f',
      { kind: 'other_deploy' } => 'someone else',
      { kind: 'permissions_unchecked' } => 'permissions',
      { kind: 'extra_codedeploy_targets', group: 'g' } => 'g would also',
      { kind: 'other' } => 'other'
    }.each do |question, text|
      it "summarises the #{question[:kind]} question" do
        expect(base.summary('question', payload(**question))).to(include(text))
      end
    end

    it 'names an unlisted event' do
      expect(base.summary('custom', payload)).to(eq('custom for dev/beta1'))
    end

    it 'reports a command that cannot start' do
      allow(Process).to(receive(:spawn).and_raise(Errno::ENOENT))
      expect(quietly { base.__send__(:spawn_command, 'nope') }).to(include('could not run nope'))
    end
  end

  describe 'HTTP delivery' do
    let(:sender) { plugin('webhook', { url: 'https://example.com/x' }) }
    let(:http) { instance_double(Net::HTTP) }

    before do
      allow(sender).to(receive(:sleep))
      allow(Net::HTTP).to(receive(:start).and_yield(http))
    end

    def answer(code)
      klass = Net::HTTPResponse::CODE_TO_OBJ[code]
      klass.new('1.1', code, '')
    end

    it 'posts the event as JSON' do
      allow(http).to(receive(:request).and_return(answer('200')))
      sender.handle('deploy_started', payload)
      expect(http).to(have_received(:request).with(have_attributes(body: include('"event":"deploy_started"'))))
    end

    it 'retries a server error' do
      allow(http).to(receive(:request).and_return(answer('500'), answer('200')))
      sender.handle('deploy_started', payload)
      expect(http).to(have_received(:request).twice)
    end

    it 'does not retry a refusal, and hides the response body' do
      allow(http).to(receive(:request).and_return(answer('403')))
      expect { sender.handle('deploy_started', payload) }
        .to(raise_error('example.com answered HTTP 403'))
    end

    it 'gives up after repeated network errors' do
      allow(http).to(receive(:request).and_raise(SocketError))
      expect { sender.handle('deploy_started', payload) }
        .to(raise_error('example.com: SocketError'))
    end

    it 'sends a slack message and custom headers' do
      slack = plugin('webhook', { url: 'https://example.com/x', format: 'slack', headers: { 'X-A': 'b' } })
      allow(http).to(receive(:request).and_return(answer('200')))
      slack.handle('deploy_started', payload)
      expect(http).to(have_received(:request).with(have_attributes(body: include('"text"'))))
    end
  end

  describe 'Plugins::Webhook.settings_errors' do
    before { plugin('webhook') }

    it 'refuses an unknown format' do
      expect(Plugins::Webhook.settings_errors(yaml_settings({ url: 'https://x', format: 'xml' })).join).to(include('format'))
    end

    it 'refuses nested headers' do
      expect(Plugins::Webhook.settings_errors(yaml_settings({ url: 'https://x', headers: { a: [] } })).join).to(include('headers'))
    end
  end

  describe Plugins do
    it 'offers the five plugins' do
      expect(described_class.available).to(eq(%w[macos_notification sms sns voice webhook]))
    end
  end

  describe 'the sms plugin' do
    let(:sms) { plugin('sms', sms_settings) }

    before { sms }

    it 'stays off without --sms' do
      expect(sms.active?).to(be(false))
    end

    it 'turns on with --sms' do
      expect(plugin('sms', sms_settings, { sms: true }).active?).to(be(true))
    end

    it 'validates its settings' do
      expect(Plugins::Sms.settings_errors(yaml_settings({ always: 'x' })).size).to(eq(5))
    end

    it 'posts to Twilio with the account credentials' do
      allow(sms).to(receive(:http_post))
      sms.handle('deploy_succeeded', payload)
      expect(sms).to(have_received(:http_post).with(include("AC#{'a' * 32}"), hash_including(yaml_settings({ Body: 'DEPLOY OK beta1 api' })), basic_auth: ["AC#{'a' * 32}", 'secret-token']))
    end

    {
      lambda_published: 'LAMBDA PUBLISHED', deploy_aborted: 'STOPPED', deploy_failed: 'FAILED', question: 'ANSWER NEEDED', healthcheck_gave_up: 'HEALTH CHECK FAILED', stack_updated: 'CloudFormation'
    }.each do |event, text|
      it "words #{event}" do
        expect(sms.message(event.to_s, payload)).to(include(text))
      end
    end
  end

  describe 'the sns plugin' do
    let(:topic)    { 'arn:aws:sns:ca-central-1:123456789012:in-prod4-notifications'                                          }
    let(:client)   { Aws::SNS::Client.new(stub_responses: true)                                                              }
    let(:plugin)   { Plugins::Sns.new(yaml_settings({ topic_arn: topic }), {})                                               }
    let(:payload)  { { profile: 'in', environment: 'prod4', instances: %w[api], error: 'unhealthy', outcome: 'rolled_back' } }

    before { allow(Aws::SNS::Client).to(receive(:new).and_return(client)) }

    def published
      client.api_requests.find { |request| request[:operation_name] == :publish }[:params]
    end

    it 'accepts an SNS topic ARN' do
      expect(Plugins::Sns.settings_errors(yaml_settings({ topic_arn: topic }))).to(be_empty)
    end

    ['', 'arn:aws:sqs:us-east-1:123456789012:queue', 'arn:aws:sns:us-east-1:123:topic'].each do |arn|
      it "refuses #{arn.inspect}" do
        expect(Plugins::Sns.settings_errors(yaml_settings({ topic_arn: arn }))).to(eq(['topic_arn must be an SNS topic ARN']))
      end
    end

    it 'publishes to the topic in its own region', :aggregate_failures do
      plugin.handle('deploy_failed', payload)
      expect(published[:topic_arn]).to(eq(topic))
      expect(Aws::SNS::Client).to(have_received(:new).with(region: 'ca-central-1'))
    end

    it 'says what happened in the subject' do
      plugin.handle('deploy_failed', payload)
      expect(published[:subject]).to(eq('deploy.rb deploy_failed in/prod4'))
    end

    it 'sends the summary and the event details', :aggregate_failures do
      plugin.handle('deploy_failed', payload)
      message = JSON.parse(published[:message])
      expect(message['summary']).to(eq('Deploying api to in/prod4 failed and was rolled back: unhealthy'))
      expect(message).to(include(yaml_settings({ event: 'deploy_failed', outcome: 'rolled_back' })))
    end

    it 'keeps the subject within the SNS limit and printable' do
      expect(plugin.subject('rollback_failed', { profile: 'é' * 200, environment: 'x' })).to(match(/\A[ -~]{100}\z/))
    end

    it 'defaults to the failures only' do
      expect(Plugins::Sns::DEFAULT_EVENTS).to(eq(%w[deploy_failed deploy_aborted deploy_interrupted healthcheck_gave_up rollback_failed]))
    end

    it 'summarises a failed rollback' do
      expect(plugin.summary('rollback_failed', { profile: 'in', environment: 'prod4', rollback_error: 'stack failed' })).to(eq('Rollback of in/prod4 failed, needs a human: stack failed'))
    end
  end

  describe 'the voice plugin' do
    let(:voice) { plugin('voice', { voice: 'Samantha' }) }

    it 'validates the voice' do
      expect(voice.class.settings_errors(yaml_settings({ voice: 1 }))).not_to(be_empty)
    end

    it 'follows the platform' do
      allow(voice).to(receive(:macos?).and_return(false))
      expect(voice.active?).to(be(false))
    end

    it 'speaks with the chosen voice' do
      allow(voice).to(receive(:spawn_command))
      voice.handle('stack_updated', payload)
      expect(voice).to(have_received(:spawn_command).with('say', '-v', 'Samantha', include('CloudFormation')))
    end

    {
      healthcheck_failing: 'failing for api', healthcheck_recovered: 'api is healthy', healthcheck_gave_up: 'Giving up on the api'
    }.each do |event, text|
      it "says #{event}" do
        expect(voice.spoken(event.to_s, payload(url: 'https://api-rc.example.com/x'))).to(include(text))
      end
    end

    it 'names failed AMIs' do
      jobs = %w[api grpc].map { |name| { instance: name, state: 'failed' } }
      expect(voice.spoken('amis_done', payload(jobs: jobs))).to(include('api and grpc failed'))
    end

    it 'says all checks passed' do
      expect(voice.spoken('healthchecks_done', payload(failed: []))).to(include('All health checks'))
    end

    it 'names the failed services' do
      expect(voice.spoken('healthchecks_done', payload(failed: [{ url: 'https://api.example.com' }]))).to(include('failed for api'))
    end

    it 'falls back to the summary' do
      expect(voice.spoken('deploy_succeeded', payload)).to(include('Deployed'))
    end
  end

  describe 'the macOS plugin' do
    let(:mac) { plugin('macos_notification') }

    before { allow(mac).to(receive(:spawn_command)) }

    it 'follows the platform' do
      allow(mac).to(receive(:macos?).and_return(true))
      expect(mac.active?).to(be(true))
    end

    it 'shows an alert for the AMIs' do
      mac.handle('amis_done', payload(jobs: [{ instance: 'api', ami_id: 'ami-1', state: 'available' }]))
      expect(mac).to(have_received(:spawn_command).with('osascript', '-e', include('display alert')))
    end

    it 'escapes quotes' do
      mac.handle('deploy_failed', payload(error: 'say "hi"'))
      expect(mac).to(have_received(:spawn_command).with('osascript', '-e', include('\\"hi\\"')))
    end

    it 'reports failed checks' do
      mac.handle('healthchecks_done', payload(failed: [{ url: 'u' }]))
      expect(mac).to(have_received(:spawn_command))
    end

    it 'stays quiet when the checks pass' do
      mac.handle('healthchecks_done', payload(failed: []))
      expect(mac).not_to(have_received(:spawn_command))
    end
  end

  describe RunLog do
    let(:path)    { File.join(home, 'logs', 'run.log') }
    let(:run_log) { described_class.new(path)          }

    after { run_log.close }

    it 'creates a private directory' do
      run_log
      expect(File.stat(File.dirname(path)).mode & 0o777).to(eq(0o700))
    end

    it 'creates a private file' do
      run_log
      expect(File.stat(path).mode & 0o777).to(eq(0o600))
    end

    it 'refuses to follow a planted symlink' do
      link = File.join(home, 'planted.log')
      File.symlink(File.join(home, 'target'), link)
      expect { described_class.new(link) }
        .to(raise_error(SystemCallError))
    end

    it 'refuses to reuse an existing file' do
      taken = File.join(home, 'taken.log')
      File.write(taken, '')
      expect { described_class.new(taken) }
        .to(raise_error(Errno::EEXIST))
    end

    it 'stamps lines and removes terminal codes' do
      run_log.write("\e[2Khello\n")
      expect(File.read(path)).to(match(/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d hello\n\z/))
    end

    it 'keeps an existing timestamp' do
      run_log.write("2026-01-01 00:00:00 hello\n")
      expect(File.read(path)).to(eq("2026-01-01 00:00:00 hello\n"))
    end

    it 'ignores writes after closing' do
      run_log.close
      expect { run_log.write('x') }
        .not_to(raise_error)
    end

    it 'turns itself off when writing fails' do
      allow(File).to(receive(:open).and_return(instance_double(File, :sync= => true, close: nil).tap { |file| allow(file).to(receive(:write).and_raise(Errno::ENOSPC)) }))
      expect(quietly { run_log.write('x') }).to(include('turned off'))
    end
  end

  describe TeeOutput do
    let(:console) { StringIO.new }
    let(:run_log) { instance_double(RunLog, write: nil)   }
    let(:tee)     { described_class.new(console, run_log) }

    it 'writes puts to both' do
      tee.puts('a')
      expect(run_log).to(have_received(:write).with("a\n"))
    end

    it 'writes print to the console' do
      tee.print('a', 'b')
      expect(console.string).to(eq('ab'))
    end

    it 'supports <<' do
      tee << 'a'
      expect(console.string).to(eq('a'))
    end

    it 'flushes' do
      expect(tee.flush).to(be(tee))
    end

    it 'follows the console terminal state' do
      expect(tee.tty?).to(be(false))
    end

    it 'exposes the descriptor' do
      expect(described_class.new($stdout, run_log).fileno).to(eq($stdout.fileno))
    end
  end

  describe '#start_run_log' do
    def logs
      Dir.glob(File.join(home, 'logs', '*.log'))
    end

    def with_log(run_options = options)
      capture_stdout do
        start_run_log(run_options)
        yield if block_given?
        stop_run_log
      end
    end

    it 'logs what is printed under ~/.deploy' do
      with_log { log('hello') }
      expect(File.read(logs.first)).to(include('hello'))
    end

    it 'names the file without path separators' do
      with_log(options.merge(profile: 'a/b'))
      expect(File.basename(logs.first)).to(end_with('-a_b-beta1.log'))
    end

    it 'writes nothing with --dry-run' do
      start_run_log(options.merge('dry-run': true))
      expect(logs).to(be_empty)
    end

    it 'can be turned off' do
      File.write(File.join(home, 'config.yaml'), "log:\n  enabled: false\n")
      start_run_log(options)
      expect(logs).to(be_empty)
    end

    it 'honours a configured directory' do
      other = File.join(home, 'elsewhere')
      File.write(File.join(home, 'config.yaml'), YAML.dump(yaml_settings({ log: { directory: other } })))
      with_log
      expect(Dir.children(other).size).to(eq(1))
    end

    it 'refuses a log setting that is not a mapping' do
      File.write(File.join(home, 'config.yaml'), "log: nope\n")
      expect { start_run_log(options) }
        .to(raise_error(PreflightError, /must be a mapping/))
    end

    it 'keeps going when the directory cannot be created' do
      allow(FileUtils).to(receive(:mkdir_p).and_raise(Errno::EACCES))
      expect(quietly { start_run_log(options) }).to(include('no run log'))
    end
  end

  describe 'a run with a log' do
    let(:path) { File.join(home, 'run.log') }
    let(:run_log) { RunLog.new(path) }

    before { instance_variable_set(:@run_log, run_log) }

    def with_tee(console, &)
      capture_with(TeeOutput.new(console, run_log), &)
    end

    def capture_with(output)
      previous = $stdout
      $stdout = output
      yield
    ensure
      $stdout = previous
    end

    it 'records answers' do
      allow($stdin).to(receive(:gets).and_return('Y'))
      read_answer
      expect(File.read(path)).to(match(/ Y$/))
    end

    it 'draws the table on the terminal and logs plain rows' do
      console = instance_double(IO, tty?: true, print: nil)
      table = instance_double(AmiStatusTable, render: nil)
      allow(AmiStatusTable).to(receive(:new).and_return(table))
      with_tee(console) { with_ami_status_table([]) { nil } }
      expect(AmiStatusTable).to(have_received(:new).with([], console, run_log))
    end
  end

  describe '#deploy_from_cli' do
    before { allow(self).to(receive(:start_plugins)) { instance_variable_set(:@plugins, plugins) } }

    let(:plugins) { instance_double(PluginManager, emit: nil, shutdown: nil) }

    def run_cli
      quietly { deploy_from_cli(options) }
    rescue SystemExit, StandardError, SignalException
      nil
    end

    {
      PreflightError.new('no') => [:deploy_aborted, { reason: 'no' }],
      RuntimeError.new('boom') => [:deploy_failed, { error: 'boom' }],
      Interrupt.new => [:deploy_interrupted, {}]
    }.each do |failure, (event, details)|
      it "reports #{failure.class} as #{event}" do
        allow(self).to(receive(:run_deployment).and_raise(failure))
        run_cli
        expect(plugins).to(have_received(:emit).with(event, details))
      end
    end

    it 'stops the plugins at the end' do
      allow(self).to(receive(:run_deployment))
      run_cli
      expect(plugins).to(have_received(:shutdown))
    end
  end

  describe '#start_plugins' do
    it 'stays off with --dry-run' do
      start_plugins(options.merge('dry-run': true))
      expect(instance_variable_get(:@plugins)).to(be_nil)
    end

    it 'reads ~/.deploy and names what it started' do
      write_plugins({ webhook: { enabled: true, url: 'https://example.com/x' } })
      expect(capture_stdout { start_plugins(options) }).to(include('Plugins: webhook'))
    end
  end

  describe '#parse_deploy_options' do
    def base
      %w[--environment beta1 --profile dev --instance api]
    end

    it 'turns everything off for a bare --disable-plugins' do
      expect(parse_deploy_options(base + %w[--disable-plugins])).to(include('disable-plugins': ['all']))
    end

    it 'refuses an unknown plugin' do
      expect { quietly { parse_deploy_options(base + %w[--disable-plugins nope]) } }
        .to(raise_error(SystemExit))
    end

    it 'accepts --sms' do
      expect(parse_deploy_options(base + %w[--sms])).to(include(sms: true))
    end
  end

  describe '#resume_command' do
    it 'keeps the notification choices' do
      command = resume_command(['api'], yaml_settings({ api: 'ami-1' }), options.merge(sms: true, 'disable-plugins': %w[voice]))
      expect(command).to(include('--sms', '--disable-plugins voice'))
    end
  end

  describe 'event wiring' do
    let(:plugins) { instance_double(PluginManager, emit: nil, shutdown: nil) }

    before do
      instance_variable_set(:@plugins, plugins)
      allow(self).to(receive(:sleep))
    end

    it 'redacts URLs in health-check events' do
      allow(self).to(receive(:healthcheck_failure).and_return('HTTP 503'))
      quietly { run_healthchecks({ urls: ['https://me:pw@x/h?token=abc'], interval: 1, give_up_after: 0 }) }
      expect(plugins).to(have_received(:emit).with(:healthcheck_gave_up, { url: 'https://x/h', reason: 'HTTP 503' }))
    end

    it 'reports a recovered URL' do
      answers = ['HTTP 503', nil]
      allow(self).to(receive(:healthcheck_failure)) { answers.shift }
      quietly { run_healthchecks({ urls: ['https://x/h'], interval: 1, give_up_after: 60 }) }
      expect(plugins).to(have_received(:emit).with(:healthcheck_recovered, hash_including(url: 'https://x/h')))
    end

    it 'announces a question before waiting for the answer' do
      allow($stdin).to(receive_messages(gets: 'n', tty?: true))
      capture_stdout { wait_for_unready?(['api']) }
      expect(plugins).to(have_received(:emit).with(:question, { kind: 'standalones_not_ready', names: ['api'] }))
    end
  end
end
