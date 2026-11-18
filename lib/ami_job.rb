# frozen_string_literal: true

# Thread-safe progress of one AMI build.
class AmiJob
  attr_reader :instance

  def initialize(instance, name)
    @instance = instance
    @mutex = Mutex.new
    @started = Time.now
    @fields = { state: 'starting', ami_id: nil, progress: nil, name: name, error: nil, finished: nil }
  end

  def update(**fields)
    @mutex.synchronize { @fields.merge!(fields) }
  end

  def snapshot
    @mutex.synchronize { @fields.dup }
  end

  def finish(ami_id)
    update(state: 'available', ami_id: ami_id, progress: '100%', finished: Time.now)
  end

  def mark_failed(message)
    update(state: 'failed', error: message, finished: Time.now)
  end

  def available?
    snapshot[:state] == 'available'
  end

  def pending?
    fields = snapshot
    !fields[:ami_id].nil? && !%w[available failed].include?(fields[:state])
  end

  def elapsed
    seconds = ((snapshot[:finished] || Time.now) - @started).floor
    format('%<minutes>02d:%<seconds>02d', minutes: seconds / 60, seconds: seconds % 60)
  end
end
