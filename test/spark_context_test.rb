require_relative "test_helper"

class SparkContextTest < Minitest::Test
  def setup
    [SPARK_SETTINGS_FILE, SPARK_HISTORY_FILE, COURSE_NAME_MAPPINGS_FILE].each { |path| FileUtils.rm_f(path) }
    @data = {
      "profile" => { "short_name" => "Avery" },
      "courses" => [{ "id" => 7, "name" => "Math" }],
      "course_names" => { "7" => "Math" }
    }
  end

  def teardown
    [SPARK_SETTINGS_FILE, SPARK_HISTORY_FILE, COURSE_NAME_MAPPINGS_FILE].each { |path| FileUtils.rm_f(path) }
  end

  def test_notes_and_model_preserve_each_other_and_use_private_storage
    save_spark_model("local-model", ["local-model"])
    save_spark_context(" Grade 7. Explain one step at a time. ", "7" => " Unit 2 is proportional relationships. ", "8" => " ")
    assert_equal "local-model", load_spark_settings["model"]
    assert_equal "Grade 7. Explain one step at a time.", load_spark_settings["student_context"]
    assert_equal({ "7" => "Unit 2 is proportional relationships." }, load_spark_settings["course_context"])
    save_spark_model("", [])
    assert_equal "Grade 7. Explain one step at a time.", load_spark_settings["student_context"]
    assert_equal 0o600, File.stat(SPARK_SETTINGS_FILE).mode & 0o777
    save_spark_context("", {})
    assert_equal "", ai_parent_context(@data)
  end

  def test_invalid_or_oversized_notes_do_not_overwrite_saved_settings
    save_spark_context("Keep this", {})
    original = File.read(SPARK_SETTINGS_FILE)
    assert_raises(ArgumentError) { save_spark_context("x" * 4_001, {}) }
    assert_raises(ArgumentError) { save_spark_context("", "7" => "x" * 4_001) }
    assert_raises(ArgumentError) { save_spark_context("", 7.times.to_h { |id| [id.to_s, "x" * 4_000] }) }
    assert_raises(ArgumentError) { save_spark_context("", "7" => []) }
    assert_equal original, File.read(SPARK_SETTINGS_FILE)
    File.write(SPARK_SETTINGS_FILE, "{broken")
    assert_raises(AiUnavailable) { load_spark_settings }
    assert_raises(AiUnavailable) { save_spark_model("", []) }
    assert_equal "{broken", File.read(SPARK_SETTINGS_FILE)
  end

  def test_chat_uses_general_and_matching_class_notes_without_overriding_canvas
    save_spark_context("Grade 7", "7" => "Use exact textbook definitions.", "8" => "Unrelated class note")
    prompt = ai_system_prompt(@data, "Current Canvas data")
    assert_includes prompt, "Grade 7"
    assert_includes prompt, "Use exact textbook definitions."
    assert_includes prompt, "Explicit current Canvas instructions take priority."
    assert_includes prompt, "do not establish due dates"
    refute_includes prompt, "Unrelated class note"
    renamed = @data.merge("course_names" => { "7" => "Renamed math" })
    assert_includes ai_parent_context(renamed), '"class":"Renamed math"'
    assert_includes ai_parent_context(renamed), "Use exact textbook definitions."
  end

  def test_notes_are_not_copied_into_conversation_history
    save_spark_context("Private parent background marker", "7" => "Private curriculum marker")
    conversation, turn = spark_begin_turn("Help me study", web_search: false)
    spark_update_turn(conversation["id"], turn["id"], status: "completed", answer: "Let's practice.")
    refute_includes File.read(SPARK_HISTORY_FILE), "Private parent background marker"
    refute_includes File.read(SPARK_HISTORY_FILE), "Private curriculum marker"
  end

  def test_daily_overview_receives_parent_context_and_keeps_date_safeguards
    save_spark_context("Grade 7", "7" => "Unit 2 is proportional relationships.")
    prompt = nil
    with_replaced_method(self, :ai_enabled?, -> { true }) do
      with_replaced_method(self, :digest_text_body, ->(*) { "Confirmed Canvas facts" }) do
        with_replaced_method(self, :ai_ask, ->(_data, _messages, **settings) {
          prompt = settings.fetch(:system_prompt)
          '{"bullets":["Review proportional relationships for the confirmed math work."]}'
        }) do
          overview = digest_spark_overview({ "data" => @data }, Time.now)
          assert_equal 1, overview["bullets"].length
        end
      end
    end
    assert_includes prompt, "Grade 7"
    assert_includes prompt, "Unit 2 is proportional relationships."
    assert_includes prompt, "cannot establish a new deadline"
  end

  def test_local_search_preparation_can_resolve_curriculum_without_sending_raw_notes
    save_spark_context("Explain one step at a time.", "7" => "Illustrative Mathematics: Unit 2 is proportional relationships.")
    prompt = nil
    with_replaced_method(self, :ai_ask, ->(_data, _messages, **settings) {
      prompt = settings.fetch(:system_prompt)
      '{"query":"Illustrative Mathematics proportional relationships practice"}'
    }) do
      with_replaced_method(self, :ai_web_search, ->(query, &_) {
        assert_equal "Illustrative Mathematics proportional relationships practice", query
        refute_includes query, "Explain one step at a time"
        { "query" => query, "sources" => [] }
      }) do
        result = ai_prepare_web_search(@data, [{ "role" => "user", "content" => "Help with Unit 2" }])
        assert_empty result["sources"]
      end
    end
    assert_includes prompt, "Unit 2 is proportional relationships."
    assert_includes prompt, "never copy parent notes"
  end
end
