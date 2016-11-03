class RackJsonLogger
  module DefaultFilterParameters
    # Under a Rails environment, this method is overriden by including ActionDispatch::Http::FilterParameters
    def filtered_parameters
      parameters
    end
  end

  class TransactionLogEvent
    include DefaultFilterParameters

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

    private

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
        parameters: filtered_parameters,
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

    def parameters
      env.fetch('action_dispatch.request.parameters') {
        env.fetch('rack.query_hash', {})
      }
    end

    # the following methods are used by ActionDispatch::Http::FilterParameters
    def fetch_header(name, &block)
      @env.fetch(name, &block)
    end
  end
end
