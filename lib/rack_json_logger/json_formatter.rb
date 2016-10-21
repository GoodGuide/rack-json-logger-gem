require 'json' # nb: this brings in many stdlib class #to_json methods which are used by the MultiJson adapters
require 'multi_json'

class RackJsonLogger
  class JSONFormatter
    def call(logger, log_obj, _env)
      logger.info "\x1E" << MultiJson.dump(log_obj)
    end
  end
end
