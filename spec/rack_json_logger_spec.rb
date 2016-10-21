require_relative './spec_helper'
require 'rack_json_logger'

APPS = {
  happy: -> (_env) {
    [
      200,
      {
        'Content-Type' => 'text/plain',
        'Content-Length' => 2,
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

  let(:app) { APPS[:happy] }
  let(:app_wrapper) {
    -> (env) {
      env = env.dup
      app_invocations << env
      Timecop.freeze(Time.now + request_duration)
      app.call(env)
    }
  }

  let(:request_duration) { rand }
  let(:request_path) { '/foo' }
  let(:request_method) { 'GET' }
  let(:request_query_string) { 'bar=baz' }
  let(:request_uri) { [request_path, request_query_string].join('?') }

  subject { RackJsonLogger.new(app_wrapper, formatter: dummy_formatter) }

  let(:env) {
    {
      'HTTP_ACCEPT' => '*/*',
      'HTTP_CONNECTION' => 'close',
      'HTTP_HOST' => 'localhost',
      'HTTP_USER_AGENT' => 'curl/7.43.0',
      'HTTP_VERSION' => 'HTTP/1.1',
      'HTTP_X_FORWARDED_PROTO' => 'http',
      'PATH_INFO' => request_path,
      'QUERY_STRING' => request_query_string,
      'REMOTE_ADDR' => '127.0.0.1',
      'REQUEST_METHOD' => request_method,
      'REQUEST_PATH' => request_path,
      'REQUEST_URI' => request_uri,
      'SCRIPT_NAME' => '',
      'SERVER_NAME' => 'localhost',
      'SERVER_PORT' => '80',
      'rack.errors' => STDERR,
      'rack.hijack?' => true,
      # 'rack.logger' => Logger.new(STDOUT),
      'rack.multiprocess' => false,
      'rack.multithread' => true,
      'rack.run_once' => false,
      'rack.url_scheme' => 'http',
      'rack.version' => [1, 3],
    }
  }

  it 'calls the app once' do
    subject.call(env)
    assert_equal 1, app_invocations.length
  end

  it "calls the app with the `env`, changing 'rack.errors' & 'rack.logger' to capture the output, while returning those keys to the original values" do
    original_env = env.dup
    subject.call(env)

    called_with_env = app_invocations.first

    (env.keys - ['rack.errors', 'rack.logger']).each do |key|
      assert_equal env[key], called_with_env[key], "called app with env[#{key}] different to supplied env"
    end
    env.keys.each do |key|
      assert_equal original_env[key], env[key], "env[#{key}] mutated"
    end

    assert_instance_of RackJsonLogger::EventLogger::IOProxy, called_with_env['rack.errors']
    assert_instance_of RackJsonLogger::EventLogger::LoggerProxy, called_with_env['rack.logger']
  end

  it 'calls the formatter once' do
    subject.call(env)
    assert_equal 1, formatter_invocations.length
  end

  it 'calls the formatter with a properly generated log_obj' do
    subject.call(env)
    _logger, log_obj, _env = formatter_invocations.first
    assert_equal(
      {
        request: {
          method: request_method,
          path: request_uri,
          user_agent: 'curl/7.43.0',
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

  describe 'request ID:' do
    it 'sets the id from a X-Request-Id header' do
      env['HTTP_X_REQUEST_ID'] = 'someId123'
      subject.call(env)
      _logger, log_obj, _env = formatter_invocations.first
      assert_equal('someId123', log_obj[:id])
    end

    it 'sets the id from an action_dispatch.request_id key in the env' do
      env['action_dispatch.request_id'] = 'someId123'
      subject.call(env)
      _logger, log_obj, _env = formatter_invocations.first
      assert_equal('someId123', log_obj[:id])
    end

    it 'if both present, gives preference to the action_dispatch.request_id' do
      env['HTTP_X_REQUEST_ID'] = 'xRequestId123'
      env['action_dispatch.request_id'] = 'actionDispactchId'
      subject.call(env)
      _logger, log_obj, _env = formatter_invocations.first
      assert_equal('actionDispactchId', log_obj[:id])
    end
  end

  describe 'when #logger= option is set' do
    let(:default_logger) { Logger.new(STDOUT) }
    before { subject.logger = default_logger }

    it 'calls the formatter with that logger' do
      subject.call(env)
      logger, _log_obj, _env = formatter_invocations.first
      assert_equal(default_logger, logger)
    end
  end

  describe 'when rack.logger is present' do
    let(:rack_logger) { Logger.new(STDOUT) }
    before { env['rack.logger'] = rack_logger }

    it 'calls the formatter with logger = env["rack.logger"]' do
      subject.call(env)
      logger, _log_obj, _env = formatter_invocations.first
      assert_equal(rack_logger, logger)
    end

    describe 'when #logger= is also set' do
      let(:default_logger) { Logger.new(STDOUT) }
      before { subject.logger = default_logger }

      it 'calls the formatter with logger set to the default, not the rack.logger' do
        subject.call(env)
        logger, _log_obj, _env = formatter_invocations.first
        assert_equal(default_logger, logger)
      end
    end
  end

  [301, 302].each do |status|
    describe 'when the response is #{status}' do
      let(:app) {
        -> (_env) {
          [status, { 'Location' => 'http://google.com' }, []]
        }
      }
      it 'includes the Location header in log_obj.response.redirect' do
        subject.call(env)
        _logger, log_obj, _env = formatter_invocations.first
        assert_equal status, log_obj[:response][:status]
        assert_equal 'http://google.com', log_obj[:response][:redirect]
      end
    end
  end

  describe 'when the app raises an exception' do
    let(:app) { APPS[:sad] }

    it 'calls the formatter with a properly generated log_obj' do
      assert_raises(RuntimeError) do
        subject.call(env)
      end

      _logger, log_obj, _env = formatter_invocations.first
      assert_equal(
        {
          request: {
            method: request_method,
            path: request_uri,
            user_agent: 'curl/7.43.0',
            remote_addr: '127.0.0.1',
            host: 'localhost',
            scheme: 'http',
          },
          response: {
            duration: request_duration,
            status: 500,
            length: nil,
          },
          exception: {
            class: RuntimeError,
            message: 'boom',
            backtrace: [
              'some-file.rb:4',
              'some-other-file.rb:23',
              'some-file.rb:1',
            ],
          },
          env: env,
        },
        log_obj
      )
    end

    it 'filters the backtrace' do
      subject.trace_stack = -> (file) {
        file =~ /some-other-file/
      }

      assert_raises do
        subject.call(env)
      end

      _logger, log_obj, _env = formatter_invocations.first
      assert_equal(
        ['some-other-file.rb:23'],
        log_obj.fetch(:exception).fetch(:backtrace)
      )
    end

    it 'filters the env' do
      subject.trace_env = -> (key, _value) {
        key =~ /^HTTP_/
      }

      assert_raises do
        subject.call(env)
      end

      _logger, log_obj, _env = formatter_invocations.first
      assert_equal(
        {
          'HTTP_ACCEPT' => '*/*',
          'HTTP_CONNECTION' => 'close',
          'HTTP_HOST' => 'localhost',
          'HTTP_USER_AGENT' => 'curl/7.43.0',
          'HTTP_VERSION' => 'HTTP/1.1',
          'HTTP_X_FORWARDED_PROTO' => 'http',
        },
        log_obj.fetch(:env)
      )
    end
  end
end
