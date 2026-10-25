require_relative "test_helper"

class SchoolCalendarTest < Minitest::Test
  def setup
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)
    $school_calendar_cache = nil
  end

  def teardown
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)
    $school_calendar_cache = nil
  end

  def test_manual_no_school_events_merge_with_feed_and_remain_in_schedule_changes
    save_achievement_settings(
      80, school_day_overrides: { "2026-10-16" => "no_school" },
      no_school_labels: { "2026-10-16" => "Family day" }
    )
    with_replaced_method(self, :school_calendar_snapshot, ->(**_args) {
      { events: parse_school_calendar(calendar_body), status: :fresh }
    }) do
      events = school_calendar_events
      assert_equal ["Minimum Day", "Family day", "Fall Break", "Board Meeting"], events.map { |event| event["title"] }
      assert_equal Date.new(2026, 10, 16), events[1]["end_date"]
      changes = upcoming_schedule_changes(events, today: Date.new(2026, 10, 14))
      assert_includes changes.map { |event| event["title"] }, "Family day"
    end
  end

  def calendar_body
    <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART;VALUE=DATE:20261014
      DTEND;VALUE=DATE:20261015
      SUMMARY:Minimum Day
      DESCRIPTION:Modified schedule\\nDismissal at noon
      END:VEVENT
      BEGIN:VEVENT
      DTSTART;VALUE=DATE:20261019
      DTEND;VALUE=DATE:20261024
      SUMMARY:Fall Break
      LOCATION:All schools
      END:VEVENT
      BEGIN:VEVENT
      DTSTART:20261201T170000Z
      SUMMARY:Board Meeting
      DESCRIPTION:District office
      END:VEVENT
      END:VCALENDAR
    ICS
  end

  def test_settings_round_trip_and_validation
    expected = "https://calendar.example.test/events.ics?feed=private"

    save_school_calendar_settings(expected, "Elementary\nHigh School")

    assert_equal expected, load_school_calendar_settings["feed_url"]
    assert_equal(
      ["Elementary", "High School"],
      load_school_calendar_settings["excluded_keywords"]
    )
    assert_raises(ArgumentError) do
      save_school_calendar_settings("file:///private/calendar.ics")
    end
  end

  def test_parses_all_day_multi_day_and_timed_events
    events = parse_school_calendar(calendar_body)

    assert_equal ["Minimum Day", "Fall Break", "Board Meeting"], events.map { |event| event["title"] }
    assert_equal Date.new(2026, 10, 14), events[0]["start_date"]
    assert_equal "Modified schedule\nDismissal at noon", events[0]["description"]
    assert_equal Date.new(2026, 10, 23), events[1]["end_date"]
    assert_equal "All schools", events[1]["location"]
  end

  def test_expands_daily_and_monthly_recurring_events
    body = <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART;TZID=America/Los_Angeles:20261015T080000
      DTEND;TZID=America/Los_Angeles:20261015T121000
      RRULE:FREQ=DAILY;UNTIL=20261016T191000Z;INTERVAL=1
      SUMMARY:Middle School Modified Day
      END:VEVENT
      BEGIN:VEVENT
      DTSTART;VALUE=DATE:20261013
      DTEND;VALUE=DATE:20261014
      RRULE:FREQ=MONTHLY;COUNT=3;BYDAY=2TU
      SUMMARY:Board Meeting
      END:VEVENT
      END:VCALENDAR
    ICS

    events = parse_school_calendar(body)

    assert_equal(
      [
        ["Board Meeting", Date.new(2026, 10, 13)],
        ["Middle School Modified Day", Date.new(2026, 10, 15)],
        ["Middle School Modified Day", Date.new(2026, 10, 16)],
        ["Board Meeting", Date.new(2026, 11, 10)],
        ["Board Meeting", Date.new(2026, 12, 8)]
      ],
      events.map { |event| [event["title"], event["start_date"]] }
    )
  end

  def test_filters_upcoming_dates_and_schedule_changes
    events = parse_school_calendar(calendar_body)
    events << {
      "title" => "Middle School Modified Day",
      "description" => "",
      "location" => "",
      "start_date" => Date.new(2026, 10, 13),
      "end_date" => Date.new(2026, 10, 13)
    }
    events.sort_by! { |event| event["start_date"] }
    today = Date.new(2026, 10, 12)

    upcoming = upcoming_school_calendar_events(events, today: today)
    changes = upcoming_schedule_changes(events, today: today)

    assert_equal(
      ["Middle School Modified Day", "Minimum Day", "Fall Break"],
      upcoming.map { |event| event["title"] }
    )
    assert_equal(
      ["Middle School Modified Day", "Minimum Day", "Fall Break"],
      changes.map { |event| event["title"] }
    )
  end

  def test_excluded_keywords_filter_title_description_and_location
    events = parse_school_calendar(calendar_body)

    assert_equal(
      ["Minimum Day", "Board Meeting"],
      filter_school_calendar_events(events, ["fall"])
        .map { |event| event["title"] }
    )
    assert_equal(
      ["Minimum Day", "Fall Break"],
      filter_school_calendar_events(events, ["district office"])
        .map { |event| event["title"] }
    )
    assert_equal(
      ["Minimum Day", "Board Meeting"],
      filter_school_calendar_events(events, ["ALL SCHOOLS"])
        .map { |event| event["title"] }
    )
  end

  def test_upcoming_dates_default_to_three_events_within_thirty_days
    events = (1..5).map do |offset|
      {
        "title" => "Event #{offset}",
        "description" => "",
        "location" => "",
        "start_date" => Date.new(2026, 10, 12) + (offset * 5),
        "end_date" => Date.new(2026, 10, 12) + (offset * 5)
      }
    end

    upcoming = upcoming_school_calendar_events(
      events,
      today: Date.new(2026, 10, 12)
    )

    assert_equal ["Event 1", "Event 2", "Event 3"], upcoming.map { |event| event["title"] }
    assert_equal(
      ["Event 1", "Event 2", "Event 3", "Event 4", "Event 5"],
      upcoming_school_calendar_events(
        events,
        today: Date.new(2026, 10, 12),
        limit: nil
      ).map { |event| event["title"] }
    )
  end

  def test_uses_cached_events_when_refresh_fails
    save_school_calendar_settings("https://calendar.example.test/events.ics")
    calls = 0
    fetcher = lambda do |_url|
      calls += 1
      raise "offline" if calls > 1

      calendar_body
    end

    first = nil
    second = nil
    with_replaced_method(self, :fetch_school_calendar, fetcher) do
      first = school_calendar_events(now: Time.local(2026, 10, 12), force: true)
      capture_io do
        second = school_calendar_events(now: Time.local(2026, 10, 12, 1), force: true)
      end
    end

    assert_equal first, second
  end

  def test_raw_snapshot_is_independent_of_display_filters
    save_school_calendar_settings("https://calendar.example.test/events.ics", "Fall Break")
    with_replaced_method(self, :fetch_school_calendar, ->(_url) { calendar_body }) do
      snapshot = school_calendar_snapshot
      assert_equal :fresh, snapshot[:status]
      assert_includes snapshot[:events].map { |event| event["title"] }, "Fall Break"
      refute_includes school_calendar_events.map { |event| event["title"] }, "Fall Break"
    end
  end

  def test_snapshot_exposes_missing_unavailable_and_stale_states
    assert_equal :not_configured, school_calendar_snapshot[:status]
    save_school_calendar_settings("https://calendar.example.test/events.ics")
    with_replaced_method(self, :fetch_school_calendar, ->(_url) { raise "offline" }) do
      capture_io do
        assert_equal :unavailable, school_calendar_snapshot[:status]
      end
    end
    now = Time.local(2026, 10, 12)
    with_replaced_method(self, :fetch_school_calendar, ->(_url) { calendar_body }) do
      school_calendar_snapshot(now: now)
    end
    with_replaced_method(self, :fetch_school_calendar, ->(_url) { raise "offline" }) do
      capture_io do
        snapshot = school_calendar_snapshot(now: now + SCHOOL_CALENDAR_CACHE_SECONDS + 1)
        assert_equal :stale, snapshot[:status]
        assert_equal 3, snapshot[:events].length
      end
    end
  end
end
