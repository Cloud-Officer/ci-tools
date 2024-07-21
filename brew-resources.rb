#!/usr/bin/env ruby

# frozen_string_literal: true

require 'bundler'
require 'digest'
require 'httparty'

begin
  lock_file = Bundler::LockfileParser.new(Bundler.read_file('Gemfile.lock'))

  lock_file.specs.each do |spec|
    response = HTTParty.get("https://rubygems.org/gems/#{spec.full_name}.gem")

    raise(response.message) unless response.code == 200

    if spec.platform == 'ruby'
      puts("  resource '#{spec.name}' do")
      puts("    url 'https://rubygems.org/gems/#{spec.full_name}.gem'")
      puts("    sha256 '#{Digest::SHA256.hexdigest(response.body)}'")
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

      puts("  #{os} do")
      puts("    #{cpu} do")
      puts("      resource '#{spec.name}' do")
      puts("        url 'https://rubygems.org/gems/#{spec.full_name}.gem'")
      puts("        sha256 '#{Digest::SHA256.hexdigest(response.body)}'")
      puts('      end')
      puts('    end')
    end

    puts('  end')
    puts('')
  end
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
