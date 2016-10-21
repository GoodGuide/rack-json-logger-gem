require_relative '../spec_helper'
require 'rack_json_logger/json_formatter'

describe RackJsonLogger::JSONFormatter do
  subject { RackJsonLogger::JSONFormatter.new }
  let(:logger) { TestLogger.new }

  let(:log_obj) do
    {
      request: {
        method: 'GET',
        path: '/test?foo=bar',
      },
      response: {
        duration: 0.032,
        status: 200,
      },
    }
  end

  let(:env) do
    Hash.new
  end

  def execute
    subject.call(logger, DeepDup.deep_dup(log_obj), DeepDup.deep_dup(env))
  end

  describe 'it logs a single event with the JSON-encoded version of the log_obj' do
    specify do
      execute
      assert_json_log_event(logger, :info, log_obj)
    end

    specify do
      log_obj[:response][:status] = 400
      execute
      assert_json_log_event(logger, :info, log_obj)
    end

    specify do
      log_obj[:id] = 'request-ID'
      execute
      assert_json_log_event(logger, :info, log_obj)
    end

    it 'is does not depend on value of "env"' do
      env.merge!(foo: 1, bar: 2)
      execute
      assert_json_log_event(logger, :info, log_obj)
    end

    specify do
      log_obj[:response][:status] = 500
      log_obj[:exception] = {
        class: 'ArgumentError',
        message: 'foo is wrong',
        backtrace: [
          '/file.rb:1',
          '/file.rb:4',
        ],
      }

      execute
      assert_json_log_event(logger, :info, log_obj)
    end
  end
end
