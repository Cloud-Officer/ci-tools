# frozen_string_literal: true

module BrewResources
  # Methods defined in brew-resources.rb
end

RSpec.describe(BrewResources) do
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
