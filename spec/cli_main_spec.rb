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

    it 'raises MissingArgument when a mandatory key is absent' do
      expect do
        described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: []) do |opts|
          opts.on('--name name', String)
        end
      end.to(raise_error(OptionParser::MissingArgument, /name/))
    end

    it 'mutates the supplied argv (parse! contract)' do
      argv = %w[--name foo unconsumed]
      described_class.parse_options!(banner: 'Usage: x', mandatory: %i[name], argv: argv) do |opts|
        opts.on('--name name', String)
      end
      expect(argv).to(eq(%w[unconsumed]))
    end
  end
end
