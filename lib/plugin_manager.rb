# frozen_string_literal: true

require 'time'
require 'yaml'
require_relative 'plugin'

# Loads the enabled plugins and gives each one its events on its own thread.
class PluginManager
  GRACE_PERIOD = 10
  PLUGIN_ERRORS = [StandardError, ScriptError, SystemExit].freeze

  Runner = Struct.new(:name, :plugin, :events, :queue, :thread)
  private_constant :GRACE_PERIOD, :PLUGIN_ERRORS, :Runner

  def self.load(path, options, context, thread_starter)
    disabled = Array(options[:'disable-plugins'])
    return new([], context, thread_starter) if disabled.include?('all')

    plugins = read_settings(path).filter_map { |name, settings| build(name, settings, options) unless disabled.include?(name) }
    warn('WARNING: --sms was given but the sms plugin is not active: no texts will be sent.') if options[:sms] && plugins.none? { |name, *| name == 'sms' }
    new(plugins, context, thread_starter)
  end

  def self.read_settings(path)
    return {} unless File.exist?(path)

    unless private_file?(path)
      warn("WARNING: #{path} can hold secrets and must be yours with no access for others: every plugin is off until you fix it (chmod 600).")
      return {}
    end

    data = YAML.safe_load_file(path) || {}
    return data if data.is_a?(Hash)

    warn("WARNING: #{path} must map plugin names to settings: every plugin is off.")
    {}
  rescue Psych::Exception, SystemCallError => e
    warn("WARNING: #{path} cannot be read, every plugin is off: #{e.class}")
    {}
  end

  def self.private_file?(path)
    stat = File.stat(path)
    stat.owned? && !stat.mode.anybits?(0o077)
  end

  def self.settings_errors(klass, settings)
    errors = (settings.keys - Plugins::COMMON_SETTINGS - klass::SETTINGS).map { |key| "unknown key '#{key}'" }
    errors << "events must be a list of: #{Plugins::EVENTS.join(', ')}" unless valid_events?(settings['events'])
    errors + klass.settings_errors(settings)
  end

  def self.valid_events?(events)
    return true if events.nil?

    events.is_a?(Array) && (events - Plugins::EVENTS).empty?
  end

  def self.build(name, settings, options)
    return unless settings.is_a?(Hash) && settings['enabled']
    return warn("WARNING: unknown plugin '#{name}' (available: #{Plugins.available.join(', ')})") unless Plugins.available.include?(name)

    require(File.join(Plugins::DIRECTORY, name))
    klass = Plugins.const_get(Plugins.class_name(name))
    errors = settings_errors(klass, settings)
    return warn("WARNING: plugin #{name} is off: #{errors.join('; ')}") unless errors.empty?

    plugin = klass.new(settings, options)
    [name, plugin, settings['events'] || klass::DEFAULT_EVENTS] if plugin.active?
  rescue *PLUGIN_ERRORS => e
    warn("WARNING: plugin #{name} is off, it failed to load: #{e.class}: #{e.message}")
  end

  def initialize(plugins, context, thread_starter)
    @context = context
    @thread_starter = thread_starter
    @runners = plugins.map { |name, plugin, events| start(name, plugin, events) }
  end

  def names
    @runners.map(&:name)
  end

  def emit(event, payload = {})
    name = event.to_s
    data = @context.merge(payload, time: Time.now.utc.iso8601)
    @runners.each { |runner| runner.queue << [name, data] if runner.events.include?(name) }
  end

  def shutdown(grace = GRACE_PERIOD)
    @runners.each { |runner| runner.queue.close }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace

    @runners.each do |runner|
      left = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      warn("WARNING: plugin #{runner.name} is still busy, not waiting for it.") unless runner.thread.join(left)
    end
  end

  private

  def start(name, plugin, events)
    queue = Thread::Queue.new
    Runner.new(name, plugin, events, queue, @thread_starter.call { run(name, plugin, queue) })
  end

  def run(name, plugin, queue)
    while (item = queue.pop)
      event, payload = item

      begin
        plugin.handle(event, payload)
      rescue *PLUGIN_ERRORS => e
        warn("WARNING: plugin #{name} failed on #{event}: #{e.class}: #{e.message}")
      end
    end
  end
end
