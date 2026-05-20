#!/usr/bin/env ruby
#
# https://docs.aws.amazon.com/sdk-for-ruby

# frozen_string_literal: true

require 'aws-sdk-cloudwatchlogs'
require 'aws-sdk-core'
require 'aws-sdk-kms'
require 'optparse'

KMS_ENVIRONMENTS = %i[beta rc prod].freeze

def infer_environment(string)
  KMS_ENVIRONMENTS.find { |env| string.include?(env.to_s) }
end

def build_kms_key_map(kms)
  keys = {}

  kms.list_keys.each_page do |page|
    page[:keys].each do |key|
      key_metadata = kms.describe_key(
        {
          key_id: key.key_id
        }
      )
      env = KMS_ENVIRONMENTS.find { |candidate| key_metadata[:key_metadata][:description].start_with?(candidate.to_s) }
      keys[env] = key_metadata[:key_metadata][:arn] if env
    end
  end

  KMS_ENVIRONMENTS.each do |env|
    raise("KMS key not found for environment '#{env}'") if keys[env].nil?
  end

  keys
end

def process_log_group(logs, log_group, keys, retention_in_days)
  if log_group[:retention_in_days] != retention_in_days
    puts("Set retention policy on #{log_group[:log_group_name]} to #{retention_in_days} days...")
    logs.put_retention_policy(
      {
        log_group_name: log_group[:log_group_name],
        retention_in_days: retention_in_days
      }
    )
  end

  return if log_group[:kms_key_id]

  env = infer_environment(log_group[:log_group_name])
  raise("Cannot infer KMS environment from log group '#{log_group[:log_group_name]}'; expected name to contain one of #{KMS_ENVIRONMENTS.join(', ')}") if env.nil?

  key = keys[env]
  puts("Encrypting #{log_group[:log_group_name]} with key = #{key}...")
  logs.associate_kms_key(
    {
      log_group_name: log_group[:log_group_name],
      kms_key_id: key
    }
  )
end

def parse_encrypt_logs_options(argv = ARGV)
  options = {}

  OptionParser.new do |opts|
    opts.banner = 'Usage: encrypt_logs.rb options'
    opts.separator('')
    opts.separator('options')

    opts.on('--profile profile', String)
    opts.on('--retention_in_days retention_in_days', Integer)
    opts.on('-h', '--help') do
      puts(opts)
      exit(1)
    end
  end.parse!(argv, into: options)

  mandatory = %i[profile retention_in_days]
  missing = mandatory.select { |param| options[param].nil? }
  raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

  options
end

def run_encrypt_logs(options)
  if options[:profile]
    puts('Setting profile...')
    Aws.config.update({ profile: options[:profile] })
  end

  kms = Aws::KMS::Client.new
  keys = build_kms_key_map(kms)
  logs = Aws::CloudWatchLogs::Client.new

  logs.describe_log_groups.each_page do |page|
    page.log_groups.each do |log_group|
      process_log_group(logs, log_group, keys, options[:retention_in_days])
    end
  end
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    run_encrypt_logs(parse_encrypt_logs_options)
  rescue StandardError => e
    warn(e)
    warn(e.backtrace)
    exit(1)
  end
end
# :nocov:
