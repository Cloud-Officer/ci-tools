# frozen_string_literal: true

require 'tmpdir'
require 'webmock/rspec'

module BrewResources
  # Methods defined in brew-resources.rb
end

RSpec.describe(BrewResources) do
  describe '#fetch_gem_sha256' do
    let(:spec)         { instance_double(Gem::Specification, full_name: 'nokogiri-1.15.2') }
    let(:gem_url)      { 'https://rubygems.org/gems/nokogiri-1.15.2.gem'                   }
    let(:gem_bytes)    { "fake gem bytes\n"                                                }
    let(:expected_sha) { Digest::SHA256.hexdigest(gem_bytes)                               }

    context 'with a 200 response' do
      before { stub_request(:get, gem_url).to_return(status: 200, body: gem_bytes) }

      it 'returns the sha256 of the response body' do
        expect(fetch_gem_sha256(spec)).to(eq(expected_sha))
      end
    end

    context 'with a 500 response' do
      before { stub_request(:get, gem_url).to_return(status: 500, body: 'service unavailable') }

      it 'raises with the status code, URL, and body excerpt' do
        expect { fetch_gem_sha256(spec) }
          .to(raise_error(RuntimeError, /500.*#{Regexp.escape(gem_url)}.*service unavailable/))
      end
    end

    context 'with a 404 response' do
      before { stub_request(:get, gem_url).to_return(status: 404, body: '<html>Not Found</html>') }

      it 'raises with the status code' do
        expect { fetch_gem_sha256(spec) }
          .to(raise_error(RuntimeError, /HTTP 404/))
      end
    end
  end

  describe '#run_brew_resources' do
    # Both paths were relative to the process working directory: the fixture was
    # written into the repository itself and the teardown then `rm -rf`'d
    # 'spec/fixtures' from wherever rspec happened to be running. Dir.mktmpdir
    # keeps the fixture out of the working tree and removes it for us, so nothing
    # deletes a relative path it does not own.
    let(:fixture_dir)   { Dir.mktmpdir                           }
    let(:lockfile_path) { File.join(fixture_dir, 'Gemfile.lock') }
    let(:gemfile_path)  { File.join(fixture_dir, 'Gemfile')      }

    after { FileUtils.remove_entry(fixture_dir) }

    before do
      File.write(gemfile_path, <<~GEMFILE)
        source 'https://rubygems.org'

        gem 'example'

        group :development do
          gem 'devonly'
        end

        group :test do
          gem 'testonly'
        end
      GEMFILE

      File.write(lockfile_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            devonly (4.5.6)
            example (1.2.3)
            testonly (7.8.9)

        PLATFORMS
          ruby

        DEPENDENCIES
          devonly
          example
          testonly

        BUNDLED WITH
           2.5.0
      LOCK
      allow(self).to(receive(:fetch_gem_sha256).and_return('deadbeef' * 8))
    end

    it 'prints a Homebrew resource block for a default-group gem' do
      expect { run_brew_resources(lockfile_path) }
        .to(output(/resource 'example' do/).to_stdout)
    end

    it 'omits development-group gems' do
      expect { run_brew_resources(lockfile_path) }
        .not_to(output(/resource 'devonly' do/).to_stdout)
    end

    it 'omits test-group gems' do
      expect { run_brew_resources(lockfile_path) }
        .not_to(output(/resource 'testonly' do/).to_stdout)
    end

    it 'never emits bundler, which ships with Ruby' do
      expect { run_brew_resources(lockfile_path) }
        .not_to(output(/resource 'bundler' do/).to_stdout)
    end

    it 'raises a clear error when the Gemfile is missing' do
      FileUtils.rm_f(gemfile_path)
      expect { run_brew_resources(lockfile_path) }
        .to(raise_error(RuntimeError, /needs the Gemfile/))
    end

    it 'writes no fixture into the repository working tree' do
      run_brew_resources(lockfile_path)
      expect(Dir.exist?(File.join(__dir__, 'fixtures'))).to(be(false))
    end
  end

  describe '#format_resource' do
    context 'with ruby platform' do
      let(:spec)   { instance_double(Gem::Specification, name: 'nokogiri', full_name: 'nokogiri-1.15.2', platform: 'ruby') }
      let(:sha256) { 'abc123def456'                                                                                        }
      let(:lines)  { format_resource(spec, sha256)                                                                         }

      it 'returns resource block lines', :aggregate_failures do
        expect(lines).to(include("  resource 'nokogiri' do"))
        expect(lines).to(include("    url 'https://rubygems.org/gems/nokogiri-1.15.2.gem'"))
        expect(lines).to(include("    sha256 'abc123def456'"))
        expect(lines).to(include('  end'))
      end

      it 'does not include platform-specific wrapping', :aggregate_failures do
        expect(lines.join("\n")).not_to(include('on_macos'))
        expect(lines.join("\n")).not_to(include('on_linux'))
      end

      it 'ends with an empty string for spacing' do
        expect(lines.last).to(eq(''))
      end
    end

    context 'with darwin arm64 platform' do
      let(:platform) { instance_double(Gem::Platform, os: 'darwin', cpu: 'arm64') }
      let(:spec)   { instance_double(Gem::Specification, name: 'nokogiri', full_name: 'nokogiri-1.15.2-arm64-darwin', platform: platform) }
      let(:sha256) { 'xyz789'                                                                                                             }
      let(:lines)  { format_resource(spec, sha256)                                                                                        }

      it 'wraps in on_macos and on_arm blocks', :aggregate_failures do
        expect(lines).to(include('  on_macos do', '    on_arm do'))
        expect(lines).to(include("      resource 'nokogiri' do"))
        expect(lines).to(include("        url 'https://rubygems.org/gems/nokogiri-1.15.2-arm64-darwin.gem'"))
        expect(lines).to(include("        sha256 'xyz789'", '      end', '    end', '  end'))
      end
    end

    context 'with darwin x86_64 platform' do
      let(:platform) { instance_double(Gem::Platform, os: 'darwin', cpu: 'x86_64') }
      let(:spec)   { instance_double(Gem::Specification, name: 'nokogiri', full_name: 'nokogiri-1.15.2-x86_64-darwin', platform: platform) }
      let(:sha256) { 'intel123'                                                                                                            }
      let(:lines)  { format_resource(spec, sha256)                                                                                         }

      it 'wraps in on_macos and on_intel blocks', :aggregate_failures do
        expect(lines).to(include('  on_macos do', '    on_intel do'))
        expect(lines).to(include("      resource 'nokogiri' do"))
      end
    end

    context 'with linux platform' do
      let(:platform) { instance_double(Gem::Platform, os: 'linux', cpu: 'x86_64') }
      let(:spec)   { instance_double(Gem::Specification, name: 'nokogiri', full_name: 'nokogiri-1.15.2-x86_64-linux', platform: platform) }
      let(:sha256) { 'linux123'                                                                                                           }
      let(:lines)  { format_resource(spec, sha256)                                                                                        }

      it 'wraps in on_linux and on_intel blocks', :aggregate_failures do
        expect(lines).to(include('  on_linux do', '    on_intel do'))
      end
    end

    context 'with linux arm64 platform' do
      let(:platform) { instance_double(Gem::Platform, os: 'linux', cpu: 'aarch64') }
      let(:spec)   { instance_double(Gem::Specification, name: 'nokogiri', full_name: 'nokogiri-1.15.2-aarch64-linux', platform: platform) }
      let(:sha256) { 'linuxarm123'                                                                                                         }
      let(:lines)  { format_resource(spec, sha256)                                                                                         }

      it 'wraps in on_linux and on_arm blocks', :aggregate_failures do
        expect(lines).to(include('  on_linux do', '    on_arm do'))
      end
    end
  end
end
