class RackJsonLogger
  ##
  # ::Logger-compatible logger target which captures instead of printing events it receives
  class EventLogger
    def initialize(start_time=Time.now)
      @events = []
      @start_time = start_time
    end

    attr_reader :events

    def build_logger_proxy(stream_name)
      LoggerProxy.new do |severity, datetime, progname, msg|
        events.push LogEvent.new(
          stream_name,
          time_since_start(datetime),
          msg,
          severity,
          progname
        )
      end
    end

    def build_io_proxy(stream_name)
      IOProxy.new do |obj|
        events.push LogEvent.new(
          stream_name,
          time_since_start,
          obj,
          nil,
          nil
        )
      end
    end

    private

    def time_since_start(time=Time.now)
      time - @start_time
    end

    LogEvent = Struct.new(:stream, :time, :body, :severity, :progname)

    class IOProxy < StringIO
      def initialize(&event_handler)
        @event_handler = event_handler
        super()
      end

      def write(obj)
        @event_handler.call(obj)
        super
      end

      def putc(obj)
        @event_handler.call(obj)
        super
      end
    end

    class LoggerProxy < ::Logger
      def initialize(&event_handler)
        super('/dev/null') # never actually print anything
        @level = 0 # always record every message
        @event_handler = event_handler
      end

      def format_message(severity, datetime, progname, msg)
        @event_handler.call(severity, datetime, progname, msg.to_s)
        super
      end
    end
  end
end
