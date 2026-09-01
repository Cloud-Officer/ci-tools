#!/usr/bin/env ruby

# frozen_string_literal: true

require 'aws-sdk-iam'
require 'date'
require 'iniparse'
require_relative 'lib/cli_main'

DEFAULT_REGION = 'us-east-1'
# A freshly created access key is not usable for signing immediately - IAM is
# eventually consistent. Poll with the new key until it authenticates rather
# than assuming it is live.
NEW_KEY_ACTIVATION_ATTEMPTS = 10
NEW_KEY_ACTIVATION_DELAY_SECONDS = 2

def cleanup_secondary_keys(iam, primary_key_id, metadata_list)
  metadata_list.each do |key_metadata|
    next if key_metadata.access_key_id == primary_key_id

    if key_metadata.status == 'Active'
      puts("\tDisabling #{key_metadata.access_key_id}")
      iam.update_access_key(
        {
          access_key_id: key_metadata.access_key_id,
          status: 'Inactive',
          user_name: key_metadata.user_name
        }
      )
    end
    puts("\tDeleting #{key_metadata.access_key_id}")
    iam.delete_access_key(
      {
        access_key_id: key_metadata.access_key_id,
        user_name: key_metadata.user_name
      }
    )
  end
end

def create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)
  response = iam.create_access_key(
    {
      user_name: user_name
    }
  )
  new_access_key_id = response.access_key.access_key_id
  puts("\tCreated key: #{new_access_key_id}")
  credentials[profile]['aws_access_key_id'] = response.access_key.access_key_id
  credentials[profile]['aws_secret_access_key'] = response.access_key.secret_access_key

  begin
    # Use file locking to prevent race conditions when multiple instances run simultaneously
    File.open("#{credentials_file_name}.lock", File::RDWR | File::CREAT, 0o600) do |lock_file|
      lock_file.flock(File::LOCK_EX)
      credentials.save
      puts("\tNew key saved into: #{credentials_file_name}")
    end
  rescue StandardError => e
    puts("\tFailed to persist new key to #{credentials_file_name}, deleting #{new_access_key_id} from AWS...")
    begin
      iam.delete_access_key({ access_key_id: new_access_key_id, user_name: user_name })
      puts("\tCleanup succeeded: #{new_access_key_id} was deleted")
    rescue StandardError => cleanup_error
      puts("\tWARNING: manual cleanup required — orphaned key #{new_access_key_id} for #{user_name}")
      pp(cleanup_error)
    end
    raise(e)
  end

  response.access_key
end

def rollback_key_change(iam, credentials, profile, user_name, credentials_file_name, new_access_key_id, original_access_key, original_secret_key, error_context)
  puts("\tRolling back due to: #{error_context}")
  region = credentials[profile]['region'] || DEFAULT_REGION

  begin
    # Re-activate the original key first. The client we were handed may be
    # signing with the new key, and the delete below removes that key - so the
    # call that restores our fallback credentials has to happen while the
    # client making it is still valid.
    begin
      iam.update_access_key(
        {
          access_key_id: original_access_key,
          status: 'Active',
          user_name: user_name
        }
      )
      puts("\tRollback: re-activated original key #{original_access_key}")
    rescue StandardError => e
      puts("\tWARNING: failed to re-activate original key #{original_access_key} - manual intervention required")
      pp(e)
    end

    # Delete the new key with the restored original credentials so the request
    # does not depend on the very key it is deleting.
    puts("\tDeleting newly created key #{new_access_key_id}...")
    build_iam_client(region, original_access_key, original_secret_key).delete_access_key(
      {
        access_key_id: new_access_key_id,
        user_name: user_name
      }
    )
    puts("\tRollback: deleted new key")

    credentials[profile]['aws_access_key_id'] = original_access_key
    credentials[profile]['aws_secret_access_key'] = original_secret_key
    File.open("#{credentials_file_name}.lock", File::RDWR | File::CREAT, 0o600) do |lock_file|
      lock_file.flock(File::LOCK_EX)
      credentials.save
      puts("\tRollback: restored original credentials")
    end
  rescue StandardError => e
    puts("\tWARNING: Rollback failed - manual cleanup required!")
    puts("\tNew key #{new_access_key_id} may still be active")
    pp(e)
  end
end

def new_key_usable?(iam, new_access_key_id, attempts: NEW_KEY_ACTIVATION_ATTEMPTS, delay: NEW_KEY_ACTIVATION_DELAY_SECONDS)
  puts("\tWaiting for #{new_access_key_id} to become usable")

  attempts.times do |attempt|
    iam.list_access_keys
    return true
  rescue Aws::Errors::ServiceError => e
    if attempt == attempts - 1
      puts("\tNew key #{new_access_key_id} did not become usable after #{attempts} attempt(s)")
      pp(e)
      return false
    end

    sleep(delay)
  end

  false
