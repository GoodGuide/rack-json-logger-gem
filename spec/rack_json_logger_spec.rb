require 'rack'

require_relative './spec_helper'
require 'rack_json_logger'

APPS = {
  happy: -> (_env) {
    [
      200,
      {
        'Content-Type' => 'text/plain',
        'Content-Length' => '2',
      },
      ['OK'],
    ]
  },
  sad: -> (_env) {
    e = RuntimeError.new('boom')
    def e.backtrace
      [
        'some-file.rb:4',
        'some-other-file.rb:23',
        'some-file.rb:1',
      ]
    end
    fail e
  },
}.freeze

describe RackJsonLogger do
  before { Timecop.freeze }
  after { Timecop.return }

  let(:app_invocations) { [] }
  let(:formatter_invocations) { [] }

  let(:dummy_formatter) {
    -> (logger, log_obj, env) {
      formatter_invocations << [logger, log_obj.dup, env.dup]
    }
  }

  let(:real_app) { APPS[:happy] }
  let(:app_wrapper) {
    -> (env) {
      env = env.dup
      app_invocations << env
      Timecop.freeze(Time.now + request_duration)
      real_app.call(env)
    }
  }

  let(:request_duration) { rand }
  let(:request_path) { '/foo' }
  let(:request_method) { 'GET' }
  let(:request_query_string) { 'bar=baz' }
  let(:request_uri) { [request_path, request_query_string].join('?') }
  let(:http_user_agent) { ['minitest', (rand * 100).to_i.to_s(16)].join('-') }

  let(:app) { RackJsonLogger.new(app_wrapper, formatter: dummy_formatter) }
  subject { app }

  let(:env) {
    Rack::MockRequest.env_for(request_uri).merge(
      'HTTP_ACCEPT' => '*/*',
      'HTTP_CONNECTION' => 'close',
      'HTTP_HOST' => 'localhost',
      'HTTP_USER_AGENT' => http_user_agent,
      'REMOTE_ADDR' => '127.0.0.1'
    )
  }

  describe '#call' do
    it 'calls the app and formatters exactly once each' do
      app.call(env)
      assert_equal 1, app_invocations.length
      assert_equal 1, formatter_invocations.length
    end

    it "calls the app with the `env`, changing 'rack.errors' & 'rack.logger' to capture the output, while returning those keys to the original values" do
      original_env = env.dup
      app.call(env)

      called_with_env = app_invocations.first

      (env.keys - ['rack.errors', 'rack.logger']).each do |key|
        assert_equal env[key], called_with_env[key],
          "called app with env[#{key}] different to supplied env"
      end

      env.keys.each do |key|
        assert_equal original_env[key], env[key],
          "env[#{key}] mutated"
      end

      assert_instance_of RackJsonLogger::EventLogger::IOProxy, called_with_env['rack.errors']
      assert_respond_to called_with_env['rack.logger'], :stream_name
    end

    describe 'when pushed through the Rack::Lint middleware' do
      let(:real_app) { Rack::Lint.new(APPS[:happy]) }

      it 'passes the checks' do
        app.call(env)
      end
    end

    describe 'log_obj sent to formatter' do
      let(:log_obj) {
        app.call(env)
        _logger, log_obj, _env = formatter_invocations.first
        log_obj
      }

      it 'builds the log_obj correctly' do
        assert_equal(
          {
            request: {
              method: request_method,
              path: request_uri,
              user_agent: http_user_agent,
              remote_addr: '127.0.0.1',
              host: 'localhost',
              scheme: 'http',
            },
            response: {
              duration: request_duration,
              status: 200,
              length: 2,
            },
          },
          log_obj
        )
      end

      describe 'request.user_agent' do
        before { assert env.key?('HTTP_USER_AGENT') }
        it 'is the value of the HTTP_USER_AGENT header' do
          assert_equal http_user_agent, log_obj[:request][:user_agent]
        end
      end

      describe 'request.path' do
        describe 'when request env has REQUEST_URI key' do
          before { env['REQUEST_URI'] = request_uri }

          it 'uses that directly' do
            assert_equal request_uri, log_obj[:request][:path]
          end
        end

        describe 'when request env has no REQUEST_URI key' do
          before {
            env.delete('REQUEST_URI')
            assert_equal request_path, env['PATH_INFO']
            assert_equal request_query_string, env['QUERY_STRING']
          }

          it 'uses a combination of the REQUEST_PATH and QUERY_STRING' do
            assert_equal(
              [env['PATH_INFO'], env['QUERY_STRING']].join('?'),
              log_obj[:request][:path]
            )
          end
        end
      end

      describe 'request.remote_addr' do
        before { env['REMOTE_ADDR'] = '127.0.0.1' }

        describe 'when request env has HTTP_X_REAL_IP key' do
          before { env['HTTP_X_REAL_IP'] = '1.2.3.4' }

          it 'uses that directly' do
            assert_equal '1.2.3.4', log_obj[:request][:remote_addr]
          end
        end

        describe 'when request env has no HTTP_X_REAL_IP key' do
          before { env.delete('HTTP_X_REAL_IP') }

          it 'uses REMOTE_ADDR' do
            assert_equal env['REMOTE_ADDR'], log_obj[:request][:remote_addr]
          end
        end
      end

      describe 'request.host' do
        before { env['SERVER_HOST'] = 'localhost' }

        describe 'when request env has HTTP_HOST key' do
          before { env['HTTP_HOST'] = 'foo.com' }

          it 'uses that directly' do
            assert_equal env['HTTP_HOST'], log_obj[:request][:host]
          end
        end

        describe 'when request env has no HTTP_HOST key' do
          before { env.delete('HTTP_HOST') }

          it 'uses SERVER_HOST' do
            assert_equal env['SERVER_HOST'], log_obj[:request][:host]
          end
        end
      end

      describe 'request.scheme' do
        before { env['rack.url_scheme'] = 'http' }

        describe 'when request env has HTTP_X_FORWARDED_PROTO key' do
          before { env['HTTP_X_FORWARDED_PROTO'] = 'https' }

          it 'uses that directly' do
            assert_equal env['HTTP_X_FORWARDED_PROTO'], log_obj[:request][:scheme]
          end
        end

        describe 'when request env has no HTTP_X_FORWARDED_PROTO key' do
          before { env.delete('HTTP_X_FORWARDED_PROTO') }

          it 'uses rack.url_scheme' do
            assert_equal env['rack.url_scheme'], log_obj[:request][:scheme]
          end
        end
      end

      describe 'id' do
        it 'sets the id from a X-Request-Id header' do
          env['HTTP_X_REQUEST_ID'] = 'someId123'

          assert_equal('someId123', log_obj[:id])
        end

        it 'sets the id from an action_dispatch.request_id key in the env' do
          env['action_dispatch.request_id'] = 'someId123'

          assert_equal('someId123', log_obj[:id])
        end

        it 'if both present, gives preference to the action_dispatch.request_id' do
          env['HTTP_X_REQUEST_ID'] = 'xRequestId123'
          env['action_dispatch.request_id'] = 'actionDispactchId'

          assert_equal('actionDispactchId', log_obj[:id])
        end
      end

      describe 'response.redirect' do
        [301, 302].each do |status|
          describe "when the response is #{status}" do
            let(:real_app) {
              -> (_env) {
                [status, { 'Location' => 'http://google.com' }, []]
              }
            }
            it 'includes the Location header in log_obj.response.redirect' do
              assert_equal status, log_obj[:response][:status]
              assert_equal 'http://google.com', log_obj[:response][:redirect]
            end
          end
        end
      end

      describe 'log_events' do
        describe 'when the app never used the log' do
          it 'is non-existent' do
            refute log_obj.key?(:log_events)
          end
        end

        describe 'when the app used the log' do
          let(:real_app) do
            -> (env) {
              env['rack.logger'].info 'some event'
              APPS[:happy].call(env)
            }
          end

          it 'contains the log events' do
            assert_equal(
              [
                RackJsonLogger::EventLogger::LogEvent.new(:'rack.logger', request_duration, 'some event', 'INFO'),
              ],
              log_obj.fetch(:log_events)
            )
          end
        end
      end
    end

    describe 'when the app raises an exception' do
      let(:real_app) { APPS[:sad] }

      let(:call_app) {
        ex = assert_raises(RuntimeError) { app.call(env) }
        assert_equal 'boom', ex.message
      }

      let(:log_obj) {
        call_app
        _logger, log_obj, _env = formatter_invocations.first
        log_obj
      }

      it 'calls the app and formatters exactly once each' do
        call_app
        assert_equal 1, app_invocations.length
        assert_equal 1, formatter_invocations.length
      end

      describe 'log_obj' do
        describe 'exception' do
          it 'includes the exception' do
            assert_equal(
              {
                class: RuntimeError,
                message: 'boom',
                backtrace: [
                  'some-file.rb:4',
                  'some-other-file.rb:23',
                  'some-file.rb:1',
                ],
              },
              log_obj[:exception]
            )
          end

          describe 'backtrace' do
            describe 'when the middleware has trace_stack = false' do
              before {
                app.trace_stack = false
              }

              it 'is an empty array' do
                assert_equal [], log_obj[:exception][:backtrace]
              end
            end

            describe 'when the middleware has trace_stack = a proc' do
              before {
                app.trace_stack = -> (file) { file =~ /some-other-file/ }
              }

              it 'filters the backtrace' do
                assert_equal(
                  ['some-other-file.rb:23'],
                  log_obj.fetch(:exception).fetch(:backtrace)
                )
              end
            end
          end
        end

        describe 'env' do
          it 'is the request env' do
            assert_equal(env, log_obj[:env])
          end

          describe 'when the middleware has trace_env = false' do
            before { app.trace_env = false }

            it 'is an empty hash' do
              assert log_obj.fetch(:env).empty?
            end
          end

          describe 'when the middleware has trace_env = proc' do
            before {
              app.trace_env = -> (key, _value) { key =~ /^HTTP_/ }
            }

            it 'filters the env' do
              assert_equal(
                {
                  'HTTP_ACCEPT' => '*/*',
                  'HTTP_CONNECTION' => 'close',
                  'HTTP_HOST' => 'localhost',
                  'HTTP_USER_AGENT' => http_user_agent,
                },
                log_obj.fetch(:env)
              )
            end

            describe 'with wrong arity' do
              it 'raises an exception' do
                ex = assert_raises(ArgumentError) {
                  app.trace_env = -> (key) { key =~ /^HTTP_/ }
                }
                assert_match(/trace_env/, ex.message)
              end
            end
          end
        end
      end
    end
  end

  describe 'logger device used for output' do
    describe 'when #logger= option is set' do
      let(:default_logger) { Logger.new(STDOUT) }
      before { subject.logger = default_logger }

      it 'calls the formatter with that logger' do
        app.call(env)
        logger, _log_obj, _env = formatter_invocations.first
        assert_equal(default_logger, logger)
      end
    end

    describe 'when rack.logger is present in request env' do
      let(:rack_logger) { Logger.new(STDOUT) }
      before { env['rack.logger'] = rack_logger }

      it 'calls the formatter with logger = env["rack.logger"]' do
        app.call(env)
        logger, _log_obj, _env = formatter_invocations.first
        assert_equal(rack_logger, logger)
      end

      describe 'when #logger= is also set' do
        let(:default_logger) { Logger.new(STDOUT) }
        before { subject.logger = default_logger }

        it 'calls the formatter with logger set to the default, not the rack.logger' do
          app.call(env)
          logger, _log_obj, _env = formatter_invocations.first
          assert_equal(default_logger, logger)
        end
      end
    end
  end
end
