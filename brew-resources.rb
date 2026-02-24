#!/usr/bin/env ruby

# frozen_string_literal: true

require 'bundler'
require 'digest'
require 'httparty'

def format_resource(spec, sha256)
  lines = []

  if spec.platform == 'ruby'
    lines << "  resource '#{spec.name}' do"
    lines << "    url 'https://rubygems.org/gems/#{spec.full_name}.gem'"
    lines << "    sha256 '#{sha256}'"
  else
    os =
      case spec.platform.os
      when /darwin/
        'on_macos'
      else
        'on_linux'
      end

    cpu =
      if spec.platform.cpu == 'x86_64'
        'on_intel'
      else
        'on_arm'
      end

    lines << "  #{os} do"
    lines << "    #{cpu} do"
    lines << "      resource '#{spec.name}' do"
    lines << "        url 'https://rubygems.org/gems/#{spec.full_name}.gem'"
    lines << "        sha256 '#{sha256}'"
    lines << '      end'
    lines << '    end'
  end

  lines << '  end'
  lines << ''
  lines
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    lock_file = Bundler::LockfileParser.new(Bundler.read_file('Gemfile.lock'))

    lock_file.specs.each do |spec|
      response = HTTParty.get("https://rubygems.org/gems/#{spec.full_name}.gem")

      raise(response.message) unless response.code == 200

      sha256 = Digest::SHA256.hexdigest(response.body)
      format_resource(spec, sha256).each { |line| puts(line) }
    end
  rescue StandardError => e
    puts(e)
    puts(e.backtrace)
    exit(1)
  end
end
# :nocov:
