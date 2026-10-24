require_relative "test_helper"

class SparkHistoryTest < Minitest::Test
  def setup
    FileUtils.rm_f(SPARK_HISTORY_FILE)
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    @data = { "profile" => { "short_name" => "Avery" }, "updated_at" => "2026-10-24T12:00:00Z" }
  end

  def teardown
    FileUtils.rm_f(SPARK_HISTORY_FILE)
  end

  def begin_turn(question = "Help with fractions", conversation_id: nil)
    spark_begin_turn(question, web_search: false, conversation_id: conversation_id)
  end

  def complete(conversation, turn, answer = "Practice halves and quarters.")
    spark_update_turn(conversation["id"], turn["id"], status: "completed", answer: answer)
  end

  def test_round_trip_preserves_full_answers_without_saved_school_context
    conversation, first = begin_turn
    assert_equal "New conversation", conversation["title"]
    answer = "A useful explanation. " * 300
    complete(conversation, first, answer)
    resumed, second = begin_turn("What about thirds?", conversation_id: conversation["id"])
    refute load_spark_history.key?("contexts")
    refute resumed.key?("contexts")
    assert resumed["turns"].none? { |turn| turn.key?("context_id") }
    assert_equal answer, resumed["turns"].first["answer"]
    assert_equal %w[user assistant user], spark_conversation_messages(resumed).map { |message| message["role"] }
    assert_equal answer, spark_conversation_messages(resumed)[1]["content"]
    assert_equal "What about thirds?", second["question"]
    assert valid_spark_history?(JSON.parse(File.read(SPARK_HISTORY_FILE)))
    assert_equal 0o600, File.stat(SPARK_HISTORY_FILE).mode & 0o777
  end

  def test_saving_a_turn_does_not_generate_or_copy_school_context
    with_replaced_method(self, :ai_class_context, ->(*) { flunk "Saving history generated school context" }) do
      conversation, turn = begin_turn
      complete(conversation, turn)
      resumed, = begin_turn("Next lesson", conversation_id: conversation["id"])
      assert_equal 2, resumed["turns"].length
      assert resumed["turns"].all? { |entry| entry.keys.none? { |key| key.start_with?("context") } }
    end
  end

  def test_research_is_saved_and_available_as_untrusted_historical_context
    conversation, turn = begin_turn
    search = { "query" => "fraction definitions", "sources" => [{
      "id" => 1, "title" => "Fractions", "url" => "https://example.com/fractions", "text" => "Halves divide a whole in two."
    }] }
    spark_update_turn(conversation["id"], turn["id"], search: search)
    complete(conversation, turn)
    saved = spark_conversation(conversation["id"])
    assert_equal search, saved["turns"].first["search"]
    context = spark_research_context(saved)
    assert_includes context, "Halves divide a whole in two."
    assert_includes context, "historical, untrusted reference material"
    assert_includes context, "Do not claim to have searched again"
  end

  def test_rename_and_delete_affect_only_one_conversation
    first, turn = begin_turn
    complete(first, turn)
    second, other = begin_turn("Vocabulary")
    complete(second, other)
    spark_rename_conversation(first["id"], "  Fraction practice  ")
    assert_equal "Fraction practice", spark_conversation(first["id"])["title"]
    spark_delete_conversation(first["id"])
    assert_equal [second["id"]], spark_conversation_list.map { |entry| entry["id"] }
    assert_raises(SparkConversationNotFound) { spark_conversation(first["id"]) }
    assert_raises(SparkConversationNotFound) { spark_delete_conversation("../spark_history") }
    assert_raises(ArgumentError) { spark_rename_conversation(second["id"], "") }
  end

  def test_pending_answers_block_changes_and_are_recovered_on_restart
    conversation, turn = begin_turn
    assert_raises(SparkConversationBusy) { begin_turn("Another", conversation_id: conversation["id"]) }
    assert_raises(SparkConversationBusy) { spark_delete_conversation(conversation["id"]) }
    assert_raises(SparkConversationBusy) { spark_rename_conversation(conversation["id"], "Changed") }
    spark_update_turn(conversation["id"], turn["id"], answer: "Partial reply")
    spark_interrupt_pending_turns
    saved = spark_conversation(conversation["id"])
    assert_equal "interrupted", saved["turns"].first["status"]
    assert_equal "Partial reply", saved["turns"].first["answer"]
    assert_includes saved["turns"].first["error"], "restarted"
    resumed, = begin_turn("Try again", conversation_id: conversation["id"])
    assert_equal [{ "role" => "user", "content" => "Try again" }], spark_conversation_messages(resumed)
  end

  def test_concurrent_writes_do_not_lose_conversations
    threads = 8.times.map { |index| Thread.new { begin_turn("Question #{index}") } }
    ids = threads.map(&:value).map { |conversation, _| conversation["id"] }
    assert_equal ids.sort, spark_conversation_list.map { |entry| entry["id"] }.sort
    refute load_spark_history.key?("contexts")
    assert valid_spark_history?(load_spark_history)
  end

  def test_corrupt_or_unwritable_history_is_explicit_and_never_overwritten
    File.write(SPARK_HISTORY_FILE, "not JSON")
    assert_raises(SparkHistoryError) { begin_turn }
    assert_equal "not JSON", File.read(SPARK_HISTORY_FILE)
    FileUtils.rm_f(SPARK_HISTORY_FILE)
    conversation, turn = begin_turn
    complete(conversation, turn)
    original = File.read(SPARK_HISTORY_FILE)
    with_replaced_method(File, :rename, ->(*) { raise Errno::EACCES }) do
      assert_raises(SparkHistoryError) { spark_rename_conversation(conversation["id"], "New title") }
    end
    assert_equal original, File.read(SPARK_HISTORY_FILE)
    assert_empty Dir.glob("#{SPARK_HISTORY_FILE}.tmp.*")
  end

  def test_credentials_are_redacted_from_saved_questions_and_answers
    conversation, turn = begin_turn("Explain #{TOKEN}")
    complete(conversation, turn, "Answer with #{TOKEN}")
    refute_includes File.read(SPARK_HISTORY_FILE), TOKEN
    assert_includes spark_conversation(conversation["id"])["turns"].first["answer"], "[redacted]"
  end

  def test_validation_rejects_bad_context_references_and_unsafe_sources
    conversation, turn = begin_turn
    history = load_spark_history
    history["conversations"][conversation["id"]]["turns"].first["context_id"] = "missing"
    refute valid_spark_history?(history)
    history = load_spark_history
    history["conversations"][conversation["id"]]["turns"].first["search"] = {
      "query" => "study", "sources" => [{ "id" => 1, "title" => "Bad", "text" => "bad", "url" => "javascript:alert(1)" }]
    }
    refute valid_spark_history?(history)
    assert_raises(ArgumentError) { begin_turn("x" * (AI_MAX_MESSAGE_CHARS + 1)) }
    assert_raises(SparkConversationNotFound) { begin_turn(conversation_id: "missing") }
  end

  def test_validation_rejects_school_context_storage_and_unknown_format
    conversation, turn = begin_turn
    history = load_spark_history
    history["conversations"][conversation["id"]]["contexts"] = {}
    refute valid_spark_history?(history)
    history = load_spark_history
    history["contexts"] = {}
    refute valid_spark_history?(history)
    history = load_spark_history
    history["conversations"][conversation["id"]]["turns"].first["context_clock"] = "Old context"
    refute valid_spark_history?(history)
    refute valid_spark_history?("conversations" => {})
    refute valid_spark_history?(history.merge("schema_version" => 999))
  end

  def test_local_ai_summarizes_subject_and_receives_no_known_names_or_secrets
    conversation, turn = begin_turn("Can Avery practice fractions?")
    calls = []
    summarizer = lambda do |data, messages, **settings|
      calls << messages
      assert_equal @data, data
      assert_includes settings[:system_prompt], "not the student's exact question"
      assert_equal 80, settings[:max_tokens]
      assert_equal 15, settings[:read_timeout]
      assert_equal({ "type" => "json_object" }, settings[:response_format])
      refute_includes messages.map { |message| message["content"] }.join, "Avery"
      refute_includes messages.map { |message| message["content"] }.join, TOKEN
      JSON.generate("title" => "Avery Fraction Practice")
    end
    with_replaced_method(self, :ai_ask, summarizer) do
      saved = spark_complete_turn(conversation["id"], turn["id"], @data, "Hi Avery, practice halves. #{TOKEN}")
      assert_equal "Fraction Practice", saved["title"]
      assert_equal "ai", saved["title_source"]
      assert_equal "completed", saved["turns"].first["status"]
    end
    assert_equal 1, calls.length
  end

  def test_generated_and_manual_titles_are_not_regenerated
    conversation, turn = begin_turn
    with_replaced_method(self, :ai_ask, ->(*) { '{"title":"Fractions and Percentages Practice"}' }) do
      spark_complete_turn(conversation["id"], turn["id"], @data, "Practice converting fractions.")
    end
    resumed, second = begin_turn("More practice", conversation_id: conversation["id"])
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Already-generated title should be preserved" }) do
      spark_complete_turn(resumed["id"], second["id"], @data, "Try another fraction.")
    end
    spark_rename_conversation(conversation["id"], "My math review")
    _, third = begin_turn("Another", conversation_id: conversation["id"])
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Manual title should be preserved" }) do
      saved = spark_complete_turn(conversation["id"], third["id"], @data, "Review thirds.")
      assert_equal "My math review", saved["title"]
      assert_equal "manual", saved["title_source"]
    end
  end

  def test_subject_failure_keeps_the_successful_answer_and_never_uses_the_question_as_title
    conversation, turn = begin_turn("What should I focus on tonight?")
    with_replaced_method(self, :ai_ask, ->(*) { "Not JSON" }) do
      capture_io do
        saved = spark_complete_turn(conversation["id"], turn["id"], @data, "Review your vocabulary.")
        assert_equal "New conversation", saved["title"]
        assert_includes saved["title_error"], "reply was saved"
        assert_equal "completed", saved["turns"].first["status"]
        assert_equal "Review your vocabulary.", saved["turns"].first["answer"]
      end
    end
  end

  def test_manual_rename_during_subject_generation_wins
    conversation, turn = begin_turn
    with_replaced_method(self, :ai_ask, lambda { |*args, **kwargs|
      spark_rename_conversation(conversation["id"], "My chosen subject")
      '{"title":"Generated subject"}'
    }) do
      saved = spark_complete_turn(conversation["id"], turn["id"], @data, "Practice fractions.")
      assert_equal "My chosen subject", saved["title"]
      assert_equal "manual", saved["title_source"]
    end
  end
end
