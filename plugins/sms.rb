# frozen_string_literal: true

module Plugins
  # Texts outcomes and pending questions through Twilio.
  class Sms < Plugin
    DEFAULT_EVENTS = %w[question healthcheck_gave_up deploy_succeeded deploy_failed deploy_aborted deploy_interrupted amis_ready lambda_published reset_done].freeze
    SETTINGS = %w[always account_sid auth_token from to].freeze
    MAX_LENGTH = 150
    TWILIO_URL = 'https://api.twilio.com/2010-04-01/Accounts/%<sid>s/Messages.json'
    OUTCOMES = { deploy_succeeded: 'DEPLOY OK', amis_ready: 'AMIS READY', deploy_interrupted: 'INTERRUPTED', reset_done: 'RESET DONE' }.freeze
    public_constant :DEFAULT_EVENTS, :SETTINGS
    private_constant :MAX_LENGTH, :TWILIO_URL, :OUTCOMES

    def self.settings_errors(settings)
      errors = []
      errors << 'account_sid must look like AC followed by 32 hex digits' unless settings['account_sid'].to_s.match?(/\AAC\h{32}\z/)
      errors << 'auth_token is missing' unless settings['auth_token'].is_a?(String) && !settings['auth_token'].empty?
      %w[from to].each { |key| errors << "#{key} must be an E.164 number" unless settings[key].to_s.match?(/\A\+\d{8,15}\z/) }
      errors << 'always must be true or false' unless [nil, true, false].include?(settings['always'])
      errors
    end

    def active?
      settings['always'] == true || options[:sms] == true
    end

    def handle(event, payload)
      sid = settings['account_sid']
      body = { From: settings['from'], To: settings['to'], Body: message(event, payload)[0, MAX_LENGTH] }.transform_keys(&:to_s)
      http_post(format(TWILIO_URL, sid: sid), body, basic_auth: [sid, settings['auth_token']])
    end

    def message(event, payload)
      environment = payload[:environment]
      instances = payload[:instances].to_a.join(',')
      outcome = OUTCOMES[event.to_sym]
      return "#{outcome} #{environment} #{instances}".strip if outcome

      case event
      when 'lambda_published' then "LAMBDA PUBLISHED #{environment} #{payload[:function]}"
      when 'deploy_aborted' then "STOPPED #{environment}: #{payload[:reason]}"
      when 'deploy_failed' then "FAILED #{environment} #{instances}: #{payload[:error]}"
      when 'question' then "ANSWER NEEDED #{environment}: #{payload[:kind]}"
      when 'healthcheck_gave_up' then "HEALTH CHECK FAILED #{environment} #{payload[:url]}: #{payload[:reason]}"
      else summary(event, payload)
      end
    end
  end
end
