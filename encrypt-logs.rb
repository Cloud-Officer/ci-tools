#!/usr/bin/env ruby
#
# to install just run
#     gem install aws-sdk
#
# https://docs.aws.amazon.com/sdk-for-ruby

# frozen_string_literal: true

require 'aws-sdk-cloudwatchlogs'
require 'aws-sdk-core'
require 'aws-sdk-kms'
require 'optparse'

def build_kms_key_map(kms)
  keys = {}

  kms.list_keys[:keys].each do |key|
    key_metadata = kms.describe_key(
      {
        key_id: key.key_id
      }
    )

    if key_metadata[:key_metadata][:description].start_with?('beta')
      keys[:beta] = key_metadata[:key_metadata][:arn]
    elsif key_metadata[:key_metadata][:description].start_with?('rc')
      keys[:rc] = key_metadata[:key_metadata][:arn]
    elsif key_metadata[:key_metadata][:description].start_with?('prod')
      keys[:prod] = key_metadata[:key_metadata][:arn]
    end
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

  key =
    if log_group[:log_group_name].include?('beta')
      keys[:beta]
    elsif log_group[:log_group_name].include?('rc')
      keys[:rc]
    else
      keys[:prod]
    end

  puts("Encrypting #{log_group[:log_group_name]} with key = #{key}...")
  logs.associate_kms_key(
    {
      log_group_name: log_group[:log_group_name],
      kms_key_id: key
    }
  )
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    # parse command line options

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
    end.parse!(into: options)

    mandatory = %i[profile retention_in_days]
    missing = mandatory.select { |param| options[param].nil? }
    raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

    if options[:profile]
      puts('Setting profile...')
      Aws.config.update({ profile: options[:profile] })
    end

    kms = Aws::KMS::Client.new
    keys = build_kms_key_map(kms)

    logs = Aws::CloudWatchLogs::Client.new

    logs.describe_log_groups[:log_groups].each do |log_group|
      process_log_group(logs, log_group, keys, options[:retention_in_days])
    end
  rescue StandardError => e
    puts(e)
    puts(e.backtrace)
    exit(1)
  end
end
# :nocov:
