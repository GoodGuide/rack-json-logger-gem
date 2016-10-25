require_relative './spec_helper'
require 'rack_json_logger'

class RackJsonLogger
  describe 'under multi-threaded operation' do
    before do
      $stdout, $stderr = RackJsonLogger.output_proxies
    end

    after do
      $stdout, $stderr = STDOUT, STDERR
    end

    let(:iterations) { 5 }

    let(:real_app) {
      -> (env) {
        iterations.times do |i|
          sleep(rand * 0.001) # inject some temporal noise to encourage concurrency
          # STDERR.write "some stderr output from #{Thread.current[:id]} path=#{env['PATH_INFO']} #{i}\n"
          # STDOUT.write "some stdout output from #{Thread.current[:id]} path=#{env['PATH_INFO']} #{i}\n"
          $stderr.write "some stderr output from #{Thread.current[:id]} path=#{env['PATH_INFO']} #{i}"
          $stdout.write "some stdout output from #{Thread.current[:id]} path=#{env['PATH_INFO']} #{i}"
          env.fetch('rack.logger').info "some logger output from #{Thread.current[:id]} path=#{env['PATH_INFO']} #{i}"
        end

        [
          200,
          {
            'Content-Type' => 'text/plain',
            'Content-Length' => '2',
          },
          ['OK'],
        ]
      }
    }

    let(:formatter_invocations) { [] }

    let(:dummy_formatter) {
      -> (logger, log_obj, env) {
        formatter_invocations << [logger, log_obj.dup, env.dup]
      }
    }

    let(:app) { RackJsonLogger.new(real_app, formatter: dummy_formatter) }

    def env(request_uri='/uri')
      Rack::MockRequest.env_for(request_uri).merge(
        'HTTP_ACCEPT' => '*/*',
        'HTTP_CONNECTION' => 'close',
        'HTTP_HOST' => 'localhost',
        'HTTP_USER_AGENT' => 'curl',
        'REMOTE_ADDR' => '127.0.0.1'
      )
    end

    # focus
    it 'works as expected' do
      threads = 3.times.map { |i|
        Thread.new do
          Thread.current[:id] = "foo#{i}"
          app.call(env("foo#{i}"))
          _logger, log_obj, _env = formatter_invocations.pop
          log_obj
        end
      }

      threads.each(&:join)

      expected = threads.inject(StringIO.new) { |io, thread|
        key = thread[:id]
        iterations.times do |i|
          io.puts "#{key}: stderr: some stderr output from #{key} path=/#{key} #{i}"
          io.puts "#{key}: stdout: some stdout output from #{key} path=/#{key} #{i}"
          io.puts "#{key}: rack.logger: some logger output from #{key} path=/#{key} #{i}"
        end
        io
      }

      actual = threads.inject(StringIO.new) { |io, thread|
        thread.value.fetch(:log_events, []).each { |e|
          io.puts "#{thread[:id]}: #{e.stream}: #{e.body}"
        }
        io
      }

      assert_equal(expected.string, actual.string)
    end
  end
end
