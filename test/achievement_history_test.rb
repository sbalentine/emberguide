require_relative "test_helper"

class AchievementHistoryTest < Minitest::Test
  def setup
    FileUtils.rm_f(ACHIEVEMENT_HISTORY_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)
  end

  def submission(
    id:,
    due_at:,
    score:,
    points_possible: 10,
    late: false,
    missing: false
  )
    {
      "assignment_id" => id,
      "workflow_state" => "graded",
      "submitted_at" => (due_at - 3600).iso8601,
      "graded_at" => due_at.iso8601,
      "score" => score,
      "late" => late,
      "missing" => missing,
      "assignment" => {
        "id" => id,
        "name" => "Assignment #{id}",
        "due_at" => due_at.iso8601,
        "points_possible" => points_possible,
        "omit_from_final_grade" => false
      }
    }
  end

  def test_assignment_and_score_streaks_stop_at_first_break
    now = Time.new(2026, 10, 15, 12, 0, 0, "UTC")
    data = {
      "grades" => [
        submission(id: 1, due_at: now - 86_400, score: 10),
        submission(id: 2, due_at: now - 172_800, score: 9),
        submission(id: 3, due_at: now - 259_200, score: 8, late: true),
        submission(id: 4, due_at: now - 345_600, score: 10)
      ]
    }

    assert_equal 2, on_time_assignment_streak(data)
    assert_equal 4, strong_score_streak(data)
    assert_equal 2, strong_score_streak(data, threshold: 90)
  end

  def test_strong_score_streak_includes_future_graded_records
    now = Time.new(2026, 10, 15, 12, 0, 0, "UTC")
    future_placeholder = submission(
      id: 1,
      due_at: now + 86_400,
      score: 0
    )
    future_placeholder["submitted_at"] = nil
    recent_score = submission(
      id: 2,
      due_at: now - 86_400,
      score: 9
    )
    assert_equal(
      0,
      strong_score_streak(
        { "grades" => [future_placeholder, recent_score] }
      )
    )
  end

  def test_no_missing_streak_skips_weekends_and_stops_at_missing_day
    history = {
      "daily_missing_counts" => {
        "2026-10-09" => 1,
        "2026-10-12" => 0,
        "2026-10-13" => 0,
        "2026-10-14" => 0,
        "2026-10-15" => 0
      }
    }

    assert_equal(
      4,
      no_missing_school_day_streak(
        history,
        date: Date.new(2026, 10, 15)
      )
    )
  end

  def test_record_achievement_day_persists_missing_count
    history = record_achievement_day(
      { "missing" => [{ "id" => 1 }, { "id" => 2 }] },
      date: Date.new(2026, 10, 15)
    )

    assert_equal 2, history["daily_missing_counts"]["2026-10-15"]
    assert_equal(
      2,
      load_achievement_history["daily_missing_counts"]["2026-10-15"]
    )
  end

  def test_achievement_settings_default_to_80_and_can_be_changed
    assert_equal 80,
      load_achievement_settings["strong_score_threshold"]

    save_achievement_settings("85")

    assert_equal 85,
      load_achievement_settings["strong_score_threshold"]
    assert_equal "2026-08-12",
      load_achievement_settings["school_year_start"]
    assert_equal "2027-06-04",
      load_achievement_settings["school_year_end"]
    assert_raises(ArgumentError) do
      save_achievement_settings("101")
    end
    assert_raises(ArgumentError) do
      save_achievement_settings(
        "80",
        school_year_start: "2027-06-04",
        school_year_end: "2026-08-12"
      )
    end
  end

  def test_school_year_progress_counts_weekdays_before_today
    progress = school_year_progress(
      Date.new(2026, 8, 12),
      Date.new(2026, 8, 18),
      date: Date.new(2026, 8, 17)
    )

    assert_equal(
      { "completed" => 3, "remaining" => 2, "total" => 5, "excluded_days" => [] },
      progress
    )
  end

  def badge_progress(streak: 0, assignments: 0, completed: 0, total: 100)
    record_achievement_badges(
      { "on_time" => streak, "no_missing" => streak, "strong_scores" => streak },
      {
        "graded_assignments" => assignments,
        "school_year" => { "completed" => completed, "total" => total }
      },
      date: Date.new(2026, 10, 15)
    )
  end

  def test_badge_collection_has_exact_goals_and_unique_names
    groups = badge_progress
    assert_equal 20, groups.sum { |group| group["badges"].length }
    assert_equal 20, groups.flat_map { |group| group["badges"].map { |badge| badge["name"] } }.uniq.length
    assert_equal(
      [[5, 10, 25, 50], [5, 10, 20, 30], [5, 10, 20, 30], [25, 50, 100, 200], [25, 50, 75, 100]],
      groups.map { |group| group["goals"] }
    )
    assert groups.all? { |group| group["badges"].all? { |badge| badge["earned_on"].nil? } }
  end

  def test_badges_unlock_at_threshold_and_survive_resets_and_daily_snapshots
    groups = badge_progress(streak: 10, assignments: 50, completed: 25)
    assert_equal 9, groups.sum { |group| group["badges"].count { |badge| badge["earned_on"] } }
    earned = load_achievement_history["earned_badges"]
    assert_equal "2026-10-15", earned["school_year-25"]
    record_achievement_day({ "missing" => [] }, date: Date.new(2026, 10, 16))
    badge_progress
    assert_equal earned, load_achievement_history["earned_badges"]
  end

  def test_year_badges_use_exact_percentage_not_rounded_display
    groups = badge_progress(completed: 49, total: 200)
    assert_nil groups.last["badges"].first["earned_on"]
    groups = badge_progress(completed: 50, total: 200)
    assert groups.last["badges"].first["earned_on"]
    assert_nil groups.last["badges"][1]["earned_on"]
    groups = badge_progress(completed: 0, total: 0)
    assert_nil groups.last["badges"].last["earned_on"]
    groups = badge_progress(completed: 200, total: 200)
    assert groups.last["badges"].all? { |badge| badge["earned_on"] }
  end

  def test_legacy_history_defaults_to_empty_badge_collection
    File.write(ACHIEVEMENT_HISTORY_FILE, JSON.generate("daily_missing_counts" => {}))
    assert_equal({}, load_achievement_history["earned_badges"])
    assert_raises(ArgumentError) { validated_earned_badges("invalid") }
    assert_raises(ArgumentError) { validated_earned_badges("badge" => "2026-02-30") }
  end

  def calendar_event(title, first, last = first)
    {
      "title" => title,
      "start_date" => Date.iso8601(first),
      "end_date" => Date.iso8601(last)
    }
  end

  def test_closures_are_distinct_from_shortened_days_and_unrelated_events
    [
      "No School", "School Closed", "District Closed", "Non-Student Day",
      "Staff Development Day", "Teacher Workday", "Winter Break",
      "Spring Recess", "Fall Break", "Labor Day", "Veterans Day (Observed)"
    ].each do |title|
      assert no_school_calendar_event?({ "title" => title }), title
    end

    [
      "Minimum Day", "Early Release", "Late Start", "Modified Schedule",
      "Holiday Concert", "Lunch Break", "Board Meeting"
    ].each do |title|
      refute no_school_calendar_event?({ "title" => title }), title
    end
    refute no_school_calendar_event?(
      "title" => "Assembly", "description" => "Discuss winter break"
    )
  end

  def test_calendar_closures_expand_clip_and_deduplicate
    first = Date.new(2026, 10, 12)
    last = Date.new(2026, 10, 23)
    events = [
      calendar_event("Fall Break", "2026-10-09", "2026-10-14"),
      calendar_event("No School", "2026-10-14"),
      calendar_event("Early Release", "2026-10-15"),
      calendar_event("Winter Break", "2026-10-23", "2026-11-02")
    ]

    progress = school_year_progress(
      first, last, date: Date.new(2026, 10, 16), events: events
    )

    assert_equal 6, progress["total"]
    assert_equal 1, progress["completed"]
    assert_equal 5, progress["remaining"]
    assert_equal(
      %w[2026-10-12 2026-10-13 2026-10-14 2026-10-23],
      progress["excluded_days"].map { |day| day["date"].iso8601 }
    )
    assert_equal ["Fall Break", "No School"], progress["excluded_days"][2]["reasons"]
  end

  def test_manual_overrides_take_priority_and_allow_makeup_weekends
    progress = school_year_progress(
      Date.new(2026, 10, 12), Date.new(2026, 10, 18),
      date: Date.new(2026, 10, 17),
      events: [calendar_event("Fall Break", "2026-10-12", "2026-10-16")],
      overrides: {
        "2026-10-14" => "school",
        "2026-10-16" => "no_school",
        "2026-10-17" => "school"
      }
    )

    assert_equal 2, progress["total"]
    assert_equal 1, progress["completed"]
    assert_equal 1, progress["remaining"]
    assert_equal ["Manual no-school override"], progress["excluded_days"].last["reasons"]
  end

  def test_progress_handles_before_after_and_zero_school_days
    first = Date.new(2026, 10, 12)
    last = Date.new(2026, 10, 16)
    assert_equal 0, school_year_progress(first, last, date: first - 1)["completed"]
    assert_equal 0, school_year_progress(first, last, date: last + 1)["remaining"]
    progress = school_year_progress(
      first, last, events: [calendar_event("Fall Break", first.iso8601, last.iso8601)]
    )
    assert_equal [0, 0, 0], progress.values_at("completed", "remaining", "total")
  end

  def test_override_settings_round_trip_validation_and_legacy_defaults
    overrides = achievement_school_day_override_fields(
      "2026-10-16,\n2026-10-19", "2026-10-17"
    )
    save_achievement_settings(80, school_day_overrides: overrides)
    assert_equal overrides, load_achievement_settings["school_day_overrides"]
    assert_raises(ArgumentError) do
      achievement_school_day_override_fields("2026-10-16", "2026-10-16")
    end
    [
      { "2026-02-30" => "school" },
      { "2026-10-16" => "invalid" },
      { "2028-10-16" => "school" },
      { "20261016" => "school" },
      []
    ].each do |invalid|
      assert_raises(ArgumentError) do
        save_achievement_settings(80, school_day_overrides: invalid)
      end
    end
    assert_equal overrides, load_achievement_settings["school_day_overrides"]
    File.write(ACHIEVEMENT_SETTINGS_FILE, JSON.generate("strong_score_threshold" => 85))
    assert_equal({}, load_achievement_settings["school_day_overrides"])
    assert_equal 85, load_achievement_settings["strong_score_threshold"]
  end

  def test_calendar_progress_labels_feed_availability_and_coverage
    settings = empty_achievement_settings
    {
      not_configured: "no calendar connected",
      unavailable: "calendar unavailable",
      stale: "older calendar data",
      fresh: "does not span the full school year"
    }.each do |status, message|
      with_replaced_method(self, :school_calendar_snapshot, -> { { events: [], status: status } }) do
        assert_includes school_year_calendar_progress(settings)["status"], message
      end

      def test_no_school_labels_validate_and_round_trip_without_changing_counts
        text = "2026-09-07 | Labor Day\n2026-10-16, 2026-10-19"
        entries = achievement_no_school_entries(text)
        labels = entries.reject { |_day, label| label.empty? }
        overrides = achievement_school_day_override_fields(text, "2026-10-17")
        save_achievement_settings(80, school_day_overrides: overrides, no_school_labels: labels)
        assert_equal({ "2026-09-07" => "Labor Day" }, load_achievement_settings["no_school_labels"])
        progress = school_year_progress(
          Date.new(2026, 9, 7), Date.new(2026, 9, 11),
          overrides: overrides, no_school_labels: labels
        )
        assert_equal 4, progress["total"]
        assert_equal ["Labor Day"], progress["excluded_days"].first["reasons"]
        [
          [], { "2026-10-17" => "School day" }, { "2026-09-07" => 42 },
          { "2026-09-07" => " " }, { "2026-09-07" => "x" * 121 },
          { "2026-09-07" => "a\nb" }, { "2026-09-07" => "a|b" }
        ].each do |invalid|
          assert_raises(ArgumentError) do
            save_achievement_settings(80, school_day_overrides: overrides, no_school_labels: invalid)
          end
          assert_equal labels, load_achievement_settings["no_school_labels"]
        end
        assert_raises(ArgumentError) do
          achievement_no_school_entries("2026-09-07 | Labor Day\n2026-09-07 | Other")
        end
        assert_raises(ArgumentError) do
          achievement_no_school_entries("2026-09-07, 2026-10-16 | Holiday")
        end
        File.write(ACHIEVEMENT_SETTINGS_FILE, JSON.generate("strong_score_threshold" => 80))
        assert_equal({}, load_achievement_settings["no_school_labels"])
      end
    end
    events = [
      calendar_event("First Day", "2026-08-12"),
      calendar_event("Last Day", "2027-06-04")
    ]
    with_replaced_method(self, :school_calendar_snapshot, -> { { events: events, status: :fresh } }) do
      assert_includes school_year_calendar_progress(settings)["status"], "may omit"
    end
  end
end
