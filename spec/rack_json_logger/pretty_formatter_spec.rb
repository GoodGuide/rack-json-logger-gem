require_relative '../spec_helper'
require 'rack_json_logger/pretty_formatter'

describe RackJsonLogger::PrettyFormatter do
  subject { RackJsonLogger::PrettyFormatter.new }
  let(:logger) { TestLogger.new }

  let(:request_method) { 'GET' }
  let(:request_path) { '/test' }
  let(:request_query_string) { 'foo=bar' }
  let(:request_uri) { [request_path, request_query_string].compact.join('?') }
  let(:response_duration) { 0.032 }
  let(:response_status) { 200 }

  let(:log_obj) do
    {
      request: {
        method: request_method,
        path: request_uri,
      },
      response: {
        duration: response_duration,
        status: response_status,
      },
    }
  end

  let(:env) do
    Hash.new
  end

  def execute
    subject.call(logger, DeepDup.deep_dup(log_obj), DeepDup.deep_dup(env))
  end

  describe 'for a non-exception 2xx request' do
    let(:response_status) { 200 }

    it 'logs a single, green-colorized INFO line summarizing the important details' do
      execute
      assert_log_events(logger) do |l|
        l.info %(\e[0;32;49m0.0320s 200 - GET "/test?foo=bar"\e[0m)
      end
    end

    describe 'when the request path contains quote marks' do
      let(:request_path) { '/foo"bar' }
      it 'handles them correctly' do
        execute
        assert_log_events(logger) do |l|
          l.info %(\e[0;32;49m0.0320s 200 - GET "/foo\\"bar?foo=bar"\e[0m)
        end
      end
    end
    describe 'when the request path contains spaces' do
      let(:request_path) { '/foo bar' }
      it 'handles them correctly' do
        execute
        assert_log_events(logger) do |l|
          l.info %(\e[0;32;49m0.0320s 200 - GET "/foo bar?foo=bar"\e[0m)
        end
      end
    end
  end

  describe 'for a non-exception 4xx request' do
    let(:response_status) { 404 }
    it 'logs a single, red-colorized INFO line summarizing the important details' do
      execute
      assert_log_events(logger) do |l|
        l.info %(\e[0;31;49m0.0320s 404 - GET "/test?foo=bar"\e[0m)
      end
    end
  end

  describe 'when the request has an X-Request-Id' do
    before do
      log_obj[:id] = 'request-ID'
    end

    it 'logs the normal line, prefixed with the request ID' do
      execute
      assert_log_events(logger) do |l|
        l.info %(request-ID| \e[0;32;49m0.0320s 200 - GET "/test?foo=bar"\e[0m)
      end
    end
  end

  describe 'when the log_obj includes the env' do
    let(:env) do
      {
        'abc' => 123,
        'foo' => 'bar',
        'foo1' => ['bar', 'baz'],
        'another key' => 'with a long value so it wraps!',
      }
    end

    before do
      log_obj[:env] = env
      log_obj[:id] = 'some-request-id'
    end

    it 'logs the normal line, then pretty-prints the env' do
      execute
      assert_log_events(logger) do |l|
        l.info  %(some-request-id| \e[0;32;49m0.0320s 200 - GET "/test?foo=bar"\e[0m)
        l.debug %(some-request-id| Request ENV follows:)
        l.debug %(some-request-id| {"abc"=>123,)
        l.debug %(some-request-id|  "foo"=>"bar",)
        l.debug %(some-request-id|  "foo1"=>["bar", "baz"],)
        l.debug %(some-request-id|  "another key"=>"with a long value so it wraps!"})
      end
    end
  end

  describe 'when the log_obj includes an exception' do
    let(:response_status) { 500 }
    before do
      log_obj[:exception] = {
        class: 'ArgumentError',
        message: 'foo is wrong',
        backtrace: [
          '/file.rb:1',
          '/file.rb:4',
        ],
      }
    end

    it 'logs a single, red-colorized INFO summary line, then the exception class & message, followed by the stack trace' do
      execute
      assert_log_events(logger) do |l|
        l.info  %(\e[0;31;49m0.0320s 500 - GET "/test?foo=bar"\e[0m)
        l.error %(Exception: ArgumentError foo is wrong)
        l.debug %(  /file.rb:1)
        l.debug %(  /file.rb:4)
      end
    end

    it 'correctly prepends a request-id if present' do
      log_obj[:id] = 'request-id'
      execute
      assert_log_events(logger) do |l|
        l.info  %(request-id| \e[0;31;49m0.0320s 500 - GET "/test?foo=bar"\e[0m)
        l.error %(request-id| Exception: ArgumentError foo is wrong)
        l.debug %(request-id|   /file.rb:1)
        l.debug %(request-id|   /file.rb:4)
      end
    end

    it 'works fine if backtrace is empty' do
      log_obj[:id] = 'request-id'
      log_obj[:exception][:backtrace] = nil
      execute
      assert_log_events(logger) do |l|
        l.info  %(request-id| \e[0;31;49m0.0320s 500 - GET "/test?foo=bar"\e[0m)
        l.error %(request-id| Exception: ArgumentError foo is wrong)
      end
    end
  end
end
