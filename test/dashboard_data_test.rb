require_relative "test_helper"

class DashboardDataTest < Minitest::Test
  def setup
    FileUtils.rm_f(CACHE_FILE)
    FileUtils.rm_f(EVENT_JOURNAL_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    $dashboard_data = nil
    $last_successful_update = nil
    $last_refresh_error = nil
    $event_journal = { "next_id" => 1, "events" => [] }
  end

  def base_data(overrides = {})
    {
      "profile" => { "short_name" => "Avery" },
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {},
      "updated_at" => "2026-09-27T12:00:00Z"
    }.merge(overrides)
  end

  def test_fetch_dashboard_data_aggregates_canvas_responses
    requests = []
    responses = lambda do |path|
      requests << path

      case path
      when "/api/v1/users/self/profile"
        { "short_name" => "Avery" }
      when /\/api\/v1\/courses\?/
        [{ "id" => 1, "name" => "Math" }]
      when /graded_submissions/
        [{ "assignment_id" => 10, "score" => 9 }]
      when /missing_submissions/
        [{ "id" => 11, "course_id" => 1, "name" => "Missing work" }]
      when /upcoming_events/
        [
          { "assignment" => { "id" => 10, "course_id" => 1, "name" => "Quiz" } },
          { "assignment" => { "id" => 12, "course_id" => 1, "name" => "Essay" } }
        ]
      when /planner\/items/
        [
          { "plannable_type" => "planner_note", "plannable_id" => 20 },
          { "plannable_type" => "assignment", "plannable_id" => 21 }
        ]
      when /students\/submissions/
        [
          { "assignment_id" => 10, "workflow_state" => "submitted" },
          { "assignment" => { "id" => 12 }, "workflow_state" => "unsubmitted" }
        ]
      else
        raise "Unexpected request: #{path}"
      end
    end

    data = nil
    with_replaced_method(self, :canvas_get, responses) do
      with_replaced_method(self, :canvas_get_all, ->(_path) { [] }) do
        capture_io { data = fetch_dashboard_data }
      end
    end

    assert_equal "Avery", data.dig("profile", "short_name")
    assert_equal({ "1" => "Math" }, data["course_names"])
    assert_equal [20], data["todo"].map { |item| item["plannable_id"] }
    assert_equal %w[10 12], data.dig("submissions", "1").keys
    assert_equal [], data.dig("modules", "1")
    assert_empty data["modules_errors"]

    submission_request = requests.find { |path| path.include?("students/submissions") }
    assert_includes submission_request, "assignment_ids%5B%5D=10"
    assert_includes submission_request, "assignment_ids%5B%5D=12"
  end

  def test_fetch_continues_when_submission_status_is_unavailable
    responses = lambda do |path|
      case path
      when "/api/v1/users/self/profile" then {}
      when /\/api\/v1\/courses\?/ then [{ "id" => 1, "name" => "Math" }]
      when /graded_submissions|missing_submissions/ then []
      when /upcoming_events/
        [{ "assignment" => { "id" => 10, "course_id" => 1 } }]
      when /planner\/items/ then []
      when /students\/submissions/ then raise "temporary failure"
      end
    end

    data = nil
    with_replaced_method(self, :canvas_get, responses) do
      with_replaced_method(self, :canvas_get_all, ->(_path) { [] }) do
        capture_io { data = fetch_dashboard_data }
      end
    end

    assert_equal({}, data.dig("submissions", "1"))
  end

  def test_cache_round_trip_and_invalid_cache_fallback
    expected = base_data

    capture_io { save_cache(expected) }
    cached = nil
    capture_io { cached = load_cache }
    assert_equal expected, cached

    File.write(CACHE_FILE, "invalid")
    capture_io { cached = load_cache }
    assert_nil cached
  end

  def test_refresh_updates_state_cache_and_event_journal
    initial = base_data
    changed = base_data(
      "updated_at" => "2026-09-27T12:10:00Z",
      "missing" => [{ "id" => 10, "course_id" => 1, "name" => "Quiz" }]
    )

    with_replaced_method(self, :fetch_dashboard_data, -> { initial }) do
      capture_io { refresh_dashboard }
    end

    assert_equal initial, dashboard_data
    assert_empty dashboard_events

    with_replaced_method(self, :fetch_dashboard_data, -> { changed }) do
      capture_io { refresh_dashboard }
    end

    cached = nil
    capture_io { cached = load_cache }
    assert_equal changed, cached
    assert_equal ["assignment_missing"], dashboard_events.map { |event| event["type"] }
    assert_nil dashboard_status[:error]
  end

  def test_refresh_publishes_events_after_journal_ids_are_assigned
    $dashboard_data = base_data
    changed = base_data(
      "updated_at" => "2026-09-27T12:10:00Z",
      "missing" => [{ "id" => 10, "course_id" => 1, "name" => "Quiz" }]
    )
    published = nil

    with_replaced_method(self, :fetch_dashboard_data, -> { changed }) do
      with_replaced_method(
        self,
        :publish_home_assistant_events,
        ->(events) { published = deep_copy(events) }
      ) do
        capture_io { refresh_dashboard }
      end
    end

    assert_equal 1, published.length
    assert_equal 1, published.first["id"]
    assert_equal "assignment_missing", published.first["type"]
  end

  def test_refresh_failure_preserves_data_and_records_error
    $dashboard_data = base_data

    with_replaced_method(self, :fetch_dashboard_data, -> { raise "Canvas unavailable" }) do
      capture_io { refresh_dashboard }
    end

    assert_equal "Avery", dashboard_data.dig("profile", "short_name")
    assert_equal "Canvas unavailable", dashboard_status[:error]
  end
end