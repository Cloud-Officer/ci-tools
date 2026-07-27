# frozen_string_literal: true

require 'optparse'

# Shared helpers used by the top-level scripts in this repo.
module CliMain
  # Wraps a CLI's main block: catches any uncaught StandardError, prints
  # the error + backtrace to STDERR, and exits 1. Use it instead of repeating
  # `rescue StandardError => e; warn(e); warn(e.full_message); exit(1)` at the
  # bottom of every script.
  def self.run!
    yield
  rescue StandardError => e
    # full_message renders one frame per line AND walks the cause chain,
    # unlike warn(e.backtrace) which inspect-joins the array onto one line
    # and drops e.cause entirely.
    warn(e.full_message)
    exit(1)
  end

  # Usage banner derived from the name the CLI was actually invoked as. The
  # Dockerfile symlinks the scripts into /usr/local/bin without their .rb
  # suffix, so a hardcoded banner would name a command that does not exist on
  # PATH; $PROGRAM_NAME follows the invoked symlink and stays correct in every
  # install mode.
  def self.default_banner
    "Usage: #{File.basename($PROGRAM_NAME)} options"
  end

  # Builds an OptionParser, hands it to the caller's block for script-specific
  # opts.on calls, parses argv, then enforces a mandatory-keys check. Returns
  # the parsed options hash. Scripts should omit banner: and take the dynamic
  # default; pass one only for a CLI whose usage line is not "<command> options".
  def self.parse_options!(mandatory:, argv: ARGV, banner: default_banner)
    options = {}

    OptionParser.new do |opts|
      opts.banner = banner
      opts.separator('')
      opts.separator('options')
      yield(opts)
      # Provide a uniform -h/--help handler for every CLI so they all print
      # usage and exit 0 (an explicitly requested help is a success, not an
      # error). Tools must not redefine -h/--help themselves.
      opts.on('-h', '--help', 'Print this help message') do
        puts(opts)
        exit(0)
      end
    end.parse!(argv, into: options)

    missing = mandatory.select { |param| options[param].nil? }
    raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

    options
  end
end
