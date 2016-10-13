require 'rack-json-logs/version'
require 'rack-json-logs/pretty-printer.rb'
require 'json'
require 'stringio'
require 'socket'

module Rack
  # JsonLogs is a rack middleware that will buffer output, capture exceptions,
  # and log the entire thing as a json object for each request.
  #
  # Options are:
  #
  #   :reraise_exceptions
  #
  #     Whether to re-raise exceptions, or just respond with a standard JSON
  #     500 response.
  #
  class JsonLogs
    DEFAULT_FORMATTER = -> (log_obj) {
      "\x1E" + log_obj.to_json + "\n"
    }
    # HUMAN_READABLE_FORMATTER = (l) -> {
    #   req, resp, out, err, events = l.values_at(:request, :response, :stdout, :stderr, :events)
    #   '\n' % []
    # }

    def initialize(app, formatter: DEFAULT_FORMATTER, reraise_exceptions: false)
      @app = app
      @reraise_exceptions = reraise_exceptions

      if formatter.respond_to?(:call)
        @formatter = formatter
      else
        fail ArgumentError, ':formatter should be an object which responds to the #call method'
      end
    end

    attr_reader :app
    attr_reader :reraise_exceptions
    attr_reader :formatter

    def call(env)
      start_time = Time.now
      $stdout, previous_stdout = (stdout_buffer = StringIO.new), $stdout
      $stderr, previous_stderr = (stderr_buffer = StringIO.new), $stderr

      logger = EventLogger.new(start_time)
      env = env.dup
      env[:logger] = logger

      begin
        response = app.call(env)
      rescue Exception => e
        exception = e
      end

      # restore output IOs
      $stderr = previous_stderr
      $stdout = previous_stdout

      log = {
        request: {
          method: env['REQUEST_METHOD'],
          path: env['PATH_INFO'],
        },
        response: {
          duration: Time.now - start_time,
          status: (response || [500]).first,
        },
      }

      unless stdout_buffer.string.empty? && stderr_buffer.string.empty?
        log[:stdout] = stdout_buffer.string
        log[:stderr] = stderr_buffer.string
      end

      # support X-Request-ID or ActionDispatch::RequestId middleware (which doesn't insert the header until after it runs the request)
      if (request_id = env['HTTP_X_REQUEST_ID'] || env['action_dispatch.request_id'])
        log[:request][:id] = request_id
      end

      if logger.events.any?
        log[:events] = logger.events
      end

      if exception
        log[:exception] = {
          message:   exception.message,
          backtrace: exception.backtrace
        }
      end

      STDOUT.print(formatter.call(log))

      if exception
        raise exception if reraise_exceptions
        response_500
      else
        response
      end
    end

    def response_500
      [
        500,
        { 'Content-Type' => 'application/json' },
        [{ status: 500, message: 'Server Error' }.to_json]
      ]
    end

    # This class can be used to log arbitrary events to the request.
    #
    class EventLogger
      attr_reader :events

      def initialize(start_time)
        @start_time = start_time
        @events     = []
      end

      # Log an event of type `type` and value `value`.
      #
      def log(type, value)
        @events << {
          type:  type,
          value: value,
          time:  (Time.now - @start_time).round(3)
        }
      end
    end
  end
end
