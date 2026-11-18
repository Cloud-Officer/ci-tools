# frozen_string_literal: true

module Plugins
  # Speaks deploy events with macOS say, one message at a time.
  class Voice < Plugin
    DEFAULT_EVENTS = %w[amis_done stack_updated healthcheck_failing healthcheck_gave_up healthchecks_done reset_disabled reset_done].freeze
    SETTINGS = %w[voice].freeze
    public_constant :DEFAULT_EVENTS, :SETTINGS

    def self.settings_errors(settings)
      voice = settings['voice']
      voice.nil? || (voice.is_a?(String) && !voice.empty?) ? [] : ['voice must be a say voice name']
    end

    def active?
      macos?
    end

    def handle(event, payload)
      @speaking&.join
      voice = settings['voice'] ? ['-v', settings['voice']] : []
      @speaking = spawn_command('say', *voice, spoken(event, payload))
    end

    def spoken(event, payload)
      environment = payload[:environment]

      case event
      when 'amis_done' then spoken_amis(payload)
      when 'stack_updated' then "CloudFormation finished for #{environment}"
      when 'healthchecks_done' then spoken_healthchecks(payload)
      when 'healthcheck_failing' then "Health check failing for #{service(payload[:url])} on #{environment}, retrying"
      when 'healthcheck_recovered' then "#{service(payload[:url])} is healthy on #{environment}"
      when 'healthcheck_gave_up' then "Giving up on the #{service(payload[:url])} health check on #{environment}"
      else summary(event, payload)
      end
    end

    private

    def spoken_amis(payload)
      failed = payload[:jobs].select { |job| job[:state] == 'failed' }
      names = failed.map { |job| job[:instance] }
      "Images complete for #{payload[:profile]} #{payload[:environment]}#{", #{spoken_list(names)} failed" unless names.empty?}"
    end

    def spoken_healthchecks(payload)
      return "All health checks succeeded for #{payload[:environment]}" if payload[:failed].empty?

      services = payload[:failed].map { |failure| service(failure[:url]) }
      services.uniq!
      "Health checks failed for #{spoken_list(services)} on #{payload[:environment]}"
    end

    def service(url)
      URI(url).host.split('.').first.sub(/-.*/, '')
    end

    def spoken_list(items)
      items.size < 2 ? items.join : "#{items[0..-2].join(', ')} and #{items.last}"
    end
  end
end
