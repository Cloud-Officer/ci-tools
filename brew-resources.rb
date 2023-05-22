#!/usr/bin/env ruby

# frozen_string_literal: true

require 'bundler'
require 'digest'
require 'httparty'

begin
  lock_file = Bundler::LockfileParser.new(Bundler.read_file('Gemfile.lock'))

  lock_file.specs.each do |spec|
    response = HTTParty.get("https://rubygems.org/gems/#{spec.name}-#{spec.version}.gem")

    raise(response.message) unless response.code == 200

    if spec.name.include?('cocoapods')
      puts('  if OS.mac?')
      puts("    resource '#{spec.name}' do")
      puts("      url 'https://rubygems.org/gems/#{spec.name}-#{spec.version}.gem'")
      puts("      sha256 '#{Digest::SHA256.hexdigest(response.body)}'")
      puts('    end')
    else
      puts("  resource '#{spec.name}' do")
      puts("    url 'https://rubygems.org/gems/#{spec.name}-#{spec.version}.gem'")
      puts("    sha256 '#{Digest::SHA256.hexdigest(response.body)}'")
    end

    puts('  end')
    puts('')
  end
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