end

KEY_AGE_DAYS_THRESHOLD = 80 # Compliance policy requires rotation every 90 days (CIS / access-keys-rotated rule); rotate at 80 to leave a 10-day buffer for cron schedules.

def build_iam_client(region, access_key, secret_key)
  Aws::IAM::Client.new(
    region: region,
    credentials: Aws::Credentials.new(access_key, secret_key)
  )
end

def find_primary_key_user(metadata_list, primary_key_id)
  metadata = metadata_list.find { |key_metadata| key_metadata.access_key_id == primary_key_id }
  return [nil, 0] if metadata.nil?

  age_days = Integer(Time.now - metadata.create_date) / (24 * 60 * 60)
  [metadata.user_name, age_days]
end

def process_credential_profile(credentials, profile, options)
  region = credentials[profile]['region'] || DEFAULT_REGION
  access_key = credentials[profile]['aws_access_key_id']
  secret_key = credentials[profile]['aws_secret_access_key']
  credentials_file_name = "#{Dir.home}/.aws/credentials"

  puts("Processing \"#{profile}\" in #{region}: #{access_key}")
  iam = build_iam_client(region, access_key, secret_key)

  begin
    response = iam.list_access_keys
  rescue StandardError => e
    puts("\tError listing access keys")
    pp(e)
    return :error
  end

  return :no_keys if response.access_key_metadata.none?

  user_name, age_days = find_primary_key_user(response.access_key_metadata, access_key)

  if user_name != options[:username]
    puts("\tUsername does not match: #{user_name}")
    return :username_mismatch
  end

  if age_days < KEY_AGE_DAYS_THRESHOLD && options[:force].nil?
    puts("\tSkipping, key is only #{age_days} day(s) old")
    return :too_young
  end

  # Cleanup runs only after the guards above - it is destructive (deletes
  # any non-primary keys) and must not fire on no-op paths.
  cleanup_secondary_keys(iam, access_key, response.access_key_metadata)
  new_key = create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)
  new_access_key_id = new_key.access_key_id

  rollback_using =
    lambda do |client|
      lambda do |error_context|
        rollback_key_change(client, credentials, profile, user_name, credentials_file_name, new_access_key_id, access_key, secret_key, error_context)
      end
    end

  # Retire the old key using the NEW key's own credentials. Signing the disable
  # and the delete with the key being retired means the delete - and the
  # rollback that would clean up after it - ride on credentials AWS has just
  # invalidated.
  rotated_iam = build_iam_client(region, new_access_key_id, new_key.secret_access_key)

  unless new_key_usable?(rotated_iam, new_access_key_id)
    # The old key is still Active here, so roll back through it.
    rollback_using.call(iam).call('new key never became usable')
    return :error
  end

  disable_and_delete_old_key(rotated_iam, access_key, user_name, rollback_using.call(rotated_iam))
  :rotated
end

def disable_and_delete_old_key(iam, access_key, user_name, rollback)
  puts("\tDisabling old access key")
  begin
    iam.update_access_key(
      {
        access_key_id: access_key,
        status: 'Inactive',
        user_name: user_name
      }
    )
  rescue StandardError => e
    puts("\tError disabling old access key")
    pp(e)
    rollback.call('failed to disable old key')
    raise
  end

  puts("\tDeleting old access key")
  begin
    iam.delete_access_key(
      {
        access_key_id: access_key,
        user_name: user_name
      }
    )
  rescue StandardError => e
    puts("\tError deleting access key")
    pp(e)
    rollback.call('failed to delete old key')
    raise
  end
end

def parse_cycle_keys_options(argv = ARGV)
  CliMain.parse_options!(mandatory: %i[profile username], argv: argv) do |opts|
    opts.on('--profile profile', String)
    opts.on('--username username', String)
    opts.on('--force')
  end
end

def run_cycle_keys(options)
  credentials_file_name = "#{Dir.home}/.aws/credentials"
  raise("AWS credentials file not found: #{credentials_file_name}") unless File.exist?(credentials_file_name)

  puts("Reading #{credentials_file_name}")
  credentials = IniParse.open(credentials_file_name)

  profile_found = false

  credentials.each do |section|
    next if section.key != options[:profile]

    profile_found = true
    result = process_credential_profile(credentials, section.key, options)
    case result
    when :error, :username_mismatch then exit(1)
    when :too_young then exit(0)
    end
  end

  raise("Profile '#{options[:profile]}' not found in #{credentials_file_name}") unless profile_found
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  CliMain.run! do
    run_cycle_keys(parse_cycle_keys_options)
  end
end
# :nocov:
