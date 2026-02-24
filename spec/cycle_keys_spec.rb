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
