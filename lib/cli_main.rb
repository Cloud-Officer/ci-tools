# frozen_string_literal: true

require 'optparse'

# Shared helpers used by the top-level scripts in this repo.
module CliMain
  # Wraps a CLI's main block: catches any uncaught StandardError, prints
  # the error + backtrace to STDERR, and exits 1. Use it instead of repeating
  # `rescue StandardError => e; warn(e); warn(e.backtrace); exit(1)` at the
  # bottom of every script.
  def self.run!
    yield
  rescue StandardError => e
    warn(e)
    warn(e.backtrace)
    exit(1)
  end

  # Builds an OptionParser, hands it to the caller's block for script-specific
  # opts.on calls, parses argv, then enforces a mandatory-keys check. Returns
  # the parsed options hash.
  def self.parse_options!(banner:, mandatory:, argv: ARGV)
    options = {}

    OptionParser.new do |opts|
      opts.banner = banner
      opts.separator('')
      opts.separator('options')
      yield(opts)
    end.parse!(argv, into: options)

    missing = mandatory.select { |param| options[param].nil? }
    raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

    options
  end
end
