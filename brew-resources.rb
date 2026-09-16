#!/usr/bin/env ruby

# frozen_string_literal: true

require 'bundler'
require 'digest'
require 'httparty'
require_relative 'lib/cli_main'

def fetch_gem_sha256(spec)
  url = "https://rubygems.org/gems/#{spec.full_name}.gem"
  response = HTTParty.get(url)
  raise("rubygems.org returned HTTP #{response.code} for #{url}: #{response.message} — #{response.body.to_s[0, 200]}") unless response.code == 200

  Digest::SHA256.hexdigest(response.body)
end

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

def default_group_dependencies(gemfile_path, lockfile_path)
  Bundler::Definition
    .build(gemfile_path, lockfile_path, false)
    .dependencies
    .filter_map { |dependency| dependency.name if dependency.groups.include?(:default) }
end

def runtime_specs(lockfile_path)
  gemfile_path = File.join(File.dirname(lockfile_path), 'Gemfile')

  raise("#{gemfile_path} not found: resolving the runtime closure needs the Gemfile, not just the lockfile") unless File.exist?(gemfile_path)

  specs_by_name = Bundler::LockfileParser.new(Bundler.read_file(lockfile_path)).specs.group_by(&:name)
  queue = default_group_dependencies(gemfile_path, lockfile_path)
  reached = {}

  until queue.empty?
    name = queue.shift
    next if reached.key?(name) || !specs_by_name.key?(name)

    reached[name] = specs_by_name[name]
    specs_by_name[name].each { |spec| queue.concat(spec.dependencies.map(&:name)) }
  end

  # bundler appears in the lockfile graph but ships with Ruby, so it is never vendored.
  reached.except('bundler').values.flatten
end

def run_brew_resources(lockfile_path = 'Gemfile.lock')
  runtime_specs(lockfile_path).each do |spec|
    sha256 = fetch_gem_sha256(spec)
    format_resource(spec, sha256).each { |line| puts(line) }
  end
end

# :nocov:
if __FILE__ == $PROGRAM_NAME
  CliMain.run! do
    run_brew_resources
  end
end
# :nocov:
