require_relative "test_helper"

class DailyAutomationTest < Minitest::Test
  def setup
    [DAILY_OVERVIEW_FILE, BACKUP_SETTINGS_FILE, GRADE_OVERRIDES_FILE, MANUAL_COURSEWORK_FILE,
     COURSE_NAME_MAPPINGS_FILE, HIDDEN_COURSES_FILE, SCHOOL_CALENDAR_SETTINGS_FILE].each { |path| FileUtils.rm_f(path) }
    @now = Time.local(2026, 10, 26, 5)
    $school_calendar_cache = nil
    $dashboard_data = {
      "profile" => { "short_name" => "Avery" },
      "updated_at" => (@now - 600).iso8601,
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [], "missing" => [], "upcoming" => [], "submissions" => {}
    }
    save_scheduled_email_settings(empty_scheduled_email_settings.merge("digest_spark_overview" => true))
  end

  def successful_overview
    { "bullets" => ["Check today's Math notes and the current assignment details below."] }
  end

  def prepare_overview(now = @now)
    with_replaced_method(self, :digest_spark_overview, ->(*) { successful_overview }) do
      assert generate_daily_overview(now: now)
    end
  end

  def test_prepares_at_five_once_per_day_and_keeps_persistent_source_metadata
    calls = 0
    with_replaced_method(self, :digest_spark_overview, ->(*) { calls += 1; successful_overview }) do
      refute run_daily_automations(@now - 60)
      refute File.exist?(DAILY_OVERVIEW_FILE)
      assert run_daily_automations(@now)
      refute run_daily_automations(@now + 60)
      refute run_daily_automations(@now + 7200)
    end
    assert_equal 1, calls
    state = load_daily_overview_state
    assert_equal "2026-10-26", state["date"]
    assert_equal 1, state["attempts"]
    assert_equal @now.iso8601, state["generated_at"]
    assert_equal $dashboard_data["updated_at"], state["canvas_updated_at"]
    assert_equal successful_overview["bullets"], daily_overview_for_digest(now: @now + 3600)["bullets"]
    assert_equal 0o600, File.stat(DAILY_OVERVIEW_FILE).mode & 0o777
  end

  def test_catches_up_after_restart_and_does_not_repeat_persisted_attempts
    with_replaced_method(self, :digest_spark_overview, ->(*) { { "error" => "Spark offline" } }) do
      refute run_daily_automations(@now)
      refute run_daily_automations(@now + 60)
      assert_equal 1, load_daily_overview_state["attempts"]
    end
    prepare_overview(@now + 25 * 60)
    assert_equal 2, load_daily_overview_state["attempts"]
    refute run_daily_automations(@now + 3600)
    FileUtils.rm_f(DAILY_OVERVIEW_FILE)
    prepare_overview(@now + 2 * 3600)
  end

  def test_three_failed_attempts_are_spaced_out_and_a_new_day_resets_the_budget
    calls = 0
    with_replaced_method(self, :digest_spark_overview, ->(*) { calls += 1; { "error" => "offline" } }) do
      [0, 60, 1200, 1260, 2400, 3600, 12 * 3600].each { |offset| refute run_daily_automations(@now + offset) }
      assert_equal 3, calls
      assert_equal 3, load_daily_overview_state["attempts"]
      refute run_daily_automations(@now + 24 * 3600)
      assert_equal 4, calls
      assert_equal 1, load_daily_overview_state["attempts"]
    end
  end

  def test_opt_out_never_calls_the_model_and_preserves_existing_digest
    save_scheduled_email_settings(empty_scheduled_email_settings)
    with_replaced_method(self, :digest_spark_overview, ->(*) { flunk "Opt-out triggered AI" }) do
      refute run_daily_automations(@now)
      digest = digest_data(now: @now)
      refute digest.key?("spark_overview")
      refute_includes digest_html_body(digest, @now), "Today at a glance"
      refute_includes digest_text_body(digest, @now), "TODAY AT A GLANCE"
    end
  end

  def test_previous_days_cache_is_not_used_even_before_the_next_generation
    prepare_overview
    next_morning = Time.local(2026, 10, 27, 4)
    overview = daily_overview_for_digest(now: next_morning)
    assert overview["error"]
    refute overview.key?("bullets")
    with_replaced_method(self, :digest_spark_overview, ->(*) { flunk "Preview invoked AI" }) do
      digest = digest_data(now: next_morning)
      assert_includes digest_text_body(digest, next_morning), "Today's Spark overview is not ready"
      assert_includes digest_html_body(digest, next_morning), "Current Grade Snapshot"
    end
  end

  def test_manual_generation_can_run_before_five_and_failure_preserves_valid_cache
    with_replaced_method(self, :digest_spark_overview, ->(*) { successful_overview }) do
      assert generate_daily_overview(now: @now - 3600, force: true)
    end
    with_replaced_method(self, :digest_spark_overview, ->(*) { { "error" => "offline" } }) do
      refute generate_daily_overview(now: @now, force: true)
    end
    assert_equal successful_overview["bullets"], daily_overview_for_digest(now: @now)["bullets"]
  end

  def test_concurrent_generation_does_not_launch_another_model_request
    $daily_overview_generation_mutex.lock
    with_replaced_method(self, :digest_spark_overview, ->(*) { flunk "Concurrent model request" }) do
      refute generate_daily_overview(now: @now, force: true)
      assert $daily_overview_generation_mutex.owned?
    end
  ensure
    $daily_overview_generation_mutex.unlock
  end

  def test_corrupt_or_invalid_cache_shows_a_notice_and_can_be_regenerated_manually
    ['not JSON', '{"date":"2026-10-26","attempts":1,"attempted_at":{}}'].each do |contents|
      File.write(DAILY_OVERVIEW_FILE, contents)
      capture_io do
        assert daily_overview_for_digest(now: @now)["error"]
        with_replaced_method(self, :digest_spark_overview, ->(*) { successful_overview }) do
          assert generate_daily_overview(now: @now, force: true)
        end
      end
    end
  end

  def test_cached_overview_renders_above_grades_safely_and_includes_source_times
    bullets = ["Math <script>alert(1)</script> & review"]
    with_replaced_method(self, :digest_spark_overview, ->(*) { { "bullets" => bullets } }) do
      assert generate_daily_overview(now: @now)
    end
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Rendering invoked AI" }) do
      digest = digest_data(now: @now + 3600)
      html = digest_html_body(digest, @now)
      text = digest_text_body(digest, @now)
      assert_operator html.index("Today at a glance"), :<, html.index("Current Grade Snapshot")
      assert_operator text.index("TODAY AT A GLANCE"), :<, text.index("CURRENT GRADES")
      assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; review"
      refute_includes html, "<script>"
      assert_includes text, bullets.first
      assert_includes html, "Canvas last refreshed"
      assert_includes text, "Prepared Mon Oct 26"
    end
  end

  def test_generation_requests_bounded_structured_output_and_reuses_spark_safeguards
    with_replaced_method(self, :ai_enabled?, -> { true }) do
      request = lambda do |_data, messages, **options|
        assert_equal 15, options[:read_timeout]
        assert_equal 400, options[:max_tokens]
        assert_equal({ "type" => "json_object" }, options[:response_format])
        assert_includes options[:system_prompt], "not from today's next occurrence"
        assert_includes options[:system_prompt], "Attendance is unknown"
        assert_includes options[:system_prompt], "An empty or stale cache does not prove"
        assert_includes options[:system_prompt], "Do not suggest web search"
        assert_includes options[:system_prompt], "Digest details for Monday, October 26, 2026"
        assert_equal "user", messages.first["role"]
        JSON.generate(successful_overview)
      end
      with_replaced_method(self, :ai_ask, request) do
        assert generate_daily_overview(now: @now)
      end
    end
  end

  def test_malformed_empty_and_overlong_output_fail_explicitly
    answers = ["not JSON", "[]", '{"bullets":[]}', '{"bullets":[42]}',
      JSON.generate("bullets" => ["word " * 151]), JSON.generate("bullets" => ["x" * 601])]
    with_replaced_method(self, :ai_enabled?, -> { true }) do
      answers.each do |answer|
        with_replaced_method(self, :ai_ask, ->(*) { answer }) do
          capture_io { assert digest_spark_overview(digest_data(now: @now, include_overview: false), @now)["error"] }
        end
      end
    end
  end

  def test_total_timeout_is_bounded_and_offline_does_not_fail_digest_data
    with_replaced_method(self, :ai_enabled?, -> { true }) do
      timeout = lambda do |seconds, error_class, message, &_block|
        assert_equal 20, seconds
        raise error_class, message
      end
      with_replaced_method(Timeout, :timeout, timeout) do
        capture_io { refute generate_daily_overview(now: @now) }
      end
    end
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Digest invoked AI" }) do
      assert digest_data(now: @now)["spark_overview"]["error"]
    end
  end
end
