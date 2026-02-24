# frozen_string_literal: true

RSpec.describe('cycle-keys.rb') do
  describe '#cleanup_secondary_keys' do
    let(:iam)            { Aws::IAM::Client.new(stub_responses: true) }
    let(:primary_key_id) { 'AKIAIOSFODNN7EXAMPLE'                     }

    before do
      allow(iam).to(receive(:update_access_key).and_call_original)
      allow(iam).to(receive(:delete_access_key).and_call_original)
    end

    it 'disables and deletes active secondary keys' do
      metadata = [
        double('key', access_key_id: primary_key_id, user_name: 'testuser', status: 'Active'),
        double('key', access_key_id: 'AKIAI44QH8DHBSECONDARY', user_name: 'testuser', status: 'Active')
      ]
      cleanup_secondary_keys(iam, primary_key_id, metadata)
      expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY', status: 'Inactive')))
      expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY')))
    end

    it 'deletes inactive secondary keys without disabling' do
      metadata = [
        double('key', access_key_id: primary_key_id, user_name: 'testuser', status: 'Active'),
        double('key', access_key_id: 'AKIAI44QH8DHBSECONDARY', user_name: 'testuser', status: 'Inactive')
      ]
      cleanup_secondary_keys(iam, primary_key_id, metadata)
      expect(iam).not_to(have_received(:update_access_key))
      expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: 'AKIAI44QH8DHBSECONDARY')))
    end

    it 'skips the primary key' do
      metadata = [
        double('key', access_key_id: primary_key_id, user_name: 'testuser', status: 'Active')
      ]
      cleanup_secondary_keys(iam, primary_key_id, metadata)
      expect(iam).not_to(have_received(:update_access_key))
      expect(iam).not_to(have_received(:delete_access_key))
    end

    it 'handles empty metadata list' do
      cleanup_secondary_keys(iam, primary_key_id, [])
      expect(iam).not_to(have_received(:update_access_key))
      expect(iam).not_to(have_received(:delete_access_key))
    end
  end

  describe '#create_and_save_new_key' do
    let(:iam) { Aws::IAM::Client.new(stub_responses: true) }
    let(:credentials)           { instance_double(IniFile, filename: '/tmp/test-credentials') }
    let(:profile)               { 'test-profile'                                              }
    let(:user_name)             { 'testuser'                                                  }
    let(:credentials_file_name) { '/tmp/test-credentials'                                     }
    let(:lock_file)             { instance_double(File)                                       }

    before do
      iam.stub_responses(
        :create_access_key,
        {
          access_key: {
            access_key_id: 'AKIANEWKEY123',
            secret_access_key: 'secret123',
            user_name: user_name,
            status: 'Active'
          }
        }
      )
      allow(credentials).to(receive(:[]).with(profile).and_return({}))
      allow(credentials).to(receive(:write))
      allow(File).to(receive(:open).with("#{credentials_file_name}.lock", anything, anything).and_yield(lock_file))
      allow(lock_file).to(receive(:flock))
    end

    it 'creates a new access key and returns the key id' do
      result = create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)
      expect(result).to(eq('AKIANEWKEY123'))
    end

    it 'writes credentials with file lock' do
      create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)
      expect(lock_file).to(have_received(:flock).with(File::LOCK_EX))
      expect(credentials).to(have_received(:write))
    end

    it 'updates credentials hash with new key' do
      cred_hash = {}
      allow(credentials).to(receive(:[]).with(profile).and_return(cred_hash))
      create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)
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

    it 'disables then deletes the old key' do
      disable_and_delete_old_key(iam, access_key, user_name, rollback)
      expect(iam).to(have_received(:update_access_key).with(hash_including(access_key_id: access_key, status: 'Inactive')))
      expect(iam).to(have_received(:delete_access_key).with(hash_including(access_key_id: access_key)))
    end

    it 'calls rollback and raises when disable fails' do
      allow(iam).to(receive(:update_access_key).and_raise(Aws::IAM::Errors::ServiceError.new(nil, 'error')))
      expect { disable_and_delete_old_key(iam, access_key, user_name, rollback) }
        .to(raise_error(Aws::IAM::Errors::ServiceError))
      expect(rollback).to(have_received(:call).with('failed to disable old key'))
    end

    it 'calls rollback and raises when delete fails' do
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
