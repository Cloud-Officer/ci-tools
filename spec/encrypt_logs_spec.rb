# frozen_string_literal: true

module EncryptLogs
  # Methods defined in encrypt-logs.rb
end

RSpec.describe(EncryptLogs) do
  describe '#build_kms_key_map' do
    let(:kms) { Aws::KMS::Client.new(stub_responses: true) }

    context 'with matching key descriptions' do
      before do
        kms.stub_responses(:list_keys, { keys: [{ key_id: 'key-1' }, { key_id: 'key-2' }, { key_id: 'key-3' }] })
        kms.stub_responses(
          :describe_key,
          [
            { key_metadata: { key_id: 'key-1', arn: 'arn:aws:kms:us-east-1:123:key/key-1', description: 'beta encryption key' } },
            { key_metadata: { key_id: 'key-2', arn: 'arn:aws:kms:us-east-1:123:key/key-2', description: 'rc encryption key' } },
            { key_metadata: { key_id: 'key-3', arn: 'arn:aws:kms:us-east-1:123:key/key-3', description: 'prod encryption key' } }
          ]
        )
      end

      it 'builds a map of environment to KMS key ARN', :aggregate_failures do
        result = build_kms_key_map(kms)
        expect(result[:beta]).to(eq('arn:aws:kms:us-east-1:123:key/key-1'))
        expect(result[:rc]).to(eq('arn:aws:kms:us-east-1:123:key/key-2'))
        expect(result[:prod]).to(eq('arn:aws:kms:us-east-1:123:key/key-3'))
      end
    end

    context 'with non-matching key description' do
      before do
        kms.stub_responses(:list_keys, { keys: [{ key_id: 'key-1' }] })
        kms.stub_responses(:describe_key, [{ key_metadata: { key_id: 'key-1', arn: 'arn:aws:kms:us-east-1:123:key/key-1', description: 'some other key' } }])
      end

      it 'raises error for missing environment key' do
        expect { build_kms_key_map(kms) }
          .to(raise_error(RuntimeError, "KMS key not found for environment 'beta'"))
      end
    end

    context 'with no keys' do
      before { kms.stub_responses(:list_keys, { keys: [] }) }

      it 'raises error for missing environment key' do
        expect { build_kms_key_map(kms) }
          .to(raise_error(RuntimeError, "KMS key not found for environment 'beta'"))
      end
    end

    context 'with partially populated keys' do
      before do
        kms.stub_responses(:list_keys, { keys: [{ key_id: 'key-1' }, { key_id: 'key-2' }] })
        kms.stub_responses(
          :describe_key,
          [
            { key_metadata: { key_id: 'key-1', arn: 'arn:aws:kms:us-east-1:123:key/key-1', description: 'beta encryption key' } },
            { key_metadata: { key_id: 'key-2', arn: 'arn:aws:kms:us-east-1:123:key/key-2', description: 'rc encryption key' } }
          ]
        )
      end

      it 'raises error for missing prod key' do
        expect { build_kms_key_map(kms) }
          .to(raise_error(RuntimeError, "KMS key not found for environment 'prod'"))
      end
    end
  end

  describe '#process_log_group' do
    let(:logs) { Aws::CloudWatchLogs::Client.new(stub_responses: true) }
    let(:keys)              { { beta: 'arn:beta-key', rc: 'arn:rc-key', prod: 'arn:prod-key' } }
    let(:retention_in_days) { 30                                                               }

    before do
      allow(logs).to(receive(:put_retention_policy).and_call_original)
      allow(logs).to(receive(:associate_kms_key).and_call_original)
    end

    context 'when retention differs' do
      let(:log_group) { { log_group_name: '/aws/beta/api', retention_in_days: 7, kms_key_id: 'already-encrypted' } }

      it 'sets retention policy' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).to(have_received(:put_retention_policy).with(hash_including(log_group_name: '/aws/beta/api', retention_in_days: 30)))
      end
    end

    context 'when retention already correct' do
      let(:log_group) { { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: 'already-encrypted' } }

      it 'skips retention update' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).not_to(have_received(:put_retention_policy))
      end
    end

    context 'with unencrypted beta log group' do
      let(:log_group) { { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: nil } }

      it 'encrypts with beta key' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).to(have_received(:associate_kms_key).with(hash_including(log_group_name: '/aws/beta/api', kms_key_id: 'arn:beta-key')))
      end
    end

    context 'with unencrypted rc log group' do
      let(:log_group) { { log_group_name: '/aws/rc/api', retention_in_days: 30, kms_key_id: nil } }

      it 'encrypts with rc key' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).to(have_received(:associate_kms_key).with(hash_including(kms_key_id: 'arn:rc-key')))
      end
    end

    context 'with unencrypted non-beta non-rc log group' do
      let(:log_group) { { log_group_name: '/aws/production/api', retention_in_days: 30, kms_key_id: nil } }

      it 'encrypts with prod key' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).to(have_received(:associate_kms_key).with(hash_including(kms_key_id: 'arn:prod-key')))
      end
    end

    context 'with already encrypted log group' do
      let(:log_group) { { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: 'existing-key' } }

      it 'skips encryption' do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).not_to(have_received(:associate_kms_key))
      end
    end

    context 'when both retention and encryption needed' do
      let(:log_group) { { log_group_name: '/aws/beta/api', retention_in_days: 7, kms_key_id: nil } }

      it 'updates retention and encrypts', :aggregate_failures do
        process_log_group(logs, log_group, keys, retention_in_days)
        expect(logs).to(have_received(:put_retention_policy))
        expect(logs).to(have_received(:associate_kms_key))
      end
    end
  end
end
