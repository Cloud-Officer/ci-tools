# frozen_string_literal: true

require_relative '../lib/cli_main'

RSpec.describe(CliMain) do
  describe '.run!' do
    it 'yields and returns the block result on success' do
      expect(described_class.run! { 42 }).to(eq(42))
    end

    it 'catches StandardError, writes to STDERR, and exits 1', :aggregate_failures do
      expect do
        expect { described_class.run! { raise(StandardError, 'boom') } }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
      end.to(output(/boom/).to_stderr)
    end

    def raise_with_cause
      raise(StandardError, 'inner')
    rescue StandardError
      raise(StandardError, 'outer')
    end

    it 'walks the cause chain and prints both messages via full_message', :aggregate_failures do
      expect do
        expect { described_class.run! { raise_with_cause } }
          .to(raise_error(SystemExit))
      end.to(output(/outer.*inner/m).to_stderr)
    end

    it 'does not catch SystemExit or other non-StandardError errors', :aggregate_failures do
      expect { described_class.run! { raise(SystemExit, 0) } }
        .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(0)) })
    end
  end

  describe '.parse_options!' do
    it 'returns the parsed options hash' do
      result =
        described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: %w[--name foo]) do |opts|
          opts.on('--name name', String)
        end
      expect(result).to(eq(name: 'foo'))
    end

    def expect_usage_error(argv, message)
      expect do
        expect { parse_with_help_banner(argv) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(1)) })
      end.to(output(/#{message}.*Usage: x.*--name/m).to_stderr)
    end

    def parse_with_help_banner(argv)
      described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: argv) do |opts|
        opts.on('--name name', String)
      end
    end

    it 'prints the error and usage to stderr and exits 1 when a mandatory key is absent' do
      expect_usage_error([], 'missing argument: name')
    end

    it 'prints the error and usage to stderr and exits 1 for an unknown option' do
      expect_usage_error(%w[--bogus], 'invalid option: --bogus')
    end

    it 'prints the error and usage to stderr and exits 1 when an option value is missing' do
      expect_usage_error(%w[--name], 'missing argument: --name')
    end

    it 'does not print a backtrace for a usage error', :aggregate_failures do
      expect do
        expect { parse_with_help_banner([]) }
          .to(raise_error(SystemExit))
      end.not_to(output(/cli_main\.rb:\d+/).to_stderr)
    end

    it 'mutates the supplied argv (parse! contract)' do
      argv = %w[--name foo unconsumed]
      described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: argv) do |opts|
        opts.on('--name name', String)
      end
      expect(argv).to(eq(%w[unconsumed]))
    end

    def expect_help_exit(flag)
      expect { parse_with_help(flag) }
        .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(0)) })
    end

    def parse_with_help(flag)
      described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: [flag]) do |opts|
        opts.on('--name name', String)
      end
    end

    %w[-h --help].each do |flag|
      it "prints usage and exits 0 for #{flag}", :aggregate_failures do
        expect do
          expect_help_exit(flag)
        end.to(output(/Usage: x/).to_stdout)
      end
    end

    def parse_with_default_banner(argv)
      described_class.parse_options!(mandatory: %i[name], argv: argv) do |opts|
        opts.on('--name name', String)
      end
    end

    it 'defaults the banner to the invoked command name', :aggregate_failures do
      output = help_output_with_program_name('/usr/local/bin/deploy') { parse_with_default_banner(%w[--help]) }
      expect(output).to(include('Usage: deploy options'))
      expect(output).not_to(include('deploy.rb'))
    end

    it 'follows the program name of a symlink without the .rb suffix' do
      output = help_output_with_program_name('/usr/local/bin/cycle-keys') { parse_with_default_banner(%w[--help]) }
      expect(output).to(include('Usage: cycle-keys options'))
    end

    def parse_with_banner_override(argv)
      described_class.parse_options!(banner: 'Usage: custom banner', mandatory: %i[name], argv: argv) do |opts|
        opts.on('--name name', String)
      end
    end

    it 'still honours an explicit banner override' do
      output = help_output_with_program_name('/usr/local/bin/deploy') { parse_with_banner_override(%w[--help]) }
      expect(output).to(include('Usage: custom banner'))
    end

    it 'parses normally when the banner is omitted' do
      expect(parse_with_default_banner(%w[--name foo])).to(eq(name: 'foo'))
    end
  end

  describe '.default_banner' do
    it 'renders the basename of the running program' do
      original = $PROGRAM_NAME
      $PROGRAM_NAME = '/opt/ci-tools/encrypt-logs.rb'
      expect(described_class.default_banner).to(eq('Usage: encrypt-logs.rb options'))
    ensure
      $PROGRAM_NAME = original
    end
  end
end
