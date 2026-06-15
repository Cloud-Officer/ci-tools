# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
  minimum_coverage line: 80, branch: 80
end

require_relative '../brew-resources'
require_relative '../cycle-keys'
require_relative '../deploy'
require_relative '../encrypt-logs'
require_relative '../lib/cli_main'

# Captures everything written to $stdout while the block runs and returns it as
# a String, restoring $stdout even when the block raises (e.g. SystemExit).
def capture_stdout
  original = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original
end

# Runs the given block with $PROGRAM_NAME temporarily set to program_name,
# capturing and returning whatever it writes to $stdout. The block is expected
# to terminate via SystemExit (as --help handlers do), which is swallowed.
def help_output_with_program_name(program_name)
  original_program_name = $PROGRAM_NAME
  $PROGRAM_NAME = program_name

  capture_stdout do
    yield
  rescue SystemExit
    # --help prints the banner then exits; swallow it so we can assert on output
  end
ensure
  $PROGRAM_NAME = original_program_name
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |e| e.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand(config.seed)
end
