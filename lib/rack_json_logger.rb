require 'stringio'

require 'rack_json_logger/event_logger'
require 'rack_json_logger/json_formatter'
require 'rack_json_logger/pretty_formatter'
require 'rack_json_logger/transaction_log_event'
require 'rack_json_logger/version'

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
