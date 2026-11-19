require_relative "ai_assistant_test"

class GradeClassificationTest < Minitest::Test
  def setup
    @saved_env = ENV.to_h.slice("LLM_URL", "LLM_API_KEY")
    %w[LLM_URL LLM_API_KEY].each { |key| ENV.delete(key) }
    @saved_dashboard = $dashboard_data
    @saved_update = $last_successful_update
    @saved_error = $last_refresh_error
    @files = [SPARK_SETTINGS_FILE, GRADE_OVERRIDES_FILE, HIDDEN_COURSES_FILE, MANUAL_COURSEWORK_FILE]
    @files.each { |file| FileUtils.rm_f(file) }
    $ai_default_model = nil
  end

  def teardown
    @fake&.stop
    @files.each { |file| FileUtils.rm_f(file) }
    %w[LLM_URL LLM_API_KEY].each { |key| ENV.delete(key) }
    ENV.update(@saved_env)
    $dashboard_data = @saved_dashboard
    $last_successful_update = @saved_update
    $last_refresh_error = @saved_error
    $ai_default_model = nil
  end

  def grade(id, name, course: 1, score: 8, points: 10, excluded: false)
    {
      "assignment_id" => id, "score" => score,
      "assignment" => {
        "id" => id, "course_id" => course, "name" => name,
        "points_possible" => points, "omit_from_final_grade" => excluded
      }
    }
  end

  def prepare_classification
    update_spark_settings { |settings| settings["auto_classify_grades"] = true }
    save_grade_overrides(
      "canvas" => { "13" => { "hidden" => true } },
      "custom" => {
        "paper" => { "course_id" => "1", "name" => "Paper worksheet", "score" => 9, "points_possible" => 10, "graded_at" => "2026-10-01" }
      },
      "grading" => {
        "1" => {
          "mode" => "weighted", "categories" => { "work" => { "name" => "Classwork", "weight" => 40 }, "quiz" => { "name" => "Quizzes", "weight" => 35 } },
          "assignments" => { "canvas-10" => "work" }
        },
        "3" => {
          "mode" => "weighted", "categories" => { "other" => { "name" => "Hidden category", "weight" => 100 } }, "assignments" => {}
        }
      }
    )
    save_hidden_course_ids(["3"])
    {
      "profile" => { "short_name" => "Private Student" },
      "courses" => [{ "id" => 1, "name" => "Math" }, { "id" => 2, "name" => "Points class" }, { "id" => 3, "name" => "Hidden class" }],
      "course_names" => { "1" => "Math", "2" => "Points class", "3" => "Hidden class" },
      "grades" => [
        grade(10, "Worksheet example"), grade(11, "New quiz"), grade(12, "Extra credit", score: 0, points: 0),
        grade(13, "Hidden assignment"), grade(14, "Excluded assignment", excluded: true), grade(15, "Ungraded", score: nil),
        grade(20, "Points assignment", course: 2), grade(30, "Hidden course assignment", course: 3)
      ],
      "missing" => [], "upcoming" => [], "submissions" => {}, "todo" => [],
      "updated_at" => "2026-10-02T12:00:00Z"
    }
  end

  def choices
    { "assignments" => { "canvas-11" => "quiz", "canvas-12" => "work", "custom-paper" => "work" } }
  end

  def test_disabled_default_and_legacy_settings_make_no_model_requests
    data = prepare_classification
    File.write(SPARK_SETTINGS_FILE, JSON.generate("model" => "local"))
    refute load_spark_settings["auto_classify_grades"]
    before = load_grade_overrides
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Disabled classification called Spark" }) do
      auto_classify_grade_categories(data)
    end
    assert_equal before, load_grade_overrides
    %w[true false yes].each do |value|
      refute valid_spark_settings?("auto_classify_grades" => value)
    end
  end

  def test_model_classifies_only_eligible_work_using_class_examples_without_scores
    data = prepare_classification
    before = load_grade_overrides
    @fake = FakeLlamaServer.new(answer: JSON.generate(choices))
    ENV["LLM_URL"] = @fake.url
    capture_io { auto_classify_grade_categories(data) }
    saved = load_grade_overrides
    assert_equal choices["assignments"].merge("canvas-10" => "work"), saved.dig("grading", "1", "assignments")
    assert_equal before["canvas"], saved["canvas"]
    assert_equal before["custom"], saved["custom"]
    assert_equal before.dig("grading", "1", "categories"), saved.dig("grading", "1", "categories")
    assert_equal before.dig("grading", "3"), saved.dig("grading", "3")
    assert_equal 1, @fake.requests.length
    request = @fake.requests.first["body"]
    assert_equal({ "type" => "json_object" }, request["response_format"])
    prompt = request.dig("messages", 0, "content")
    assert_includes prompt, "best guess"
    assert_includes prompt, "Worksheet example"
    ['"score":', "Private Student"].each { |text| refute_includes prompt, text }
    ["Hidden assignment", "Excluded assignment", "Points assignment", "Hidden course assignment", "Ungraded"].each do |text|
      refute_includes prompt, text
    end
    capture_io { auto_classify_grade_categories(data) }
    assert_equal 1, @fake.requests.length, "Already categorized work must not be sent again"
  end

  def test_invalid_or_incomplete_responses_save_nothing_and_report_failure
    data = prepare_classification
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    before = load_grade_overrides
    answers = [
      "not JSON", "[]",
      JSON.generate("assignments" => { "canvas-11" => "quiz" }),
      JSON.generate("assignments" => choices["assignments"].merge("canvas-11" => "invented")),
      JSON.generate("assignments" => choices["assignments"].merge("canvas-other" => "work"))
    ]
    answers.each do |answer|
      output, = capture_io do
        with_replaced_method(self, :ai_ask, ->(*, **) { answer }) { auto_classify_grade_categories(data) }
      end
      assert_includes output, "Spark automatic grade categories failed"
      assert_includes output, "retried on the next refresh"
      assert_equal before, load_grade_overrides
    end
  end

  def test_manual_choices_removals_and_hiding_during_model_request_win
    data = prepare_classification
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    reply = lambda do |*, **|
      GRADE_OVERRIDES_MUTEX.synchronize do
        latest = load_grade_overrides
        latest["grading"]["1"]["assignments"]["canvas-11"] = "work"
        latest["custom"].delete("paper")
        latest["canvas"]["12"] = { "hidden" => true }
        save_grade_overrides(latest)
      end

      JSON.generate(choices)
    end
    with_replaced_method(self, :ai_ask, reply) { capture_io { auto_classify_grade_categories(data) } }
    assert_equal({ "canvas-10" => "work", "canvas-11" => "work" }, load_grade_overrides.dig("grading", "1", "assignments"))
    refute load_grade_overrides["custom"].key?("paper")
    assert load_grade_overrides.dig("canvas", "12", "hidden")
  end

  def test_a_failed_class_does_not_prevent_other_classes_being_categorized
    data = prepare_classification
    save_hidden_course_ids([])
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    reply = lambda do |*, **kwargs|
      if kwargs.fetch(:system_prompt).include?("Hidden course assignment")
        JSON.generate("assignments" => { "canvas-30" => "other" })
      else
        "invalid JSON"
      end
    end
    with_replaced_method(self, :ai_ask, reply) { capture_io { auto_classify_grade_categories(data) } }
    assert_equal({ "canvas-10" => "work" }, load_grade_overrides.dig("grading", "1", "assignments"))
    assert_equal "other", load_grade_overrides.dig("grading", "3", "assignments", "canvas-30")
  end

  def test_disabling_or_changing_categories_during_request_discards_result
    data = prepare_classification
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    disable = lambda do |*, **|
      update_spark_settings { |settings| settings["auto_classify_grades"] = false }
      JSON.generate(choices)
    end
    with_replaced_method(self, :ai_ask, disable) { capture_io { auto_classify_grade_categories(data) } }
    assert_equal({ "canvas-10" => "work" }, load_grade_overrides.dig("grading", "1", "assignments"))

    update_spark_settings { |settings| settings["auto_classify_grades"] = true }
    change = lambda do |*, **|
      latest = load_grade_overrides
      latest["grading"]["1"]["categories"]["quiz"]["name"] = "Updated quizzes"
      save_grade_overrides(latest)
      JSON.generate(choices)
    end
    output, = capture_io do
      with_replaced_method(self, :ai_ask, change) { auto_classify_grade_categories(data) }
    end
    assert_includes output, "Class categories changed"
    assert_equal({ "canvas-10" => "work" }, load_grade_overrides.dig("grading", "1", "assignments"))
  end

  def test_refresh_classifies_new_grades_and_model_failure_does_not_fail_canvas_refresh
    data = prepare_classification
    @fake = FakeLlamaServer.new(answer: JSON.generate(choices))
    ENV["LLM_URL"] = @fake.url
    $dashboard_data = nil
    with_replaced_method(self, :fetch_dashboard_data, -> { data }) { capture_io { refresh_dashboard } }
    assert_equal data, dashboard_data
    assert_nil dashboard_status[:error]
    assert_equal "quiz", load_grade_overrides.dig("grading", "1", "assignments", "canvas-11")

    latest = load_grade_overrides
    latest["grading"]["1"]["assignments"].delete("canvas-11")
    save_grade_overrides(latest)
    @fake.stop
    @fake = nil
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    output, = capture_io do
      with_replaced_method(self, :fetch_dashboard_data, -> { data }) { refresh_dashboard }
    end
    assert_includes output, "Spark automatic grade categories failed"
    assert_equal data, dashboard_data
    assert_nil dashboard_status[:error]
    refute load_grade_overrides.dig("grading", "1", "assignments").key?("canvas-11")
  end

  def test_large_backlogs_are_batched_without_truncating_assignment_input
    data = prepare_classification
    data["grades"] = (100...125).map { |id| grade(id, "Practice worksheet #{id} " + "x" * 250) }
    overrides = load_grade_overrides
    overrides["custom"] = {}
    save_grade_overrides(overrides)
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    requests = []
    classify = lambda do |_, _, **kwargs|
      payload = JSON.parse(kwargs.fetch(:system_prompt).split("Class data (JSON):\n").last)
      requests << payload
      JSON.generate("assignments" => payload["assignments"].to_h { |grade| [grade["id"], "work"] })
    end
    with_replaced_method(self, :ai_ask, classify) { capture_io { auto_classify_grade_categories(data) } }
    assert_equal [20, 5], requests.map { |payload| payload["assignments"].length }
    saved = load_grade_overrides.dig("grading", "1", "assignments")
    assert_equal 25, saved.keys.count { |id| id.match?(/\Acanvas-1[012]\d\z/) }
    assert_equal "work", saved["canvas-124"]
  end
end
