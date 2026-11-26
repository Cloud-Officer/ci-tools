# frozen_string_literal: true

require 'aws-sdk-core'
require 'shellwords'

# Detects AWS SSO profiles and renews their expired sessions with `aws sso login`.
module AwsSso
  class SessionExpired < StandardError; end

  SESSION_ERRORS = [Aws::Errors::InvalidSSOToken, Aws::Errors::InvalidSSOCredentials, Aws::SSO::Errors::UnauthorizedException].freeze
  private_constant :SESSION_ERRORS

  module_function

  def login_command(profile)
    ['aws', 'sso', 'login', *(profile ? ['--profile', profile] : [])]
  end

  def config_file
    ENV.fetch('AWS_CONFIG_FILE', File.join(Dir.home, '.aws', 'config'))
  end

  def profile?(profile, file: config_file)
    return false unless File.file?(file)

    settings = Aws::IniParser.ini_parse(File.read(file))[profile] || {}
    settings.key?('sso_session') || settings.key?('sso_start_url')
  end

  # Signs in once and retries when the block fails on an expired SSO session and a terminal can answer the browser prompt.
  def with_sign_in(profile, interactive: $stdin.tty?)
    signed_in = false

    begin
      yield
    rescue *SESSION_ERRORS => e
      command = Shellwords.join(login_command(profile))
      raise(SessionExpired, "its SSO session has expired, sign in with: #{command} (#{e.message.lines.first.to_s.strip})", cause: nil) if signed_in || !interactive

      puts("The SSO session has expired, signing in with: #{command}")
      raise(SessionExpired, "the SSO sign-in failed, run: #{command}", cause: nil) unless system(*login_command(profile))

      signed_in = true
      retry
    end
  end
end
