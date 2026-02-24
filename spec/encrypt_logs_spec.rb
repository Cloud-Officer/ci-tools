# frozen_string_literal: true

RSpec.describe('encrypt-logs.rb') do
  describe '#build_kms_key_map' do
    let(:kms) { Aws::KMS::Client.new(stub_responses: true) }

    it 'builds a map of environment to KMS key ARN' do
      kms.stub_responses(
        :list_keys,
        {
          keys: [
            { key_id: 'key-1' },
            { key_id: 'key-2' },
            { key_id: 'key-3' }
          ]
        }
      )
      kms.stub_responses(
        :describe_key,
        [
          { key_metadata: { key_id: 'key-1', arn: 'arn:aws:kms:us-east-1:123:key/key-1', description: 'beta encryption key' } },
          { key_metadata: { key_id: 'key-2', arn: 'arn:aws:kms:us-east-1:123:key/key-2', description: 'rc encryption key' } },
          { key_metadata: { key_id: 'key-3', arn: 'arn:aws:kms:us-east-1:123:key/key-3', description: 'prod encryption key' } }
        ]
      )
      result = build_kms_key_map(kms)
      expect(result['beta']).to(eq('arn:aws:kms:us-east-1:123:key/key-1'))
      expect(result['rc']).to(eq('arn:aws:kms:us-east-1:123:key/key-2'))
      expect(result['prod']).to(eq('arn:aws:kms:us-east-1:123:key/key-3'))
    end

    it 'ignores keys with non-matching descriptions' do
      kms.stub_responses(
        :list_keys,
        { keys: [{ key_id: 'key-1' }] }
      )
      kms.stub_responses(
        :describe_key,
        [{ key_metadata: { key_id: 'key-1', arn: 'arn:aws:kms:us-east-1:123:key/key-1', description: 'some other key' } }]
      )
      result = build_kms_key_map(kms)
      expect(result).to(be_empty)
    end

    it 'returns empty map when no keys exist' do
      kms.stub_responses(:list_keys, { keys: [] })
      result = build_kms_key_map(kms)
      expect(result).to(eq({}))
    end
  end

  describe '#process_log_group' do
    let(:logs) { Aws::CloudWatchLogs::Client.new(stub_responses: true) }
    let(:keys)              { { 'beta' => 'arn:beta-key', 'rc' => 'arn:rc-key', 'prod' => 'arn:prod-key' } }
    let(:retention_in_days) { 30                                                                           }

    before do
      allow(logs).to(receive(:put_retention_policy).and_call_original)
      allow(logs).to(receive(:associate_kms_key).and_call_original)
    end

    it 'sets retention when it differs' do
      log_group = { log_group_name: '/aws/beta/api', retention_in_days: 7, kms_key_id: 'already-encrypted' }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).to(
        have_received(:put_retention_policy).with(
          hash_including(log_group_name: '/aws/beta/api', retention_in_days: 30)
        )
      )
    end

    it 'skips retention when already correct' do
      log_group = { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: 'already-encrypted' }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).not_to(have_received(:put_retention_policy))
    end

    it 'encrypts with beta key for beta log group' do
      log_group = { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: nil }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).to(
        have_received(:associate_kms_key).with(
          hash_including(log_group_name: '/aws/beta/api', kms_key_id: 'arn:beta-key')
        )
      )
    end

    it 'encrypts with rc key for rc log group' do
      log_group = { log_group_name: '/aws/rc/api', retention_in_days: 30, kms_key_id: nil }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).to(
        have_received(:associate_kms_key).with(
          hash_including(kms_key_id: 'arn:rc-key')
        )
      )
    end

    it 'encrypts with prod key for non-beta non-rc log group' do
      log_group = { log_group_name: '/aws/production/api', retention_in_days: 30, kms_key_id: nil }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).to(
        have_received(:associate_kms_key).with(
          hash_including(kms_key_id: 'arn:prod-key')
        )
      )
    end

    it 'skips encryption when already encrypted' do
      log_group = { log_group_name: '/aws/beta/api', retention_in_days: 30, kms_key_id: 'existing-key' }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).not_to(have_received(:associate_kms_key))
    end

    it 'both updates retention and encrypts when needed' do
      log_group = { log_group_name: '/aws/beta/api', retention_in_days: 7, kms_key_id: nil }
      process_log_group(logs, log_group, keys, retention_in_days)
      expect(logs).to(have_received(:put_retention_policy))
      expect(logs).to(have_received(:associate_kms_key))
    end
  end
end
