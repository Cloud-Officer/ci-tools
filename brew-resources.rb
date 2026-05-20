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

def fetch_gem_sha256(spec)
  url = "https://rubygems.org/gems/#{spec.full_name}.gem"
  response = HTTParty.get(url)
  raise("rubygems.org returned HTTP #{response.code} for #{url}: #{response.message} — #{response.body.to_s[0, 200]}") unless response.code == 200

  Digest::SHA256.hexdigest(response.body)
end

def run_brew_resources(lockfile_path = 'Gemfile.lock')
  lock_file = Bundler::LockfileParser.new(Bundler.read_file(lockfile_path))

  lock_file.specs.each do |spec|
    sha256 = fetch_gem_sha256(spec)
    format_resource(spec, sha256).each { |line| puts(line) }
  end
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  begin
    run_brew_resources
  rescue StandardError => e
    warn(e)
    warn(e.backtrace)
    exit(1)
  end
end
# :nocov:
