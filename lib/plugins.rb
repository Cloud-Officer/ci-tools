# frozen_string_literal: true

# Notification plugins: plugins/<name>.rb defines Plugins::<Name> and loads only when enabled in plugins.yaml.
module Plugins
  DIRECTORY = File.expand_path('../plugins', __dir__)
  EVENTS = %w[
    deploy_started
    question
    amis_done
    amis_ready
    stack_updated
    rollout_started
    rollout_done
    healthcheck_failing
    healthcheck_recovered
    healthcheck_gave_up
    healthchecks_done
    rollback_started
    rollback_done
    rollback_failed
    deploy_succeeded
    deploy_failed
    deploy_aborted
    deploy_interrupted
    lambda_published
    reset_disabling
    reset_disabled
    reset_enabling
    reset_done
  ].freeze
  COMMON_SETTINGS = %w[enabled events].freeze
  public_constant :DIRECTORY, :EVENTS, :COMMON_SETTINGS

  def self.available
    names = Dir.glob(File.join(DIRECTORY, '*.rb')).map { |file| File.basename(file, '.rb') }
    names.sort!
    names
  end

  def self.class_name(name)
    name.split('_').map(&:capitalize).join
  end
end
