# frozen_string_literal: true

module Plugins
  # Shows macOS alerts and notifications.
  class MacosNotification < Plugin
    DEFAULT_EVENTS = %w[amis_done healthcheck_failing healthcheck_gave_up healthchecks_done].freeze
    public_constant :DEFAULT_EVENTS

    def active?
      macos?
    end

    def handle(event, payload)
      where = "#{payload[:profile]}/#{payload[:environment]}"

      case event
      when 'amis_done' then alert(
        "AMIs done for #{where}",
        payload[:jobs].map { |job| "#{job[:instance]}: #{job[:ami_id] || '-'} (#{job[:state]})" }
        .join("\n")
      )
      when 'healthchecks_done' then report_failed_checks(where, payload[:failed])
      else notification("deploy #{where}", summary(event, payload))
      end
    end

    private

    def report_failed_checks(where, failed)
      return if failed.empty?

      notification(
        "Health check failed: #{where}",
        failed.map { |failure| failure[:url] }
        .join(', ')
      )
    end

    def alert(title, text)
      spawn_command('osascript', '-e', "display alert #{quote(title)} message #{quote(text)}")
    end

    def notification(title, text)
      spawn_command('osascript', '-e', "display notification #{quote(text)} with title #{quote(title)}")
    end

    def quote(text)
      %("#{text.gsub(/[\\"]/) { |char| "\\#{char}" }}")
    end
  end
end
