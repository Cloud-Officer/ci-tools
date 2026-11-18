# frozen_string_literal: true

require 'fileutils'
require_relative 'tee_output'

# The run's log file, readable only by its owner.
class RunLog
  TIMED_LINE = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d /
  private_constant :TIMED_LINE

  attr_reader :path

  def initialize(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    @path = path
    @file = File.open(path, File::WRONLY | File::APPEND | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
    @file.sync = true
    @mutex = Mutex.new
    @line_start = true
  end

  def write(text)
    @mutex.synchronize do
      next if @file.nil?

      begin
        @file.write(stamp(text.gsub(TeeOutput::ESCAPE_CODES, '')))
      rescue IOError, SystemCallError => e
        @file = nil
        report_failure(e)
      end
    end
  end

  def close
    @mutex.synchronize do
      @file&.close
      @file = nil
    end
  end

  private

  def report_failure(error)
    output = $stderr.respond_to?(:console) ? $stderr.console : $stderr
    output.write("WARNING: run log #{@path} turned off: #{error.message}\n")
  end

  def stamp(text)
    time = Time.now.strftime('%Y-%m-%d %H:%M:%S ')
    stamped =
      text.each_line.map do |line|
        prefixed = @line_start && !line.match?(TIMED_LINE) ? time + line : line
        @line_start = line.end_with?("\n")
        prefixed
      end
    stamped.join
  end
end
