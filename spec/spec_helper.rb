require 'logger'
require 'json'
require 'pp'

require 'simplecov'
require 'minitest/autorun'
require 'minitest/spec'
require 'minitest/reporters'
require 'minitest/focus'
require 'hash_diff'
require 'deep_dup'
require 'awesome_print'
require 'timecop'

Minitest::Reporters.use! [
  Minitest::Reporters::DefaultReporter.new,
  # Minitest::Reporters::MeanTimeReporter.new(previous_runs_filename: File.expand_path('../tmp/minitest_previous_runs', __dir__), show_progress: false),
  Minitest::Reporters::HtmlReporter.new(reports_dir: 'spec/report'),
  Minitest::Reporters::JUnitReporter.new('spec/report'),
]

class TestLogger < ::Logger
  def initialize
    super('/dev/null')
    @events = []
    @level = 0 # always record every message
  end

  attr_reader :events

  def format_message(severity, datetime, progname, msg)
    events << [severity, msg]
    super(severity, datetime, progname, msg)
  end

  class LogExpectationBuilder
    def initialize
      @expected_events = []
      yield self if block_given?
    end
    attr_reader :expected_events

    def info(msg)
      @expected_events << ['INFO', msg]
    end

    def debug(msg)
      @expected_events << ['DEBUG', msg]
    end

    def warn(msg)
      @expected_events << ['WARN', msg]
    end

    def error(msg)
      @expected_events << ['ERROR', msg]
    end

    def fatal(msg)
      @expected_events << ['FATAL', msg]
    end

    def unknown(msg)
      @expected_events << ['UNKNOWN', msg]
    end
  end
end

module MiniTest::Assertions
  # use pretty-print to build diffs
  class InspectedString < String
  end

  def mu_pp(obj)
    return obj if obj.is_a?(InspectedString)
    obj.pretty_inspect
  end

  def mu_pp_for_diff(obj)
    mu_pp(obj)
  end

  def assert_log_events(test_logger, &block)
    actual = test_logger.events
    expected = TestLogger::LogExpectationBuilder.new(&block).expected_events

    msg = message('log events mis-match', '') {
      diff(stringify_log(actual), stringify_log(expected))
    }
    assert(actual == expected, msg)
  end

  def assert_json_log_event(test_logger, expected_sev, expected_json)
    actual = test_logger.events

    assert_equal 1, actual.length, 'there should be only one log event'

    actual_sev, actual_json_str = actual.first

    assert_equal "\x1E", actual_json_str[0], 'JSON log entries should begin with an ASCII RS char'

    actual_json = MultiJson.load(actual_json_str[1..-1])
    expected_json = MultiJson.load(MultiJson.dump(expected_json))

    assert_equal expected_sev.to_s.upcase, actual_sev

    diff = HashDiff.diff(actual_json, expected_json)
    assert expected_json == actual_json, "log entries differ: #{diff.awesome_inspect}"
  end

  private

  def stringify_log(events)
    InspectedString.new(
      events.map { |(sev, msg)| '%5s: %s' % [sev, msg] }.join("\n")
    )
  end
end
