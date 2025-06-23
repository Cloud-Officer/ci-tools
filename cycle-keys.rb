#!/usr/bin/env ruby

# frozen_string_literal: true

require 'aws-sdk-iam'
require 'date'
require 'inifile'
require 'optparse'

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
      else
        if key_metadata.status == 'Active'
          puts("\tDisabling #{key_metadata.access_key_id}")
          begin
            iam.update_access_key(
              {
                access_key_id: key_metadata.access_key_id,
                status: 'Inactive',
                user_name: key_metadata.user_name
              }
            )
          rescue StandardError => e
            puts("\tError disabling access key")
            pp(e)
            exit(1)
          end
        end
        puts("\tDeleting #{key_metadata.access_key_id}")
        begin
          iam.delete_access_key(
            {
              access_key_id: key_metadata.access_key_id,
              user_name: key_metadata.user_name
            }
          )
        rescue StandardError => e
          puts("\tError deleting access key")
          pp(e)
          exit(1)
        end
      end
    end

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

    begin
      response = iam.create_access_key(
        {
          user_name: user_name
        }
      )
      puts("\tCreated key: #{response.access_key.access_key_id}")
      credentials[profile]['aws_access_key_id'] = response.access_key.access_key_id
      credentials[profile]['aws_secret_access_key'] = response.access_key.secret_access_key

      credentials.write
      puts("\tNew key saved into: #{credentials.filename}")
    rescue StandardError => e
      puts("\tError creating new access key")
      pp(e)
      exit(1)
    end

    # disable old key
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
      exit(1)
    end

    # delete old key

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
      exit(1)
    end
  end
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
