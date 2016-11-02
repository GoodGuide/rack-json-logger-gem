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

  def self.output_proxies
    [EventLogger::IOProxy.new($stdout), EventLogger::IOProxy.new($stderr)]
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

    formatter.call(logger, log, env)

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
        log[:env] = env_as_json
      end
      log
    end

    def exception
      @exception ||
        env['sinatra.error'] ||
        env['action_dispatch.exception']
    end

    def request_as_json
      {
        method: env['REQUEST_METHOD'],
        path: env.fetch('REQUEST_URI') {
          [env['PATH_INFO'], env['QUERY_STRING']].compact.join('?')
        },
        user_agent: env['HTTP_USER_AGENT'],
        remote_addr: env.fetch('HTTP_X_REAL_IP') {
          env['REMOTE_ADDR']
        },
        host: env.fetch('HTTP_HOST') {
          env['SERVER_HOST']
        },
        scheme: env.fetch('HTTP_X_FORWARDED_PROTO') {
          env['rack.url_scheme']
        },
      }
    end

    def response_as_json
      response = {
        duration: duration,
        status: response_status,
      }

      if (v = response_headers['Content-Length'])
        response[:length] = Integer(v)
      end

      case response[:status]
      when 301, 302
        response[:redirect] = response_headers['Location']
      end
      response
    end

    def exception_as_json
      {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace.select(&trace_stack_filter),
      }
    end

    # return the filtered env, with any non-JSON-primative values stringified instead of letting the JSON serializer do whatever with them
    def env_as_json
      env.each_with_object({}) { |(k, v), hash|
        next unless trace_env_filter.call(k, v)
        case v
        when String, Numeric, NilClass, TrueClass, FalseClass
          hash[k] = v
        else
          hash[k] = v.inspect
        end
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
    previous_rack_errors = env['rack.errors']
    previous_rack_logger = env['rack.logger']

    Thread.current[:rack_json_logs_event_handler] = event_logger

    env['rack.errors'] = EventLogger::IOProxy.new(previous_rack_errors, :'rack.errors')
    env['rack.logger'] = EventLogger::LoggerProxy.wrap(previous_rack_logger || default_logger, :'rack.logger')

    begin
      yield
    ensure
      env['rack.errors'] = previous_rack_errors
      env['rack.logger'] = previous_rack_logger

      Thread.current[:rack_json_logs_event_handler] = nil
    end
  end

  def logger
    @logger ||= default_logger
  end

  def default_logger
    Logger.new(STDOUT).tap do |logger|
      logger.level = :debug
      logger.formatter = -> (_, _, _, msg) { msg << "\n" }
    end
  end

  def validate_formatter(f)
    f.respond_to?(:call) or
      fail ArgumentError, ':formatter should be an object which responds to the #call method'
    f
  end

  def validate_trace_env(trace_env)
    trace_env.is_a?(Proc) and trace_env.arity == 2 or
      fail ArgumentError, 'trace_env should be either Boolean or an object which responds to #call(key, value)'

    trace_env
  end
end

require 'rack_json_logger/railtie' if defined?(Rails)
