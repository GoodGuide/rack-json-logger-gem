require 'stringio'

require 'rack_json_logger/version'
require 'rack_json_logger/pretty_formatter'
require 'rack_json_logger/json_formatter'
require 'rack_json_logger/event_logger'

##
# RackJsonLogger is a rack middleware that will buffer output, capture exceptions, and log the entire thing as a json object for each request.
class RackJsonLogger
  def initialize(app, logger: nil, formatter: JSONFormatter.new, trace_env: true, trace_stack: true)
    @app = app
    @logger = logger

    self.trace_env = trace_env
    self.trace_stack = trace_stack

    @formatter = validate_formatter(formatter)

    yield self if block_given?
  end

  attr_reader :app
  attr_accessor :formatter
  attr_writer :logger
  attr_reader :trace_env_filter
  attr_reader :trace_stack_filter

  def call(env)
    start_time = Time.now
    event_logger = EventLogger.new(start_time)

    response, exception = with_captured_output_streams(env, event_logger) {
      capture_exceptions {
        app.call(env)
      }
    }

    log = TransactionLogEvent.new(env).tap { |t|
      t.record_response response, exception
      t.duration = Time.now - start_time
      t.event_logger = event_logger
      t.trace_env_filter = trace_env_filter
      t.trace_stack_filter = trace_stack_filter
    }.as_json

    formatter.call(logger(env), log, env)

    return response unless exception
    raise exception # rubocop:disable Style/SignalException
  end

  def trace_env=(trace)
    filter = trace.respond_to?(:call) ? trace : -> (_k, _v) { trace }
    @trace_env_filter = validate_trace_env(filter)
  end

  def trace_stack=(trace)
    @trace_stack_filter = trace.respond_to?(:call) ? trace : -> (_l) { trace }
  end

  private

  class TransactionLogEvent
    def initialize(env)
      @env = env
      @finished = false
    end

    attr_accessor :request, :response, :exception, :env, :duration, :event_logger, :trace_stack_filter, :trace_env_filter

    def record_response(response, exception)
      @finished = true
      self.response = response
      self.exception = exception
    end

    def as_json
      log = {
        request: request_as_json,
        response: response_as_json,
      }
      log[:log_events] = event_logger.events if event_logger.events.any?
      log[:id] = request_id if request_id
      if exception
        log[:exception] = exception_as_json
        log[:env] = env.select(&trace_env_filter)
      end
      log
    end

    def request_as_json
      {
        method: env['REQUEST_METHOD'],
        path: env['REQUEST_URI'],
        user_agent: env['HTTP_USER_AGENT'],
        remote_addr: env.fetch('HTTP_X_REAL_IP') { env['REMOTE_ADDR'] },
        host: env.fetch('HTTP_HOST') { env['SERVER_HOST'] },
        scheme: env.fetch('HTTP_X_FORWARDED_PROTO') { env['rack.url_scheme'] },
      }
    end

    def response_as_json
      response = {
        duration: duration,
        status: response_status,
        length: response_headers['Content-Length'],
      }
      case response[:status]
      when 301, 302
        response[:redirect] = response_headers['Location']
      end
      response
    end

    def exception_as_json
      {
        class: exception.class,
        message: exception.message,
        backtrace: exception.backtrace.select(&trace_stack_filter),
      }
    end

    def response_status
      fail 'Response not finished' unless @finished
      Array(@response).fetch(0) {
        exception ? 500 : fail('response did not include a status')
      }
    end

    def response_headers
      fail 'Response not finished' unless @finished
      Array(@response).fetch(1) { {} }
    end

    # support X-Request-ID or ActionDispatch::RequestId middleware (which doesn't insert the header until after it runs the request)
    def request_id
      env.fetch('action_dispatch.request_id') {
        env['HTTP_X_REQUEST_ID']
      }
    end
  end

  def capture_exceptions
    return yield, nil
  rescue Exception => ex
    return nil, ex
  end

  def with_captured_output_streams(env, event_logger)
    $stdout, previous_stdout = event_logger.build_io_proxy('stdout'), $stdout
    $stderr, previous_stderr = event_logger.build_io_proxy('stderr'), $stderr
    env['rack.errors'], previous_rack_errors = event_logger.build_io_proxy('rack.errors'), env['rack.errors']
    env['rack.logger'], previous_rack_logger = event_logger.build_logger_proxy('rack.logger'), env['rack.logger']

    yield
  ensure
    # restore output IOs
    $stderr = previous_stderr
    $stdout = previous_stdout

    env['rack.errors'] = previous_rack_errors
    env['rack.logger'] = previous_rack_logger
  end

  def logger(env)
    @logger || env.fetch('rack.logger', Logger.new(STDERR))
  end

  def validate_formatter(f)
    f.respond_to?(:call) or
      fail ArgumentError, ':formatter should be an object which responds to the #call method'
    f
  end

  def validate_trace_env(trace_env)
    ary = nil
    if trace_env.is_a?(Proc)
      ary = trace_env.arity
    elsif trace_env.respond_to?(:call)
      ary = trace_env.method(:call).arity
    end
    ary == 2 or
      fail ArgumentError, 'trace_env should be either Boolean or an object which responds to #call(key, value)'

    trace_env
  end
end
