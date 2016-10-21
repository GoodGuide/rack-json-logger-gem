require 'logger'
require 'colorized_string'

class RackJsonLogger
  class PrettyFormatter
    def call(logger, log_obj, _env)
      logger = TaggedLogger.wrap(logger)

      logger.tag = log_obj[:id] if log_obj[:id]

      summary_color = status_color(log_obj[:response][:status])

      status_line = '%05.4fs %i - %s %s' % [
        log_obj[:response][:duration],
        log_obj[:response][:status],
        log_obj[:request][:method],
        log_obj[:request][:path].inspect,
      ]

      logger.info ColorizedString.new(status_line).colorize(summary_color)

      if log_obj[:exception]
        logger.error "Exception: #{log_obj[:exception][:class]} #{log_obj[:exception][:message]}"

        Array(log_obj[:exception][:backtrace]).each do |e|
          logger.debug "  #{e}"
        end
      end

      if log_obj[:env]
        logger.debug 'Request ENV follows:'
        logger.debug log_obj[:env].pretty_inspect
      end
    end

    private

    def status_color(status)
      case status
      when 200...300
        :green
      when 300...600
        :red
      else
        :cyan
      end
    end

    class TaggedLogger < ::Logger
      module InstanceMethods
        def tag=(tag)
          @tag_str = "#{tag}| "
        end

        def format_message(severity, datetime, progname, message)
          message.split("\n").map { |line|
            super(severity, datetime, progname, @tag_str.to_s + line)
          }.join
        end
      end

      def self.wrap(logger)
        logger.dup.extend(InstanceMethods)
      end
    end
  end
end
