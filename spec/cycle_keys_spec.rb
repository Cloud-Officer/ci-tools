# frozen_string_literal: true

module CycleKeys
  # Methods defined in cycle-keys.rb
end

RSpec.describe(CycleKeys) do
  describe '#cleanup_secondary_keys' do
    let(:iam)            { Aws::IAM::Client.new(stub_responses: true) }
    let(:primary_key_id) { 'AKIAIOSFODNN7EXAMPLE'                     }

    before do
      allow(iam).to(receive(:update_access_key).and_call_original)
      allow(iam).to(receive(:delete_access_key).and_call_original)
    end

    context 'with active secondary key' do
      let(:metadata) do
        [
          instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: primary_key_id, user_name: 'testuser', status: 'Active'),
          instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: 'AKIAI44QH8DHBSECONDARY', user_name: 'testuser', status: 'Active')
        ]
      end

      before { cleanup_secondary_keys(iam, primary_key_id, metadata) }

      it 'disables and deletes the key', :aggregate_failures do
        expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY', status: 'Inactive')))
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY')))
      end
    end

    context 'with inactive secondary key' do
      let(:metadata) do
        [
          instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: primary_key_id, user_name: 'testuser', status: 'Active'),
          instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: 'AKIAI44QH8DHBSECONDARY', user_name: 'testuser', status: 'Inactive')
        ]
      end

      before { cleanup_secondary_keys(iam, primary_key_id, metadata) }

      it 'deletes without disabling', :aggregate_failures do
        expect(iam).not_to(have_received(:update_access_key))
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY')))
      end
    end

    context 'with only primary key' do
      let(:metadata) do
        [instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: primary_key_id, user_name: 'testuser', status: 'Active')]
      end

      before { cleanup_secondary_keys(iam, primary_key_id, metadata) }

      it 'skips the primary key', :aggregate_failures do
        expect(iam).not_to(have_received(:update_access_key))
        expect(iam).not_to(have_received(:delete_access_key))
      end
    end

    context 'with empty metadata' do
      before { cleanup_secondary_keys(iam, primary_key_id, []) }

      it 'does nothing', :aggregate_failures do
        expect(iam).not_to(have_received(:update_access_key))
        expect(iam).not_to(have_received(:delete_access_key))
      end
    end
  end

  describe '#create_and_save_new_key' do
    let(:iam) { Aws::IAM::Client.new(stub_responses: true) }
    let(:credentials) { instance_double(IniParse::Document) }
    let(:user_name)   { 'testuser'                          }
    let(:lock_file)   { instance_double(File)               }

    before do
      iam.stub_responses(
        :create_access_key,
        { access_key: { access_key_id: 'AKIANEWKEY123', secret_access_key: 'secret123', user_name: user_name, status: 'Active' } }
      )
      allow(credentials).to(receive(:[]).with('test-profile').and_return({}))
      allow(credentials).to(receive(:save))
      allow(File).to(receive(:open).with('/tmp/test-credentials.lock', anything, anything).and_yield(lock_file))
      allow(lock_file).to(receive(:flock))
    end

    it 'creates a new access key and returns the key id' do
      expect(create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials')).to(eq('AKIANEWKEY123'))
    end

    it 'writes credentials with file lock', :aggregate_failures do
      create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials')
      expect(lock_file).to(have_received(:flock).with(File::LOCK_EX))
      expect(credentials).to(have_received(:save))
    end

    it 'updates credentials hash with new key', :aggregate_failures do
      cred_hash = {}
      allow(credentials).to(receive(:[]).with('test-profile').and_return(cred_hash))
      create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials')
      expect(cred_hash['aws_access_key_id']).to(eq('AKIANEWKEY123'))
      expect(cred_hash['aws_secret_access_key']).to(eq('secret123'))
    end

    context 'when credentials.save raises' do
      before do
        allow(credentials).to(receive(:save).and_raise(Errno::EACCES.new('permission denied')))
        allow(iam).to(receive(:delete_access_key).and_call_original)
      end

      it 're-raises the disk error after cleanup' do
        expect { create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials') }
          .to(raise_error(Errno::EACCES))
      end

      it 'deletes the orphaned AWS key' do
        begin
          create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials')
        rescue Errno::EACCES
          # expected; we want to inspect side effects after the raise
        end
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIANEWKEY123', user_name: user_name)))
      end
    end

    context 'when credentials.save raises and cleanup also fails' do
      before do
        allow(credentials).to(receive(:save).and_raise(Errno::EACCES.new('permission denied')))
        allow(iam).to(receive(:delete_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'cleanup failed')))
      end

      it 'still re-raises the original disk error' do
        expect { create_and_save_new_key(iam, credentials, 'test-profile', user_name, '/tmp/test-credentials') }
          .to(raise_error(Errno::EACCES))
      end
    end
  end

  describe '#rollback_key_change' do
    let(:iam)         { Aws::IAM::Client.new(stub_responses: true) }
    let(:credentials) { instance_double(IniParse::Document)        }
    let(:cred_hash)   { {}                                         }
    let(:lock_file)   { instance_double(File)                      }

    def call_rollback
      rollback_key_change(iam, credentials, 'test-profile', 'testuser', '/tmp/test-credentials', 'AKIANEWKEY123', 'AKIAOLDKEY123', 'oldsecret123', 'failed to disable old key')
    end

    before do
      allow(iam).to(receive(:delete_access_key).and_call_original)
      allow(credentials).to(receive(:[]).with('test-profile').and_return(cred_hash))
      allow(credentials).to(receive(:save))
      allow(File).to(receive(:open).with('/tmp/test-credentials.lock', anything, anything).and_yield(lock_file))
      allow(lock_file).to(receive(:flock))
    end

    it 'deletes the new key and saves restored credentials under lock', :aggregate_failures do
      call_rollback
      expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIANEWKEY123', user_name: 'testuser')))
      expect(lock_file).to(have_received(:flock).with(File::LOCK_EX))
      expect(credentials).to(have_received(:save))
    end

    it 'restores the original access-key fields in the credentials hash', :aggregate_failures do
      call_rollback
      expect(cred_hash['aws_access_key_id']).to(eq('AKIAOLDKEY123'))
      expect(cred_hash['aws_secret_access_key']).to(eq('oldsecret123'))
    end

    it 're-activates the original key so the restored credentials are usable' do
      allow(iam).to(receive(:update_access_key).and_call_original)
      call_rollback
      expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: 'AKIAOLDKEY123', status: 'Active', user_name: 'testuser')))
    end

    it 'still restores credentials when re-activate fails', :aggregate_failures do
      allow(iam).to(receive(:update_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'reactivate failed')))
      expect { call_rollback }
        .not_to(raise_error)
      expect(credentials).to(have_received(:save))
    end

    it 'swallows errors from delete_access_key without raising' do
      allow(iam).to(receive(:delete_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'API error')))
      expect { call_rollback }
        .not_to(raise_error)
    end

    it 'swallows errors from credentials.save without raising' do
      allow(credentials).to(receive(:save).and_raise(Errno::EACCES.new('permission denied')))
      expect { call_rollback }
        .not_to(raise_error)
    end
  end

  describe '#find_primary_key_user' do
    let(:now)      { Time.now }
    let(:created)  { now - (45 * 24 * 60 * 60)                                                                                                   }
    let(:other)    { instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: 'AKIAOTHER', user_name: 'other', create_date: created)   }
    let(:matching) { instance_double(Aws::IAM::Types::AccessKeyMetadata, access_key_id: 'AKIAMATCH', user_name: 'matched', create_date: created) }

    before { stub_const('Time', class_double(Time, now: now).as_stubbed_const) }

    it 'returns [user_name, age_days] for the matching access key' do
      expect(find_primary_key_user([other, matching], 'AKIAMATCH')).to(eq(['matched', 45]))
    end

    it 'returns [nil, 0] when no key matches' do
      expect(find_primary_key_user([], 'AKIAMISSING')).to(eq([nil, 0]))
    end
  end

  describe '#parse_cycle_keys_options' do
    it 'parses required args', :aggregate_failures do
      options = parse_cycle_keys_options(%w[--profile dev --username alice])
      expect(options[:profile]).to(eq('dev'))
      expect(options[:username]).to(eq('alice'))
    end

    it 'raises when missing args' do
      expect { parse_cycle_keys_options(%w[--profile dev]) }
        .to(raise_error(OptionParser::MissingArgument, /username/))
    end
  end

  describe '#run_cycle_keys' do
    let(:credentials_path) { "#{Dir.home}/.aws/credentials" }
    let(:credentials)      { instance_double(IniParse::Document)                   }
    let(:section)          { instance_double(IniParse::Lines::Section, key: 'dev') }

    before do
      allow(File).to(receive(:exist?).with(credentials_path).and_return(true))
      allow(IniParse).to(receive(:open).with(credentials_path).and_return(credentials))
      allow(credentials).to(receive(:each).and_yield(section))
    end

    context 'when no profile in credentials matches the --profile arg' do
      let(:section) { instance_double(IniParse::Lines::Section, key: 'production') }

      it 'returns without raising or exiting' do
        expect { run_cycle_keys({ profile: 'dev', username: 'alice' }) }
          .not_to(raise_error)
      end
    end

    context 'when the credentials file is missing' do
      before { allow(File).to(receive(:exist?).with(credentials_path).and_return(false)) }

      it 'raises a clear error' do
        expect { run_cycle_keys({ profile: 'dev', username: 'alice' }) }
          .to(raise_error(RuntimeError, /AWS credentials file not found/))
      end
    end

    context 'when process_credential_profile returns :error' do
      before { allow(self).to(receive(:process_credential_profile).and_return(:error)) }

      it 'exits with status 1', :aggregate_failures do
        expect { run_cycle_keys({ profile: 'dev', username: 'alice' }) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
      end
    end

    context 'when process_credential_profile returns :username_mismatch' do
      before { allow(self).to(receive(:process_credential_profile).and_return(:username_mismatch)) }

      it 'exits with status 1', :aggregate_failures do
        expect { run_cycle_keys({ profile: 'dev', username: 'alice' }) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
      end
    end

    context 'when process_credential_profile returns :too_young' do
      before { allow(self).to(receive(:process_credential_profile).and_return(:too_young)) }

      it 'exits with status 0 (success — nothing to rotate)', :aggregate_failures do
        expect { run_cycle_keys({ profile: 'dev', username: 'alice' }) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(0)) })
      end
    end
  end

  describe '#process_credential_profile' do
    let(:iam)         { Aws::IAM::Client.new(stub_responses: true)                                                    }
    let(:credentials) { instance_double(IniParse::Document)                                                           }
    let(:cred_hash)   { %w[region aws_access_key_id aws_secret_access_key].zip(%w[us-east-1 AKIACURRENT secret]).to_h }
    let(:options)     { { profile: 'dev', username: 'alice' }                                                         }

    before do
      allow(Aws::IAM::Client).to(receive(:new).and_return(iam))
      allow(credentials).to(receive(:[]).with('dev').and_return(cred_hash))
    end

    context 'when list_access_keys raises' do
      before { iam.stub_responses(:list_access_keys, 'ServiceError') }

      it 'returns :error and does not propagate' do
        expect(process_credential_profile(credentials, 'dev', options)).to(eq(:error))
      end
    end

    context 'when no keys exist' do
      before { iam.stub_responses(:list_access_keys, { access_key_metadata: [] }) }

      it 'returns :no_keys' do
        expect(process_credential_profile(credentials, 'dev', options)).to(eq(:no_keys))
      end
    end

    context 'when the primary key user does not match' do
      before do
        iam.stub_responses(:list_access_keys, { access_key_metadata: [{ access_key_id: 'AKIACURRENT', user_name: 'other', create_date: Time.now - (200 * 24 * 60 * 60), status: 'Active' }] })
        allow(iam).to(receive(:delete_access_key))
        allow(iam).to(receive(:update_access_key))
      end

      it 'returns :username_mismatch' do
        expect(process_credential_profile(credentials, 'dev', options)).to(eq(:username_mismatch))
      end

      it 'does not delete any keys (guards run before destructive cleanup)' do
        process_credential_profile(credentials, 'dev', options)
        expect(iam).not_to(have_received(:delete_access_key))
      end
    end

    context 'when the key is too young and --force is not set' do
      before do
        iam.stub_responses(:list_access_keys, { access_key_metadata: [{ access_key_id: 'AKIACURRENT', user_name: 'alice', create_date: Time.now - (10 * 24 * 60 * 60), status: 'Active' }] })
        allow(iam).to(receive(:delete_access_key))
        allow(iam).to(receive(:update_access_key))
      end

      it 'returns :too_young' do
        expect(process_credential_profile(credentials, 'dev', options)).to(eq(:too_young))
      end

      it 'does not delete any keys (guards run before destructive cleanup)' do
        process_credential_profile(credentials, 'dev', options)
        expect(iam).not_to(have_received(:delete_access_key))
      end
    end

    context 'when the key is old enough and the username matches (rotation happy path)' do
      let(:lock_file) { instance_double(File) }

      before do
        iam.stub_responses(:list_access_keys, { access_key_metadata: [{ access_key_id: 'AKIACURRENT', user_name: 'alice', create_date: Time.now - (100 * 24 * 60 * 60), status: 'Active' }, { access_key_id: 'AKIASECONDARY', user_name: 'alice', create_date: Time.now - (100 * 24 * 60 * 60), status: 'Active' }] })
        iam.stub_responses(:create_access_key, { access_key: { access_key_id: 'AKIANEWKEY123', secret_access_key: 'newsecret', user_name: 'alice', status: 'Active' } })
        allow(iam).to(receive(:create_access_key).and_call_original)
        allow(iam).to(receive(:update_access_key).and_call_original)
        allow(iam).to(receive(:delete_access_key).and_call_original)
        allow(credentials).to(receive(:save))
        allow(File).to(receive(:open).with("#{Dir.home}/.aws/credentials.lock", anything, anything).and_yield(lock_file))
        allow(lock_file).to(receive(:flock))
      end

      it 'returns :rotated' do
        expect(process_credential_profile(credentials, 'dev', options)).to(eq(:rotated))
      end

      it 'cleans up the secondary key and persists a new one', :aggregate_failures do
        process_credential_profile(credentials, 'dev', options)
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIASECONDARY')))
        expect(iam).to(have_received(:create_access_key).with(hash_including(user_name: 'alice')))
        expect(credentials).to(have_received(:save))
      end

      it 'disables then deletes the old key', :aggregate_failures do
        process_credential_profile(credentials, 'dev', options)
        expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: 'AKIACURRENT', status: 'Inactive')))
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIACURRENT')))
      end
    end

    context 'when disabling the old key fails after a new key was created' do
      let(:lock_file) { instance_double(File) }

      # Run the rotation and swallow the propagated error so examples can assert the rollback side effects.
      def run_failed_rotation
        process_credential_profile(credentials, 'dev', options)
      rescue Aws::IAM::Errors::ServiceError
        nil
      end

      before do
        iam.stub_responses(:list_access_keys, { access_key_metadata: [{ access_key_id: 'AKIACURRENT', user_name: 'alice', create_date: Time.now - (100 * 24 * 60 * 60), status: 'Active' }] })
        iam.stub_responses(:create_access_key, { access_key: { access_key_id: 'AKIANEWKEY123', secret_access_key: 'newsecret', user_name: 'alice', status: 'Active' } })
        allow(iam).to(receive(:create_access_key).and_call_original)
        allow(iam).to(receive(:delete_access_key).and_call_original)
        # Fail the disable step (status Inactive) so the captured rollback lambda fires; re-activate (Active) succeeds.
        allow(iam).to(receive(:update_access_key)) { |args| raise(Aws::IAM::Errors::ServiceError.new(nil, 'disable failed')) if args[:status] == 'Inactive' }
        allow(credentials).to(receive(:save))
        allow(File).to(receive(:open).with("#{Dir.home}/.aws/credentials.lock", anything, anything).and_yield(lock_file))
        allow(lock_file).to(receive(:flock))
      end

      it 'propagates the error after rolling back' do
        expect { process_credential_profile(credentials, 'dev', options) }
          .to(raise_error(Aws::IAM::Errors::ServiceError))
      end

      it 'deletes the newly created key during rollback' do
        run_failed_rotation
        expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIANEWKEY123', user_name: 'alice')))
      end

      it 're-activates the original key during rollback' do
        run_failed_rotation
        expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: 'AKIACURRENT', status: 'Active')))
      end

      it 'restores the original credentials during rollback', :aggregate_failures do
        run_failed_rotation
        expect(cred_hash['aws_access_key_id']).to(eq('AKIACURRENT'))
        expect(cred_hash['aws_secret_access_key']).to(eq('secret'))
      end
    end
  end

  describe '#disable_and_delete_old_key' do
    let(:iam) { Aws::IAM::Client.new(stub_responses: true) }
    let(:access_key) { 'AKIAOLDKEY123'       }
    let(:user_name)  { 'testuser'            }
    let(:rollback)   { instance_double(Proc) }

    before do
      allow(rollback).to(receive(:call))
      allow(iam).to(receive(:update_access_key).and_call_original)
      allow(iam).to(receive(:delete_access_key).and_call_original)
    end

    it 'disables then deletes the old key', :aggregate_failures do
      disable_and_delete_old_key(iam, access_key, user_name, rollback)
      expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: access_key, status: 'Inactive')))
      expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: access_key)))
    end

    it 'calls rollback and raises when disable fails', :aggregate_failures do
      allow(iam).to(receive(:update_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'error')))
      expect { disable_and_delete_old_key(iam, access_key, user_name, rollback) }
        .to(raise_error(Aws::IAM::Errors::ServiceError))
      expect(rollback).to(have_received(:call).with('failed to disable old key'))
    end

    it 'calls rollback and raises when delete fails', :aggregate_failures do
      allow(iam).to(receive(:delete_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'error')))
      expect { disable_and_delete_old_key(iam, access_key, user_name, rollback) }
        .to(raise_error(Aws::IAM::Errors::ServiceError))
      expect(rollback).to(have_received(:call).with('failed to delete old key'))
    end

    it 'does not call rollback on success' do
      disable_and_delete_old_key(iam, access_key, user_name, rollback)
      expect(rollback).not_to(have_received(:call))
    end
  end
end
