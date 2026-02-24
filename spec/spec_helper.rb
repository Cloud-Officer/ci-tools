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

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |e| e.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand(config.seed)
end
