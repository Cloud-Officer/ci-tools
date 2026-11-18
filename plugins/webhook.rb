# frozen_string_literal: true

module Plugins
  # Posts deploy events to a URL.
  class Webhook < Plugin
    SETTINGS = %w[url format headers].freeze
    FORMATS = %w[json slack].freeze
    public_constant :SETTINGS
    private_constant :FORMATS

    def self.settings_errors(settings)
      errors = []
      errors << 'url must be an http(s) URL' unless settings['url'].to_s.match?(%r{\Ahttps?://\S+\z})
      errors << "format must be one of: #{FORMATS.join(', ')}" unless settings['format'].nil? || FORMATS.include?(settings['format'])
      errors << 'headers must map names to values' unless valid_headers?(settings['headers'])
      errors
    end

    def self.valid_headers?(headers)
      return true if headers.nil?

      headers.is_a?(Hash) && headers.values.none?(Enumerable)
    end

    def handle(event, payload)
      body = settings['format'] == 'slack' ? { text: "*deploy* #{summary(event, payload)}" } : { event: event, **payload }
      headers = (settings['headers'] || {}).to_h { |name, value| [name.to_s, value.to_s] }
      http_post(settings['url'], JSON.generate(body), headers: { 'Content-Type': 'application/json' }.transform_keys(&:to_s).merge(headers))
    end
  end
end
