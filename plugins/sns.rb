# frozen_string_literal: true

require 'aws-sdk-sns'

module Plugins
  # Publishes failures to an SNS topic, such as the notifications topic of the environment.
  class Sns < Plugin
    DEFAULT_EVENTS = %w[deploy_failed deploy_aborted deploy_interrupted healthcheck_gave_up rollback_failed].freeze
    SETTINGS = %w[topic_arn].freeze
    TOPIC_ARN = /\Aarn:aws[a-z-]*:sns:[a-z0-9-]+:\d{12}:[\w-]{1,256}\z/
    SUBJECT_LENGTH = 100
    public_constant :DEFAULT_EVENTS, :SETTINGS
    private_constant :TOPIC_ARN, :SUBJECT_LENGTH

    def self.settings_errors(settings)
      settings['topic_arn'].to_s.match?(TOPIC_ARN) ? [] : ['topic_arn must be an SNS topic ARN']
    end

    def handle(event, payload)
      client.publish({ topic_arn: settings['topic_arn'], subject: subject(event, payload), message: JSON.pretty_generate({ summary: summary(event, payload), event: event, **payload }) })
    end

    def subject(event, payload)
      "deploy.rb #{event} #{payload[:profile]}/#{payload[:environment]}".gsub(/[^ -~]/, '?')[0, SUBJECT_LENGTH]
    end

    private

    def client
      @client ||= Aws::SNS::Client.new(region: settings['topic_arn'].split(':')[3])
    end
  end
end
