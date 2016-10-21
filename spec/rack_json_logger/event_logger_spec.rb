require_relative '../spec_helper'
require 'rack_json_logger/event_logger'

class RackJsonLogger
  describe EventLogger do
    before { Timecop.freeze }
    after { Timecop.return }

    subject { EventLogger.new(Time.now) }

    describe '#build_logger_proxy' do
      let(:logger) {
        subject.build_logger_proxy('log_stream_name')
      }

      specify { assert_instance_of EventLogger::LoggerProxy, logger }

      specify {
        logger.info 'foo'
        Timecop.freeze(Time.now + 0.01)
        logger.fatal 'bar'

        assert_equal [
          EventLogger::LogEvent.new('log_stream_name', 0.00, 'foo', 'INFO',  nil),
          EventLogger::LogEvent.new('log_stream_name', 0.01, 'bar', 'FATAL', nil),
        ], subject.events
      }
    end

    describe '#build_io_proxy' do
      let(:io) {
        subject.build_io_proxy('io_stream_name')
      }

      specify { assert_instance_of EventLogger::IOProxy, io }

      specify {
        io.puts 'foo'
        Timecop.freeze(Time.now + 0.01)
        io << 'bar'

        assert_equal [
          EventLogger::LogEvent.new('io_stream_name', 0.00, 'foo', nil, nil),
          EventLogger::LogEvent.new('io_stream_name', 0.00, "\n",  nil, nil),
          EventLogger::LogEvent.new('io_stream_name', 0.01, 'bar', nil, nil),
        ], subject.events
      }
    end

    describe EventLogger::IOProxy do
      let(:events) { [] }

      subject do
        EventLogger::IOProxy.new do |obj|
          events << obj
        end
      end

      it 'satisfies IO::generic_writable interface while calling the handler for each bit written' do
        subject.print 'foo'
        subject.puts 'foo', 'bar'
        subject.write 'bar'
        subject.putc ?.
        subject.printf '%05.2f', 1.1
        subject << 'asd123'
        subject.write_nonblock 'zxc21'

        assert_equal ['foo', 'foo', "\n", 'bar', "\n", 'bar', '.', '01.10', 'asd123', 'zxc21'], events

        # events stream should match the string value
        assert_equal subject.string, events.join, 'something about the implementation does not look right'
      end
    end

    describe EventLogger::LoggerProxy do
      let(:events) { [] }

      subject do
        EventLogger::LoggerProxy.new do |severity, datetime, progname, msg|
          events << [severity, datetime, progname, msg]
        end
      end

      it 'calls the event_handler for each event logged' do
        subject.info  'foo'
        subject.debug 'bar'
        subject.error('myProg') { 'whiz' }
        subject.fatal 3

        assert_equal(
          [
            ['INFO',  Time.now, nil,      'foo'],
            ['DEBUG', Time.now, nil,      'bar'],
            ['ERROR', Time.now, 'myProg', 'whiz'],
            ['FATAL', Time.now, nil,      '3'],
          ],
          events
        )
      end
    end
  end
end
