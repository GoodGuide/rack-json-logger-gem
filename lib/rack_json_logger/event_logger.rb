class RackJsonLogger
  ##
  # ::Logger-compatible logger target which captures instead of printing events it receives
  class EventLogger
    def initialize(start_time=Time.now)
      @events = []
      @start_time = start_time
    end

    attr_reader :events

    def add_logger_event(stream_name, severity, datetime, progname, msg)
      events.push LogEvent.new(
        stream_name,
        time_since_start(datetime),
        msg,
        severity,
        progname
      )
    end

    def add_io_event(stream_name, obj)
      events.push LogEvent.new(
        stream_name,
        time_since_start,
        obj,
        nil,
        nil
      )
    end

    def inspect
      "#<#{self.class.name}:#{object_id}>"
    end

    private

    def time_since_start(time=Time.now)
      time - @start_time
    end

    LogEvent = Struct.new(:stream, :time, :body, :severity, :progname) do
      def ==(other)
        return false unless other.class == self.class
        other.stream == stream &&
          other.body == body &&
          other.severity == severity &&
          other.progname == progname &&
          (time - other.time).abs < 0.000000000000001
      end

      def as_json(*args)
        h = to_h.reject { |_k, v| v.nil? }
        if h.respond_to?(:as_json)
          h.as_json(*args)
        else
          h
        end
      end

      def to_json
        as_json.to_json
      end
    end

    ##
    # Wraps an object implementing the IO::generic_writable interface. When written to, it checks for an EventLogger registered to the thread-local `rack_json_logs_event_handler` and sends the string there as a log event rather than writing to the underlying IO object. Inheriting StringIO is merely to simplify the implementation -- StringIO features are not used.
    class IOProxy < StringIO
      def initialize(io, stream_name=nil)
        @io = io
        @io.respond_to?(:write) && @io.respond_to?(:putc) or
          fail ArgumentError, "#{self.class} needs to wrap an IO object (or something which responds to #write and #putc"
        self.stream_name = stream_name if stream_name
        super()
      end

      def write(obj)
        if event_logger
          event_logger.add_io_event(stream_name, obj)
        else
          @io.write(obj)
        end
      end

      def putc(obj)
        if event_logger
          event_logger.add_io_event(stream_name, obj)
        else
          @io.putc(obj)
        end
      end

      attr_writer :stream_name

      private

      def event_logger
        Thread.current[:rack_json_logs_event_handler]
      end

      def stream_name
        return @stream_name if instance_variable_defined?(:@stream_name)
        case @io.fileno
        when 1
          :stdout
        when 2
          :stderr
        else
          @io.inspect
        end
      end
    end

    module LoggerProxy
      def wrap(logger, stream_name)
        logger = logger.clone
        logger.extend(InstanceMethods)
        logger.stream_name = stream_name
        logger
      end
      module_function :wrap

      module InstanceMethods
        attr_accessor :stream_name
        def format_message(severity, datetime, progname, msg)
          event_logger = Thread.current[:rack_json_logs_event_handler]
          return super unless event_logger
          event_logger.add_logger_event(stream_name, severity, datetime, progname, msg)
          # the return of format_message is given to @logdev.write(); nil here will cause no write to happen
          nil
        end
      end
    end
  end
end
