# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'
require_relative 'plugins'

# The interface of a notification plugin.
class Plugin
  DEFAULT_EVENTS = Plugins::EVENTS
  SETTINGS = [].freeze
  HTTP_ATTEMPTS = 3
  HTTP_OPEN_TIMEOUT = 10
  HTTP_READ_TIMEOUT = 15
  HTTP_RETRY_DELAY = 2
  NETWORK_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

  SUMMARIES = {
    deploy_started: ->(_payload, where, instances) { "Deploying #{instances} to #{where}" },
    question: ->(payload, where, _instances) { "#{question_text(payload)} on #{where}: waiting for an answer" },
    amis_done: ->(payload, where, _instances) { "AMIs done for #{where}: #{ami_list(payload)}" },
    amis_ready: ->(payload, where, _instances) { "AMIs ready for #{where}: #{ami_list(payload)}" },
    stack_updated: ->(_payload, where, _instances) { "CloudFormation finished for #{where}" },
    rollout_started: ->(payload, where, _instances) { "Replacing the instances of #{where}: scaling #{scaling_list(payload)}" },
    rollout_done: ->(_payload, where, _instances) { "Instances of #{where} replaced" },
    healthcheck_failing: ->(payload, _where, _instances) { "Health check failing for #{payload[:url]} (#{payload[:reason]}), retrying" },
    healthcheck_recovered: ->(payload, _where, _instances) { "Health check OK again for #{payload[:url]} after #{payload[:after]} s" },
    healthcheck_gave_up: ->(payload, _where, _instances) { "Health check still failing for #{payload[:url]} (#{payload[:reason]}), giving up" },
    healthchecks_done: ->(payload, where, _instances) { healthchecks_summary(payload, where) },
    deploy_succeeded: ->(_payload, where, instances) { "Deployed #{instances} to #{where}" },
    deploy_failed: ->(payload, where, instances) { "Deploying #{instances} to #{where} failed: #{payload[:error]}" },
    deploy_aborted: ->(payload, where, _instances) { "Deploy to #{where} stopped: #{payload[:reason]}" },
    deploy_interrupted: ->(_payload, where, instances) { "Deploy of #{instances} to #{where} interrupted" },
    lambda_published: ->(payload, where, _instances) { "Lambda #{payload[:function]} published for #{where}" },
    reset_disabling: ->(_payload, where, _instances) { "Disabling the standalone instances of #{where}" },
    reset_disabled: ->(_payload, where, _instances) { "Standalone instances of #{where} disabled" },
    reset_enabling: ->(_payload, where, _instances) { "Recreating the standalone instances of #{where}" },
    reset_done: ->(_payload, where, _instances) { "Standalone instances of #{where} recreated" }
  }.freeze
  public_constant :DEFAULT_EVENTS, :SETTINGS
  private_constant :HTTP_ATTEMPTS, :HTTP_OPEN_TIMEOUT, :HTTP_READ_TIMEOUT, :HTTP_RETRY_DELAY, :NETWORK_ERRORS, :SUMMARIES

  def self.settings_errors(_settings)
    []
  end

  attr_reader :settings, :options

  def initialize(settings, options)
    @settings = settings
    @options = options
  end

  def active?
    true
  end

  def handle(event, _payload)
    raise(NotImplementedError, "#{self.class} must handle #{event}")
  end

  def summary(event, payload)
    where = "#{payload[:profile]}/#{payload[:environment]}"
    sentence = SUMMARIES[event.to_sym]
    sentence ? instance_exec(payload, where, payload[:instances].to_a.join(', '), &sentence) : "#{event} for #{where}"
  end

  private

  def question_text(payload)
    case payload[:kind]
    when 'standalones_not_ready' then "#{payload[:names].join(', ')} not ready"
    when 'partial_ami_failure' then "AMI failed for #{payload[:failed].join(', ')}"
    when 'other_deploy' then 'someone else may be deploying'
    when 'permissions_unchecked' then 'permissions could not be checked'
    when 'extra_codedeploy_targets' then "#{payload[:group]} would also deploy to other instances"
    else payload[:kind].to_s
    end
  end

  def ami_list(payload)
    payload[:jobs].to_a.map { |job| "#{job[:instance]} #{job[:ami_id] || '-'} (#{job[:state]})" }
                  .join(', ')
  end

  def scaling_list(payload)
    payload[:groups].to_a.map { |group| "#{group[:name]} from #{group[:from]} to #{group[:to]}" }
                    .join(', ')
  end

  def healthchecks_summary(payload, where)
    return "All health checks succeeded for #{where}" if payload[:failed].empty?

    "Health checks failed for #{where}: #{payload[:failed].map { |failure| "#{failure[:url]} (#{failure[:reason]})" }
.join(', ')}"
  end

  def macos?
    RUBY_PLATFORM.include?('darwin')
  end

  def spawn_command(*command)
    Process.detach(Process.spawn(*command, %i[out err] => File::NULL))
  rescue SystemCallError => e
    warn("#{self.class}: could not run #{command.first}: #{e.message}")
    nil
  end

  def http_post(url, body, headers: {}, basic_auth: nil)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri, headers)
    body.is_a?(Hash) ? request.set_form_data(body) : request.body = body
    request.basic_auth(*basic_auth) if basic_auth

    with_http_retries(uri) do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT) { |http| http.request(request) }
    end
  end

  def with_http_retries(uri, &)
    error = nil

    HTTP_ATTEMPTS.times do |attempt|
      sleep(HTTP_RETRY_DELAY * (2**(attempt - 1))) if attempt.positive?
      response, error, retryable = http_attempt(uri, &)
      return response if response
      break unless retryable
    end

    raise(error)
  end

  def http_attempt(uri)
    response = yield
    return [response] if response.is_a?(Net::HTTPSuccess)

    [nil, "#{uri.host} answered HTTP #{response.code}", response.code == '429' || response.code.start_with?('5')]
  rescue *NETWORK_ERRORS => e
    [nil, "#{uri.host}: #{e.class}", true]
  end
end
