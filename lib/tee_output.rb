# frozen_string_literal: true

require 'stringio'

# Sends $stdout or $stderr to the terminal and to the run log.
class TeeOutput
  ESCAPE_CODES = /\e\[[0-9;]*[A-Za-z]/
  public_constant :ESCAPE_CODES

  attr_reader :console

  def initialize(console, log)
    @console = console
    @log = log
  end

  def write(*parts)
    @log.write(parts.join)
    @console.write(*parts)
  end

  def puts(*lines)
    buffer = StringIO.new
    buffer.puts(*lines)
    write(buffer.string)
    nil
  end

  def print(*parts)
    write(parts.join)
    nil
  end

  def <<(text)
    write(text.to_s)
    self
  end

  def flush
    @console.flush
    self
  end

  def tty?
    @console.tty?
  end
  alias isatty tty?

  def fileno
    @console.fileno
  end
end
