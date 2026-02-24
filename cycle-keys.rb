#!/usr/bin/env ruby

# frozen_string_literal: true

require 'aws-sdk-iam'
require 'date'
require 'inifile'
require 'optparse'

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

  # Use file locking to prevent race conditions when multiple instances run simultaneously
  File.open("#{credentials_file_name}.lock", File::RDWR | File::CREAT, 0o600) do |lock_file|
    lock_file.flock(File::LOCK_EX)
    credentials.write
    puts("\tNew key saved into: #{credentials.filename}")
  end

  new_access_key_id
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

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    options = {}

    OptionParser.new do |opts|
      opts.banner = 'Usage: cycle-keys.rb options'
      opts.separator('')
      opts.separator('options')

      opts.on('--profile profile', String)
      opts.on('--username username', String)
      opts.on('--force')
      opts.on('-h', '--help') do
        puts(opts)
        exit(1)
      end
    end.parse!(into: options)

    mandatory = %i[profile username]
    missing = mandatory.select { |param| options[param].nil? }

    raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

    credentials_file_name = "#{Dir.home}/.aws/credentials"
    puts("Reading #{credentials_file_name}")
    credentials = IniFile.load(credentials_file_name)

    credentials.each_section do |profile|
      next if profile != options[:profile]

      region = credentials[profile]['region'] || 'us-east-1'
      access_key = credentials[profile]['aws_access_key_id']
      secret_key = credentials[profile]['aws_secret_access_key']

      puts("Processing \"#{profile}\" in #{region}: #{access_key}")
      iam = Aws::IAM::Client.new(
        region: region,
        credentials: Aws::Credentials.new(access_key, secret_key)
      )

      # list current keys

      user_name = ''
      age = 0
      begin
        response = iam.list_access_keys
      rescue StandardError => e
        puts("\tError listing access keys")
        pp(e)
        exit(1)
      end

      next if response.access_key_metadata.none?

      response.access_key_metadata.each do |key_metadata|
        if key_metadata.access_key_id == access_key
          age = (Integer(Time.now - key_metadata.create_date) / (24 * 60 * 60))
          user_name = key_metadata.user_name
        end
      end

      cleanup_secondary_keys(iam, access_key, response.access_key_metadata)

      # check username

      if user_name != options[:username]
        puts("\tUsername does not match: #{user_name}")
        exit(1)
      end

      # check date

      if age < 80 and options[:force].nil?
        puts("\tSkipping, key is only #{age} day(s) old")
        exit(0)
      end

      # create new key

      new_access_key_id = create_and_save_new_key(iam, credentials, profile, user_name, credentials_file_name)

      # Helper to rollback: delete new key and restore old credentials
      rollback =
        lambda do |error_context|
          puts("\tRolling back due to: #{error_context}")
          begin
            puts("\tDeleting newly created key #{new_access_key_id}...")
            iam.delete_access_key(
              {
                access_key_id: new_access_key_id,
                user_name: user_name
              }
            )
            puts("\tRollback: deleted new key")

            # Restore original credentials
            credentials[profile]['aws_access_key_id'] = access_key
            credentials[profile]['aws_secret_access_key'] = secret_key
            File.open("#{credentials_file_name}.lock", File::RDWR | File::CREAT, 0o600) do |lock_file|
              lock_file.flock(File::LOCK_EX)
              credentials.write
              puts("\tRollback: restored original credentials")
            end
          rescue StandardError => e
            puts("\tWARNING: Rollback failed - manual cleanup required!")
            puts("\tNew key #{new_access_key_id} may still be active")
            pp(e)
          end
        end

      disable_and_delete_old_key(iam, access_key, user_name, rollback)
    end
  rescue StandardError => e
    puts(e)
    puts(e.backtrace)
    exit(1)
  end
end
# :nocov:
