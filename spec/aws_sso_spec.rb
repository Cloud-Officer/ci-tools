# frozen_string_literal: true

require 'tmpdir'

RSpec.describe(AwsSso) do
  let(:dir)    { Dir.mktmpdir             }
  let(:config) { File.join(dir, 'config') }

  after { FileUtils.remove_entry(dir) }

  describe '.profile?' do
    before do
      File.write(config, <<~INI)
        [default]
        region = ca-central-1
        [profile sso]
        sso_session = company
        [profile legacy]
        sso_start_url = https://example.awsapps.com/start
        [profile keys]
        region = ca-central-1
        [sso-session company]
        sso_region = ca-central-1
      INI
    end

    it 'detects sso_session and sso_start_url profiles', :aggregate_failures do
      expect(described_class.profile?('sso', file: config)).to(be(true))
      expect(described_class.profile?('legacy', file: config)).to(be(true))
    end

    it 'leaves access-key and unknown profiles alone', :aggregate_failures do
      expect(described_class.profile?('keys', file: config)).to(be(false))
      expect(described_class.profile?('default', file: config)).to(be(false))
      expect(described_class.profile?('missing', file: config)).to(be(false))
    end

    it 'reads the file AWS_CONFIG_FILE names' do
      allow(described_class).to(receive(:config_file).and_call_original)
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('AWS_CONFIG_FILE', anything).and_return(config))
      expect(described_class.profile?('sso')).to(be(true))
    end

    it 'is false without a config file' do
      expect(described_class.profile?('sso', file: File.join(dir, 'none'))).to(be(false))
    end
  end

  describe '.login_command' do
    it 'names the profile only when there is one', :aggregate_failures do
      expect(described_class.login_command('in')).to(eq(%w[aws sso login --profile in]))
      expect(described_class.login_command(nil)).to(eq(%w[aws sso login]))
    end
  end

  describe '.with_sign_in' do
    def expired
      Aws::Errors::InvalidSSOToken.new('Token is invalid and failed to refresh.')
    end

    it 'returns the block value when the session is valid' do
      expect(described_class.with_sign_in('in', interactive: true) { 'arn' }).to(eq('arn'))
    end

    it 'signs in and retries once on an expired session', :aggregate_failures do
      allow(described_class).to(receive(:system).with('aws', 'sso', 'login', '--profile', 'in').and_return(true))
      attempts = [-> { raise(expired) }, -> { 'arn:me' }]
      expect(capture_stdout { expect(described_class.with_sign_in('in', interactive: true) { attempts.shift.call }).to(eq('arn:me')) }).to(include('signing in'))
      expect(described_class).to(have_received(:system).once)
    end

    it 'gives the sign-in command without a terminal', :aggregate_failures do
      allow(described_class).to(receive(:system))
      expect { described_class.with_sign_in('in', interactive: false) { raise(expired) } }
        .to(raise_error(AwsSso::SessionExpired, /expired, sign in with: aws sso login --profile in \(Token is invalid/))
      expect(described_class).not_to(have_received(:system))
    end

    it 'stops when the sign-in fails' do
      allow(described_class).to(receive(:system).and_return(false))
      expect { capture_stdout { described_class.with_sign_in('in', interactive: true) { raise(expired) } } }
        .to(raise_error(AwsSso::SessionExpired, /sign-in failed, run: aws sso login --profile in/))
    end

    it 'stops when the session is still refused after signing in' do
      allow(described_class).to(receive(:system).and_return(true))
      expect { capture_stdout { described_class.with_sign_in('in', interactive: true) { raise(Aws::Errors::InvalidSSOCredentials, 'Token has expired') } } }
        .to(raise_error(AwsSso::SessionExpired, /sign in with: aws sso login --profile in/))
    end

    it 'does not catch other errors' do
      expect { described_class.with_sign_in('in', interactive: true) { raise(Aws::Errors::NoSuchProfileError, 'no profile') } }
        .to(raise_error(Aws::Errors::NoSuchProfileError))
    end
  end
end
