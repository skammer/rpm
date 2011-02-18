require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'test_helper'))
class QueueTimeTest < Test::Unit::TestCase
  require 'new_relic/agent/instrumentation/queue_time'
  include NewRelic::Agent::Instrumentation::QueueTime
  
  def setup
    NewRelic::Agent.instance.stats_engine.clear_stats
  end
  
  # test helper method
  def check_metric(metric, value, delta)
    time = NewRelic::Agent.get_stats(metric).total_call_time
    assert_between (value - delta), (value + delta), time, "Metric #{metric} not in expected range: was #{time} but expected in #{value - delta} to #{value + delta}!"
  end

  def create_test_start_time(env)
    env[APP_HEADER] = "t=#{convert_to_microseconds(Time.at(1002))}"
  end

  def test_combined_middleware_and_server
    return # incomplete, ignoring for this branch
    env = {}
    env[MAIN_HEADER] = "t=#{convert_to_microseconds(Time.at(1000))}"
    env[MIDDLEWARE_HEADER] = "t=#{convert_to_microseconds(Time.at(1001))}"
    # this should also include queue time
    create_test_start_time(env)

    assert_calls_metrics('WebFrontend/WebServer/all', 'Middleware/all') do
      parse_server_time_from(env)
      parse_middleware_time_from(env)
    end
    
    check_metric('WebFrontend/WebServer/all', 1.0, 0.001)
    check_metric('Middleware/all', 1.0, 0.001)
  end

  # initial base case, a router and a static content server
  def test_parse_server_time_from_initial
    env = {}
    create_test_start_time(env)
    time1 = convert_to_microseconds(Time.at(1000))
    time2 = convert_to_microseconds(Time.at(1001))
    env['HTTP_X_REQUEST_START'] = "servera t=#{time1}, serverb t=#{time2}"
    assert_calls_metrics('WebFrontend/WebServer/all', 'WebFrontend/WebServer/servera', 'WebFrontend/WebServer/serverb') do
      parse_server_time_from(env)
    end
    check_metric('WebFrontend/WebServer/all', 2.0, 0.1)
    check_metric('WebFrontend/WebServer/servera', 1.0, 0.1)
    check_metric('WebFrontend/WebServer/serverb', 1.0, 0.1)
  end

  # test for backwards compatibility with old header
  def test_parse_server_time_from_with_no_server_name
    env = {'HTTP_X_REQUEST_START' => "t=#{convert_to_microseconds(Time.at(1001))}"}
    create_test_start_time(env)
    assert_calls_metrics('WebFrontend/WebServer/all') do
      parse_server_time_from(env)
    end
    check_metric('WebFrontend/WebServer/all', 1.0, 0.1)
  end

  def test_parse_server_time_from_with_no_header
    assert_calls_metrics('WebFrontend/WebServer/all') do
      parse_server_time_from({})
    end
  end
  
  def test_parse_middleware_time
    env = {}
    create_test_start_time(env)
    time1 = convert_to_microseconds(Time.at(1000))
    time2 = convert_to_microseconds(Time.at(1001))

    env['HTTP_X_MIDDLEWARE_START'] = "base t=#{time1}, second t=#{time2}"
    assert_calls_metrics('Middleware/all', 'Middleware/base', 'Middleware/second') do
      parse_middleware_time_from(env)
    end
    check_metric('Middleware/all', 2.0, 0.1)
    check_metric('Middleware/base', 1.0, 0.1)
    check_metric('Middleware/second', 1.0, 0.1)
  end

  # each server should be one second, and the total would be 2 seconds
  def test_record_individual_server_stats
    matches = [['foo', Time.at(1000)], ['bar', Time.at(1001)]]
    assert_calls_metrics('WebFrontend/WebServer/foo', 'WebFrontend/WebServer/bar') do
      record_individual_server_stats(Time.at(1002), matches)
    end
    check_metric('WebFrontend/WebServer/foo', 1.0, 0.1)
    check_metric('WebFrontend/WebServer/bar', 1.0, 0.1)
  end

  def test_record_rollup_server_stat
    assert_calls_metrics('WebFrontend/WebServer/all') do
      record_rollup_server_stat(Time.at(1001), [['a', Time.at(1000)]])
    end
    check_metric('WebFrontend/WebServer/all', 1.0, 0.1)
  end

  def test_record_rollup_server_stat_no_data
    assert_calls_metrics('WebFrontend/WebServer/all') do
      record_rollup_server_stat(Time.at(1001), [])
    end
    check_metric('WebFrontend/WebServer/all', 0.0, 0.001)
  end

  def test_record_rollup_middleware_stat
    assert_calls_metrics('Middleware/all') do
      record_rollup_middleware_stat(Time.at(1001), [['a', Time.at(1000)]])
    end
    check_metric('Middleware/all', 1.0, 0.1)
  end

  def test_record_rollup_middleware_stat_no_data
    assert_calls_metrics('Middleware/all') do
      record_rollup_middleware_stat(Time.at(1001), [])
    end
    check_metric('Middleware/all', 0.0, 0.001)
  end
  
  
  # check all the combinations to make sure that ordering doesn't
  # affect the return value
  def test_find_oldest_time
    test_arrays = [
                   ['a', Time.at(1000)],
                   ['b', Time.at(1001)],
                   ['c', Time.at(1002)],
                   ['d', Time.at(1000)],
                  ]
    test_arrays = test_arrays.permutation
    test_arrays.each do |test_array|
      assert_equal find_oldest_time(test_array), Time.at(1000), "Should be the oldest time in the array"
    end
  end

  # trivial test but the method doesn't do much
  def test_record_server_time_for
    name = 'foo'
    time = Time.at(1000)
    start_time = Time.at(1001)
    self.expects(:record_time_stat).with('WebFrontend/WebServer/foo', time, start_time)
    record_server_time_for(name, time, start_time)
  end

  def test_record_time_stat
    assert_calls_metrics('WebFrontend/WebServer/foo') do
      record_time_stat('WebFrontend/WebServer/foo', Time.at(1000), Time.at(1001))
    end
    check_metric('WebFrontend/WebServer/foo', 1.0, 0.1)
    assert_raises(RuntimeError) do
      record_time_stat('foo', Time.at(1001), Time.at(1000))
    end
  end

  def test_convert_to_microseconds
    assert_equal((1_000_000_000), convert_to_microseconds(Time.at(1000)), 'time at 1000 seconds past epoch should be 1,000,000,000 usec')
    assert_equal 1_000_000_000, convert_to_microseconds(1_000_000_000), 'should not mess with a number if passed in'
    assert_raises(TypeError) do
      convert_to_microseconds('whoo yeah buddy')
    end
  end

  def test_convert_from_microseconds
    assert_equal Time.at(1000), convert_from_microseconds(1_000_000_000), 'time at 1,000,000,000 usec should be 1000 seconds after epoch'
    assert_equal Time.at(1000), convert_from_microseconds(Time.at(1000)), 'should not mess with a time passed in'
    assert_raises(TypeError) do
      convert_from_microseconds('10000000000')
    end
  end

  def test_add_end_time_header
    env = {}
    start_time = Time.at(1)
    add_end_time_header(start_time, env)
    assert_equal({'HTTP_X_APPLICATION_START' => "t=#{convert_to_microseconds(Time.at(1))}"}, env, "should add the header to the env hash")
  end

  def test_parse_end_time_base
    env = {}
    env['HTTP_X_APPLICATION_START'] = "t=#{convert_to_microseconds(Time.at(1))}"
    start_time = parse_end_time(env)
    assert_equal(Time.at(1), start_time, "should pull the correct start time from the app header")
  end

  def test_get_matches_from_header
    env = {'A HEADER' => 't=1000000'}
    self.expects(:convert_from_microseconds).with(1000000).returns(Time.at(1))
    matches = get_matches_from_header('A HEADER', env)
    assert_equal [[nil, Time.at(1)]], matches, "should pull the correct time from the string"
  end

  def test_convert_to_name_time_pair
    name = :foo
    time = "1000000"

    pair = convert_to_name_time_pair(name, time)
    assert_equal [:foo, Time.at(1)], pair
  end
  
  def test_get_matches
    str = "servera t=1000000, serverb t=1000000"
    matches = get_matches(str) # start a fire
    assert_equal [['servera', '1000000'], ['serverb', '1000000']], matches
  end

  def test_matches_with_bad_data
    str = "stephan is a dumb lol"
    matches = get_matches(str)
    assert_equal [], matches

    str = "t=100"
    matches = get_matches(str)
    assert_equal [[nil, '100']], matches

    str = nil
    matches = get_matches(str)
    assert_equal [], matches
  end
  # each server should be one second, and the total would be 2 seconds
  def test_record_individual_middleware_stats
    matches = [['foo', Time.at(1000)], ['bar', Time.at(1001)]]
    assert_calls_metrics('Middleware/foo', 'Middleware/bar') do
      record_individual_middleware_stats(Time.at(1002), matches)
    end
    check_metric('Middleware/foo', 1.0, 0.1)
    check_metric('Middleware/bar', 1.0, 0.1)
  end
end
