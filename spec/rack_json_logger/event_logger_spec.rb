require_relative '../spec_helper'
require 'rack_json_logger/event_logger'

class RackJsonLogger
  describe EventLogger do
    let(:attach_event_logger) { true }
    let(:event_logger) { EventLogger.new(Time.now) }
    subject { event_logger }

    before do
      Timecop.freeze

      Thread.current[:rack_json_logs_event_handler] = event_logger if attach_event_logger
    end

    after do
      Timecop.return

      Thread.current[:rack_json_logs_event_handler] = nil if attach_event_logger
    end

    describe '#add_logger_event' do
      it 'builds a LogEvent and adds it to the events list, calculating its time-offset from the EventLogger.start_time' do
        Timecop.freeze(Time.now + 2.1)
        event_logger.add_logger_event('my-stream', 'INFO', Time.now, 'some-prog', 'foo')

        assert_equal [EventLogger::LogEvent.new('my-stream', 2.1, 'foo', 'INFO', 'some-prog')], event_logger.events
      end
    end

    describe '#add_io_event' do
      it 'builds a LogEvent and adds it to the events list, calculating its time-offset from the EventLogger.start_time' do
        Timecop.freeze(Time.now + 1.3)
        event_logger.add_io_event('my-stream', 'foo bar')

        assert_equal [EventLogger::LogEvent.new('my-stream', 1.3, 'foo bar')], event_logger.events
      end
    end

    describe 'LogEvent' do
      describe '#to_json' do
        specify {
          e = EventLogger::LogEvent.new('my-stream', 0.01, 'foo bar', 'DEBUG', 'prog1')
          assert_equal(
            {
              stream: 'my-stream',
              time: 0.01,
              body: 'foo bar',
              severity: 'DEBUG',
              progname: 'prog1',
            },
            e.as_json
          )
          assert_equal('{"stream":"my-stream","time":0.01,"body":"foo bar","severity":"DEBUG","progname":"prog1"}', e.to_json)
        }
      end
    end

    describe 'IOProxy' do
      let(:io) { StringIO.new }
      let(:io_proxy) { EventLogger::IOProxy.new(io, 'io_stream_name') }
      subject { io_proxy }

      before do
        subject.print 'foo'
        subject.puts 'foo', 'bar'
        subject.write 'bar'
        subject.putc ?.
        subject.printf '%05.2f', 1.1
        subject << 'asd123'
        subject.write_nonblock 'zxc21'
      end

      describe 'when the EventLogger is registered' do
        it 'does not write to the underlying io object' do
          assert_equal '', io.string, 'it should not be writing to the underlying IO object'
        end

        it 'results in correct LogEvent objects being added to the Thread-local EventLogger' do
          assert_equal [
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'foo',    nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'foo',    nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, "\n",     nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'bar',    nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, "\n",     nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'bar',    nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, '.',      nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, '01.10',  nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'asd123', nil, nil),
            EventLogger::LogEvent.new('io_stream_name', 0.0, 'zxc21',  nil, nil),
          ], event_logger.events
        end
      end

      describe 'when the EventLogger is NOT registered' do
        let(:attach_event_logger) { false }

        it 'writes to the underlying io object' do
          assert_equal "foofoo\nbar\nbar.01.10asd123zxc21", io.string
        end
      end
    end

    describe 'LoggerProxy' do
      let(:stringio) { StringIO.new }
      let(:logger) { Logger.new(stringio) }
      let(:logger_proxy) { EventLogger::LoggerProxy.wrap(logger, 'my stream') }
      subject { logger_proxy }

      before {
        subject.info 'foo'
        Timecop.freeze(Time.now + 0.1)
        subject.debug 'bar'
        Timecop.freeze(Time.now + 0.1)
        subject.error('myProg') { 'whiz' }
        Timecop.freeze(Time.now + 0.1)
        subject.fatal 3
      }

      describe 'when the EventLogger is registered' do
        it 'does not write to the underlying IO object' do
          assert_equal '', stringio.string
        end

        it 'calls the event_handler for each event logged' do
          assert_equal(
            [
              EventLogger::LogEvent.new('my stream', 0.0, 'foo',  'INFO',  nil),
              EventLogger::LogEvent.new('my stream', 0.1, 'bar',  'DEBUG', nil),
              EventLogger::LogEvent.new('my stream', 0.2, 'whiz', 'ERROR', 'myProg'),
              EventLogger::LogEvent.new('my stream', 0.3, 3,      'FATAL', nil),
            ],
            event_logger.events
          )
        end
      end

      describe 'when the EventLogger is NOT registered' do
        let(:attach_event_logger) { false }
        let(:logger) {
          Logger.new(stringio).tap { |l|
            l.formatter = -> (sev, _datetime, progname, msg) {
              [sev, progname, msg].join(?:) << "\n"
            }
          }
        }

        it 'writes to the underlying io object' do
          assert_equal <<-EOF.gsub(/^\s+/, ''), stringio.string
            INFO::foo
            DEBUG::bar
            ERROR:myProg:whiz
            FATAL::3
          EOF
        end
      end
    end
  end
end
