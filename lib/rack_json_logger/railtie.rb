require 'rails/railtie'
require 'active_support/ordered_options'
require 'active_support/log_subscriber'
require 'action_dispatch/http/filter_parameters'
require 'rack_json_logger'

class RackJsonLogger
  class Railtie < Rails::Railtie
    TransactionLogEvent.include ActionDispatch::Http::FilterParameters

    config.rack_json_logger = settings = ActiveSupport::OrderedOptions.new

    settings.enabled = false
    settings.capture_stdio = false
    settings.log_subscriber_components_to_remove = ['ActionController', 'ActionView']

    # limit to the all-caps keys which are the basic HTTP_ header and common CGI-style env vars.
    settings.trace_env = -> (key, _value) {
      key =~ /^[A-Z0-9_.-]+$/
    }

    initializer 'rack_json_logger.configure_logger', after: :initialize_logger do
      next unless settings.enabled
      Rails.logger = EventLogger::LoggerProxy.wrap(Rails.logger, 'Rails.logger')
    end

    initializer 'rack_json_logger.configure_middleware' do |app|
      next unless settings.enabled

      app.middleware.swap Rails::Rack::Logger, RackJsonLogger do |logger|
        [:trace_env, :trace_stack].each do |key|
          val = config.rack_json_logger[key] or next
          logger.send("#{key}=", val)
        end
      end
    end

    # Let RackJsonLogger capture and arbitrary STDOUT/STDERR which happens from threads which are used for request handling
    initializer 'rack_json_logger.setup_stdio_proxies' do
      next unless settings.enabled
      next unless settings.capture_stdio
      $stdout, $stderr = RackJsonLogger.output_proxies
    end

    # remove Rails' default logger output for ActionView and ActionController
    config.after_initialize do
      next unless settings.enabled

      components = settings.log_subscriber_components_to_remove
      if components.any?
        ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
          case subscriber
          when ActionView::LogSubscriber
            next unless components.include?('ActionView')
            RackJsonLogger::Railtie.unsubscribe_notifications :action_view, subscriber
          when ActionController::LogSubscriber
            next unless components.include?('ActionController')
            RackJsonLogger::Railtie.unsubscribe_notifications :action_controller, subscriber
          end
        end
      end
    end

    def self.unsubscribe_notifications(component, subscriber)
      events = subscriber.public_methods(false).reject { |method| method.to_s == 'call' }

      events.each do |event|
        ActiveSupport::Notifications.notifier.listeners_for("#{event}.#{component}").each do |listener|
          if listener.instance_variable_get('@delegate') == subscriber
            ActiveSupport::Notifications.unsubscribe listener
          end
        end
      end
    end
  end
end
