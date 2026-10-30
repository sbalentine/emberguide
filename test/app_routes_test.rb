require "net/http"
require "timeout"
require_relative "test_helper"
require_relative "ai_assistant_test"

DASHBOARD_TEST_SERVER_THREAD = Thread.new do
  DASHBOARD_SERVER.start
end

Timeout.timeout(5) do
  Thread.pass until DASHBOARD_SERVER.status == :Running
end

DASHBOARD_TEST_PORT = DASHBOARD_SERVER.listeners.first.addr[1]

Minitest.after_run do
  DASHBOARD_SERVER.shutdown
  DASHBOARD_TEST_SERVER_THREAD.join
end

class AppRoutesTest < Minitest::Test
  def test_modules_browsing_is_read_only_and_escapes_canvas_text
    $dashboard_data["modules"] = {
      "1" => [{
        "id" => 50, "name" => "Week <script>alert(1)</script>",
        "items" => [
          { "id" => 51, "title" => "Start here", "type" => "SubHeader" },
          { "id" => 52, "title" => "Weekly overview", "type" => "Page",
            "completion_requirement" => { "completed" => true } },
          { "id" => 53, "title" => "Practice", "type" => "Assignment",
            "content_details" => { "due_at" => "2026-10-23T16:00:00Z" } }
        ]
      }]
    }
    response = request("/modules")
    assert_equal "200", response.code
    assert_includes response.body, "<title>Class Modules</title>"
    assert_includes response.body, "Week &lt;script&gt;"
    refute_includes response.body, "<script>alert"
    assert_includes response.body, 'id="module-1-50"'
    refute_includes response.body, "data-pin-module"
    assert_includes response.body, "This Week in Class"
    assert_includes response.body, 'href="/modules#module-1-50"'
    assert_match(%r{module-week-links.*Practice}m, response.body)
    assert_includes response.body, "Due "
    assert_includes response.body, '<details class="module-items-toggle">'
    assert_includes response.body, '<details class="module-group"'
    refute_match(/<details[^>]*\sopen/, response.body)
    assert_match(%r{<summary>\s*<strong>Start here</strong>\s*<span>2 items</span>}, response.body)
    assert_includes response.body, "data-module-expand"
    assert_includes response.body, "1 of 1 requirements complete"
    assert_includes response.body, "#{BASE_URL}/courses/1/modules/items/52"
    assert_equal "405", request("/modules", Net::HTTP::Post).code
    assert_equal "404", request("/modules/invalid").code
    assert_equal "text/javascript; charset=utf-8", request("/modules.js")["Content-Type"]
    assert_includes request("/").body, 'href="/modules#module-1-50"'
    save_course_name_mappings("1" => "Algebra")
    assert_includes request("/modules").body, ">Algebra</option>"
    assert_includes request("/").body, 'class="module-eyebrow">Algebra'

    save_hidden_course_ids(["1"])
    refute_includes request("/modules").body, 'id="module-1-50"'
    refute_includes request("/").body, 'href="/modules#module-1-50"'
  end

  def test_module_items_outside_this_week_load_instructions_once_on_open
    $dashboard_data["modules"] = { "1" => [
      { "id" => 60, "name" => "Week 9", "items" => [
        { "id" => 61, "title" => "Today", "type" => "Page", "page_url" => "today",
          "content" => { "text" => "Saved <text>", "links" => [], "fetched_at" => Time.now.iso8601 } }
      ] },
      { "id" => 70, "name" => "Week 8", "items" => [
        { "id" => 71, "title" => "Last week", "type" => "Page", "page_url" => "last-week" },
        { "id" => 72, "title" => "Locked", "type" => "Page", "page_url" => "locked",
          "content_details" => { "locked_for_user" => true } },
        { "id" => 73, "title" => "Video", "type" => "ExternalUrl" }
      ] }
    ] }
    page = request("/modules").body
    assert_includes page, "Saved &lt;text&gt;"
    assert_includes page, 'data-module-content-url="/modules/item-content?course_id=1&amp;item_id=71"'
    refute_includes page, "item_id=72"
    refute_includes page, "item_id=73"

    paths = []
    server_main = TOPLEVEL_BINDING.receiver
    response = nil
    capture_io do
      with_replaced_method(server_main, :canvas_get, ->(path) { paths << path; { "body" => "<p>Read <i>chapter</i> 3</p>" } }) do
        response = request("/modules/item-content?course_id=1&item_id=71")
        assert_equal "200", request("/modules/item-content?course_id=1&item_id=71").code
        assert_equal "404", request("/modules/item-content?course_id=1&item_id=72").code
        assert_equal "404", request("/modules/item-content?course_id=1&item_id=999").code
      end
    end
    assert_equal "200", response.code
    assert_includes response.body, "<p>Read chapter 3</p>"
    assert_equal ["/api/v1/courses/1/pages/last-week"], paths
    assert_equal "Read chapter 3", JSON.parse(File.read(CACHE_FILE))["modules"]["1"][1]["items"][0].dig("content", "text")
    assert_includes request("/modules").body, "Read chapter 3"
    assert_equal "405", request("/modules/item-content?course_id=1&item_id=71", Net::HTTP::Post).code

    capture_io do
      with_replaced_method(server_main, :canvas_get, ->(_path) { raise "Canvas API error: 500" }) do
        $dashboard_data["modules"]["1"][1]["items"][0].delete("content")
        assert_equal "502", request("/modules/item-content?course_id=1&item_id=71").code
      end
    end
  end

  def test_modules_distinguishes_not_loaded_empty_and_failed_states
    assert_includes request("/modules").body, "haven't been loaded"
    $dashboard_data["modules"] = { "1" => [] }
    assert_includes request("/modules").body, "No modules are available"
    $dashboard_data["modules_errors"] = { "1" => "Could not refresh modules." }
    assert_includes request("/modules").body, "Could not refresh modules."
    assert_includes request("/modules").body, "Showing saved modules"
    $dashboard_data = nil
    assert_includes request("/modules").body, "Waiting for Canvas data"
  end

  def setup
    FileUtils.rm_f(STUDENT_SETTINGS_FILE)
    FileUtils.rm_f(SPARK_SETTINGS_FILE)
    FileUtils.rm_f(DAILY_OVERVIEW_FILE)
    FileUtils.rm_f(SPARK_HISTORY_FILE)
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    FileUtils.rm_f(BACKUP_SETTINGS_FILE)
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    FileUtils.rm_f(ACHIEVEMENT_HISTORY_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)
    $school_calendar_cache = nil
    $dashboard_data = {
      "profile" => { "short_name" => "Avery" },
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [{
        "assignment_id" => 10,
        "score" => 8,
        "assignment" => {
          "id" => 10,
          "course_id" => 1,
          "name" => "Quiz",
          "points_possible" => 10
        }
      }],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {},
      "updated_at" => "2026-09-27T12:00:00Z"
    }
    $last_successful_update = Time.parse("2026-09-27T12:00:00Z")
    $last_refresh_error = nil
    $event_journal = { "next_id" => 1, "events" => [] }
  end

  def test_student_birthday_settings_and_calendar_marker
    assert_includes request("/settings").body, 'href="/settings/student"'
    assert_equal "200", request("/settings/student").code
    assert_equal "405", request("/settings/student", Net::HTTP::Delete).code
    assert_equal "404", request("/settings/student/invalid").code
    response = request("/settings/student", Net::HTTP::Post, "birthday" => "11/15")
    assert_equal "303", response.code
    assert_equal "/settings/student?saved=1", URI(response["Location"]).request_uri
    assert_includes request("/settings/student").body, 'value="11/15"'
    assert_includes request("/settings/student").body, 'placeholder="MM/DD"'
    assert_equal({ "birthday_month" => 11, "birthday_day" => 15 }, load_student_settings)
    page = request("/calendar?month=2026-11").body
    assert_match(/datetime="2026-11-15">15<\/time>\s*<span class="calendar-birthday"/, page)
    assert_equal 1, page.scan('class="calendar-birthday"').length
    assert_includes page.dup.force_encoding(Encoding::UTF_8), "🎂"
    assert_includes request("/calendar?month=2027-11").body, 'class="calendar-birthday"'
    refute_includes request("/calendar?month=2026-07").body, 'class="calendar-birthday"'
    rejected = request("/settings/student", Net::HTTP::Post, "birthday" => "02/30")
    assert_equal "422", rejected.code
    assert_includes rejected.body, "Student settings not saved."
    assert_equal 11, load_student_settings["birthday_month"]
    %w[2026-11-15 2/9 13/01 00/15].each do |invalid|
      assert_equal "422", request("/settings/student", Net::HTTP::Post, "birthday" => invalid).code
      assert_equal 11, load_student_settings["birthday_month"]
    end
    assert_equal "303", request("/settings/student", Net::HTTP::Post, "birthday" => "02/29").code
    assert_includes request("/calendar?month=2028-02").body, 'class="calendar-birthday"'
    refute_includes request("/calendar?month=2027-02").body, 'class="calendar-birthday"'
    assert_equal "303", request("/settings/student", Net::HTTP::Post, "birthday" => "").code
    refute_includes request("/calendar?month=2026-11").body, 'class="calendar-birthday"'
  ensure
    FileUtils.rm_f(STUDENT_SETTINGS_FILE)
  end

  def test_parent_context_can_be_saved_without_a_running_spark_server
    ENV.delete("LLM_URL")
    save_spark_model("saved-model", ["saved-model"])
    File.write(DAILY_OVERVIEW_FILE, "{}")
    response = request("/settings/spark", Net::HTTP::Post,
      "action" => "context", "student_context" => "Grade 7. One step at a time.",
      "course_context_1" => "Unit 2 covers proportional relationships. Use exact textbook definitions.")
    assert_equal "303", response.code
    assert_equal "/settings/spark?saved=context", URI(response["Location"]).request_uri
    saved = load_spark_settings
    assert_equal "saved-model", saved["model"]
    assert_includes saved.dig("course_context", "1"), "proportional relationships"
    refute File.exist?(DAILY_OVERVIEW_FILE)
    page = request("/settings/spark?saved=context").body
    assert_includes page, "Spark context saved."
    assert_includes page, "Grade 7. One step at a time."
    assert_includes page, 'name="course_context_1"'
    rejected = request("/settings/spark", Net::HTTP::Post,
      "action" => "context", "student_context" => "x" * (SPARK_CONTEXT_NOTE_MAX_CHARS + 1),
      "course_context_1" => "Keep this draft")
    assert_equal "422", rejected.code
    assert_includes rejected.body, "Spark context not saved."
    assert_includes rejected.body, "Keep this draft"
    assert_equal saved, load_spark_settings
  ensure
    FileUtils.rm_f(SPARK_SETTINGS_FILE)
  end

  def test_parent_context_excludes_hidden_classes_without_erasing_their_notes
    ENV.delete("LLM_URL")
    $dashboard_data["courses"] << { "id" => 2, "name" => "Science" }
    $dashboard_data["course_names"]["2"] = "Science"
    save_spark_context("Grade 7", "1" => "Visible math note", "2" => "Hidden science note",
      "gone" => "Hidden unavailable note", "retired" => "Editable retired note")
    save_hidden_course_ids(["2", "gone"])
    page = request("/settings/spark").body
    assert_includes page, 'name="course_context_1"'
    assert_includes page, 'name="course_context_retired"'
    refute_includes page, 'name="course_context_2"'
    refute_includes page, 'name="course_context_gone"'
    refute_includes page, "Hidden science note"
    refute_includes ai_parent_context(dashboard_data_with_manual), "Hidden science note"
    response = request("/settings/spark", Net::HTTP::Post,
      "action" => "context", "student_context" => "Updated student note",
      "course_context_1" => "Updated math note", "course_context_retired" => "Editable retired note",
      "course_context_2" => "Do not overwrite hidden notes")
    assert_equal "303", response.code
    assert_equal "Updated math note", load_spark_settings.dig("course_context", "1")
    assert_equal "Hidden science note", load_spark_settings.dig("course_context", "2")
    assert_equal "Hidden unavailable note", load_spark_settings.dig("course_context", "gone")
    save_hidden_course_ids([])
    page = request("/settings/spark").body
    assert_includes page, 'name="course_context_2"'
    assert_includes page, "Hidden science note"
  ensure
    FileUtils.rm_f(SPARK_SETTINGS_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def test_ask_page_and_endpoint_use_the_configured_llama_server
    ENV.delete("LLM_URL")
    refute_includes request("/").body, 'href="/ask"'
    page = request("/ask")
    assert_equal "200", page.code
    assert_includes page.body, "Set up Spark"
    spark = request("/settings/spark")
    assert_equal "200", spark.code
    assert_includes spark.body, "LLM_URL"
    refute_includes spark.body, "data-spark-test"
    assert_equal({ "enabled" => false, "online" => false }, JSON.parse(request("/api/ai/status").body))

    fake = FakeLlamaServer.new(answer: "Study Lesson 1-3 Blookets.", models: [{ id: "qwen3-14b", state: "loaded" }, { id: "gemma-4", state: "unloaded" }])
    ENV["LLM_URL"] = fake.url
    ENV["LLM_API_KEY"] = "never-shown-key"
    FileUtils.rm_f(SPARK_SETTINGS_FILE)
    $ai_default_model = nil
    assert_includes request("/").body, %(href="/ask">\n        Spark)
    assert_includes request("/settings").body, 'href="/settings/spark"'
    spark = request("/settings/spark")
    assert_includes spark.body, fake.url
    assert_includes spark.body, "Set (hidden)"
    assert_includes spark.body, "data-spark-test"
    refute_includes spark.body, "never-shown-key"
    refute_includes spark.body, "llama.exe", "server-side paths aren't shown"
    assert_includes spark.body, %(<option value="" selected>Automatic (qwen3-14b)</option>)
    assert_includes spark.body.dup.force_encoding(Encoding::UTF_8), %(<option value="qwen3-14b">qwen3-14b · ready</option>)
    assert_includes spark.body, %(<option value="gemma-4">gemma-4</option>)
    refute_includes spark.body, "llm_model"
    saved = request("/settings/spark", Net::HTTP::Post, "model" => "gemma-4", "llm_url" => "http://evil")
    assert_equal ["303", "/settings/spark?saved=1"], [saved.code, URI(saved["Location"]).request_uri]
    assert_equal ["gemma-4", fake.url], ai_settings.values_at("model", "url")
    assert_includes request("/settings/spark?saved=1").body, %(<option value="gemma-4" selected>gemma-4</option>)
    rejected = request("/settings/spark", Net::HTTP::Post, "model" => "evil-model")
    assert_equal "422", rejected.code
    assert_includes rejected.body, "isn&#39;t installed"
    assert_equal "gemma-4", ai_settings["model"]
    assert_equal "405", request("/settings/spark", Net::HTTP::Delete).code
    assert_equal "303", request("/settings/spark", Net::HTTP::Post, "model" => "").code
    assert_equal "", ai_settings["model"]
    page = request("/ask")
    assert_includes page.body, "What Spark can see"
    assert_includes page.body, "data-ask-form"
    assert_match(%r{<h1>Spark</h1>\s*<span class="ask-status"[^>]*aria-label="Spark connection status"}, page.body)
    assert_includes page.body, 'role="log" aria-label="Messages" tabindex="0"'
    assert_match(%r{<div class="ask-log"[^>]*></div>}, page.body)
    refute_includes page.body, "Try one of these, or type your own question."
    assert_includes page.body, '<label class="module-sr-only" for="ask-suggestion-select">Suggested questions</label>'
    assert_includes page.body, 'data-ask-suggestion-select'
    suggestions = page.body.scan(/<button type="button" class="ask-suggestion">(.*?)<\/button>/).flatten
    assert_equal 4, suggestions.length
    suggestions.each do |suggestion|
      assert_includes page.body, %(<option value="#{suggestion}">#{suggestion}</option>)
    end
    assert_match(/data-ask-web-toggle>\s*Search the web\s*<\/label>/, page.body)
    refute_match(/\bExa\b/, page.body)
    assert_match(%r{<details class="ask-web-details">\s*<summary>How web search works</summary>\s*<p>.*external web-search service.*cannot guarantee anonymity.*</p>\s*</details>}, page.body)
    status = JSON.parse(request("/api/ai/status").body)
    assert_equal [true, true], status.values_at("enabled", "online")
    refute status.key?("key_accepted")
    assert_equal [%w[qwen3-14b gemma-4], "qwen3-14b", true], JSON.parse(request("/api/ai/status?check=1").body).values_at("models", "model", "automatic")
    assert_equal "405", request("/ai/ask").code
    assert_equal "415", request("/ai/ask", Net::HTTP::Post, "messages" => "hi").code

    response = post_json("/ai/ask", "messages" => [{ "role" => "user", "content" => "What should I study?" }])
    assert_equal "200", response.code
    assert_equal "Study Lesson 1-3 Blookets.", JSON.parse(response.body)["answer"]
    assert_equal "What should I study?", fake.requests.last["body"]["messages"].last["content"]
    assert_equal "422", post_json("/ai/ask", "messages" => []).code
    assert_equal "422", post_json("/ai/ask", "not json").code

    response, events = post_stream([{ "role" => "user", "content" => "What should I focus on tonight?" }])
    assert_equal "200", response.code
    assert_equal "application/x-ndjson; charset=utf-8", response["Content-Type"]
    assert_equal %w[progress token done], events.map { |event| event["type"] }.uniq
    assert_equal 100, events.find { |event| event["type"] == "progress" }["total"]
    assert_equal "Study Lesson 1-3 Blookets.", events.last["answer"]
    assert_equal "Study Lesson 1-3 Blookets.", events.select { |event| event["type"] == "token" }.map { |event| event["text"] }.join.strip
    assert_equal "422", post_json("/ai/ask", { "messages" => [] }, "Accept" => "application/x-ndjson").code

    fake.stop
    fake = nil
    offline = request("/settings/spark", Net::HTTP::Post, "model" => "gemma-4")
    assert_equal "422", offline.code
    assert_includes offline.body, "Spark is offline"
    assert_equal "", ai_settings["model"]
    _response, events = post_stream([{ "role" => "user", "content" => "Hi" }])
    assert_equal ["error"], events.map { |event| event["type"] }
    assert_match(/offline/, events.first["error"])
    response = post_json("/ai/ask", "messages" => [{ "role" => "user", "content" => "Hi" }])
    assert_equal "503", response.code
    assert_match(/offline/, JSON.parse(response.body)["error"])
  ensure
    fake&.stop
    %w[LLM_URL LLM_API_KEY].each { |name| ENV.delete(name) }
    FileUtils.rm_f(SPARK_SETTINGS_FILE)
    $ai_default_model = nil
  end

  def post_json(path, payload, headers = {})
    uri = URI("http://127.0.0.1:#{DASHBOARD_TEST_PORT}#{path}")
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.post(uri.path, payload.is_a?(String) ? payload : JSON.generate(payload), { "Content-Type" => "application/json" }.merge(headers))
    end
  end

  def test_optional_web_search_in_json_and_streaming_requests
    saved_env = ENV.to_h.slice("LLM_URL")
    fake = FakeLlamaServer.new(answer: "The Nile helped farming [1].", search_query: "Egypt geography")
    ENV["LLM_URL"] = fake.url
    page = request("/ask").body
    assert_includes page, "data-ask-web-toggle"
    refute_match(/data-ask-web-toggle[^>]*checked/, page)
    assert_includes page, "Spark first identifies the study material locally"
    refute_includes page, "data-ask-web-query"
    refute_includes page, "EXA_API_KEY"
    settings_page = request("/settings/spark").body
    assert_includes settings_page, "No API key or extra setup is required"
    refute_match(/\bExa\b/, settings_page)
    payload = {
      "messages" => [{ "role" => "user", "content" => "Help PRIVATE STUDENT study PRIVATE ASSIGNMENT" }],
      "web_search" => true, "web_query" => "Egypt geography"
    }
    calls = []
    search = lambda do |query|
      calls << query
      { "content" => [{
        "type" => "text", "text" => "Title: <Study guide>\nURL: https://example.com/guide\nHighlights:\nThe Nile helped farming."
      }] }
    end
    with_replaced_method(TOPLEVEL_BINDING.eval("self"), :exa_search_response, search) do
      result = JSON.parse(post_json("/ai/ask", payload).body)
      assert_equal "The Nile helped farming [1].", result["answer"]
      assert_equal "Egypt geography", result["web_query"]
      assert_includes fake.requests[-2].dig("body", "messages", 0, "content"), "You prepare a minimal public"
      assert_includes fake.requests[-2].dig("body", "messages", -1, "content"), "PRIVATE STUDENT"
      assert_equal "https://example.com/guide", result["sources"].first["url"]
      refute result["sources"].first.key?("text")
      prompt = fake.requests.last.dig("body", "messages", 0, "content")
      assert_includes prompt, "The Nile helped farming."
      assert_includes prompt, "untrusted reference material"
      response = post_json("/ai/ask", payload, "Accept" => "application/x-ndjson")
      events = response.body.lines.map { |line| JSON.parse(line) }
      assert_equal %w[preparing_search searching sources progress token done], events.map { |event| event["type"] }.uniq
      assert_equal "Egypt geography", events[2]["query"]
      assert_equal "The Nile helped farming [1].", events.last["answer"]
      assert_equal ["Egypt geography"] * 2, calls
      payload["web_search"] = false
      result = JSON.parse(post_json("/ai/ask", payload).body)
      refute result.key?("sources")
      refute_includes fake.requests.last.dig("body", "messages", 0, "content"), "Optional public web search"
      assert_equal 2, calls.length
      payload["web_search"] = true
      payload["web_search"] = "true"
      assert_equal "422", post_json("/ai/ask", payload, "Accept" => "application/x-ndjson").code
      assert_equal 2, calls.length
      payload["web_search"] = true
    end
    count = fake.requests.length
    with_replaced_method(TOPLEVEL_BINDING.eval("self"), :exa_search_response, ->(*) { raise WebSearchUnavailable, "Web search unavailable" }) do
      response = post_json("/ai/ask", payload, "Accept" => "application/x-ndjson")
      events = response.body.lines.map { |line| JSON.parse(line) }
      assert_equal %w[preparing_search searching error], events.map { |event| event["type"] }.uniq
      assert_equal "Web search unavailable", events.last["error"]
      assert_equal count + 1, fake.requests.length, "Search failure must stop after local preparation, without a final answer"
      assert_equal "503", post_json("/ai/ask", payload).code
    end
  ensure
    fake&.stop
    ENV.delete("LLM_URL")
    ENV.update(saved_env) if saved_env
    $ai_default_model = nil
  end

  def post_stream(messages)
    response = post_json("/ai/ask", { "messages" => messages }, "Accept" => "application/x-ndjson")
    [response, response.body.to_s.lines.map { |line| JSON.parse(line) }]
  end

  def test_search_planning_format_errors_explain_the_failure_and_retry_once
    fake = FakeLlamaServer.new(answer: "I can help with a writing outline.")
    saved_url = ENV["LLM_URL"]
    ENV["LLM_URL"] = fake.url
    with_replaced_method(TOPLEVEL_BINDING.eval("self"), :exa_search_response, ->(*) { flunk "Malformed request reached web search" }) do
      capture_io do
        response = post_json("/ai/ask", { "question" => "Help with a play reflection", "web_search" => true }, "Accept" => "application/x-ndjson")
        events = response.body.lines.map { |line| JSON.parse(line) }
        assert_equal %w[conversation preparing_search retrying_search error], events.map { |event| event["type"] }
        assert_equal "format", events[2]["reason"]
        assert_includes events.last["error"], "not a privacy violation"
        assert_equal 2, fake.requests.length
        assert fake.requests.all? { |entry| entry["body"]["response_format"] == { "type" => "json_object" } }
        saved = spark_conversation(events.first["conversation_id"])
        assert_equal "failed", saved["turns"].first["status"]
        assert_equal events.last["error"], saved["turns"].first["error"]
      end
    end
  ensure
    fake&.stop
    ENV["LLM_URL"] = saved_url
    $ai_default_model = nil
  end

  def test_saved_spark_conversations_resume_research_and_current_school_context
    fake = FakeLlamaServer.new(answer: "Practice the Nile vocabulary [1].", search_query: "Nile vocabulary")
    saved_url = ENV["LLM_URL"]
    ENV["LLM_URL"] = fake.url
    search = ->(*) { { "content" => [{ "type" => "text", "text" => "Title: Nile guide\nURL: https://example.com/nile\nHighlights:\nThe Nile supports farming." }] } }
    with_replaced_method(TOPLEVEL_BINDING.eval("self"), :exa_search_response, search) do
      first = JSON.parse(post_json("/ai/ask", "question" => "Define Nile vocabulary", "web_search" => true).body)
      id = first.fetch("conversation_id")
      assert_equal "School Study Priorities", first["title"]
      title_request = fake.requests.last["body"]
      assert_equal 80, title_request["max_tokens"]
      assert_includes title_request.dig("messages", 0, "content"), "Summarize a Spark conversation"
      original = JSON.parse(request("/api/ai/conversations/#{id}").body)
      assert_equal "completed", original["turns"].first["status"]
      assert_equal "Nile vocabulary", original["turns"].first["search"]["query"]
      assert_includes original["turns"].first["search"]["sources"].first["text"], "The Nile supports farming."
      assert_equal [id], JSON.parse(request("/api/ai/conversations").body)["conversations"].map { |entry| entry["id"] }

      $dashboard_data["profile"]["short_name"] = "Avery Updated"
      $dashboard_data["updated_at"] = "2026-10-25T12:00:00Z"
      $dashboard_data["modules"] = { "1" => [{ "name" => "New geography lesson", "items" => [
        { "type" => "Page", "title" => "River practice", "content" => { "text" => "Review the Nile's role in farming." } }
      ] }] }
      response = post_json("/ai/ask", { "question" => "Help me practice", "conversation_id" => id }, "Accept" => "application/x-ndjson")
      events = response.body.lines.map { |line| JSON.parse(line) }
      assert_equal "conversation", events.first["type"]
      assert_equal id, events.first["conversation_id"]
      assert_equal "done", events.last["type"]
      saved = JSON.parse(request("/api/ai/conversations/#{id}").body)
      assert_equal 2, saved["turns"].length
      refute original.key?("contexts")
      refute saved.key?("contexts")
      assert saved["turns"].none? { |turn| turn.key?("context_id") }
      sent = fake.requests.last["body"]["messages"]
      assert_equal %w[system user assistant user], sent.map { |message| message["role"] }
      assert_includes sent.first["content"], "for Avery"
      assert_includes sent.first["content"], "Review the Nile's role in farming."
      refute_includes File.read(SPARK_HISTORY_FILE), "Review the Nile's role in farming."
      assert_includes sent.first["content"], "previously saved web research for general explanations"
      assert_includes sent.first["content"], "Previously saved web research"
      assert_includes sent.first["content"], "The Nile supports farming."
      assert_equal "Define Nile vocabulary", sent[1]["content"]
      assert_equal "Help me practice", sent.last["content"]
      renamed = post_json("/api/ai/conversations/#{id}", "title" => "Nile study")
      assert_equal "Nile study", JSON.parse(renamed.body)["title"]
      assert_equal "405", request("/api/ai/conversations", Net::HTTP::Delete).code
      assert_equal "415", request("/api/ai/conversations/#{id}/delete", Net::HTTP::Post).code
      deleted = post_json("/api/ai/conversations/#{id}/delete", {})
      assert_equal "200", deleted.code
      assert_equal "404", request("/api/ai/conversations/#{id}").code
      assert_empty JSON.parse(request("/api/ai/conversations").body)["conversations"]
    end
  ensure
    fake&.stop
    ENV["LLM_URL"] = saved_url
    $ai_default_model = nil
  end

  def test_saved_spark_failures_are_visible_and_can_be_retried
    saved_url = ENV["LLM_URL"]
    ENV["LLM_URL"] = "http://127.0.0.1:1"
    response = post_json("/ai/ask", "question" => "Help with homework")
    assert_equal "503", response.code
    result = JSON.parse(response.body)
    id = result.fetch("conversation_id")
    saved = spark_conversation(id)
    assert_equal "failed", saved["turns"].first["status"]
    assert_match(/offline/, saved["turns"].first["error"])
    response = post_json("/ai/ask", { "question" => "Try again", "conversation_id" => id }, "Accept" => "application/x-ndjson")
    assert_equal "error", JSON.parse(response.body.lines.last)["type"]
    assert_equal %w[failed failed], spark_conversation(id)["turns"].map { |turn| turn["status"] }
    assert_equal "404", post_json("/ai/ask", "question" => "Hi", "conversation_id" => SecureRandom.uuid).code
    assert_equal "422", post_json("/ai/ask", "question" => "").code
    assert_equal "422", post_json("/api/ai/conversations/#{id}", "title" => "").code
    _, pending = spark_begin_turn("Still running", conversation_id: id, web_search: false)
    assert_equal "409", post_json("/ai/ask", "question" => "Again", "conversation_id" => id).code
    spark_update_turn(id, pending["id"], status: "interrupted", error: "Test ended")
  ensure
    ENV["LLM_URL"] = saved_url
    $ai_default_model = nil
  end

  def request(path, request_class = Net::HTTP::Get, fields = nil)
    uri = URI("http://127.0.0.1:#{DASHBOARD_TEST_PORT}#{path}")
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      request = request_class.new(uri)
      request.set_form_data(fields) if fields
      http.request(request)
    end
  end

  def multipart_request(path, fields:, filename:, content:)
    boundary = "emberguide-test-#{SecureRandom.hex(8)}"
    parts = fields.map do |name, value|
      <<~PART.gsub("\n", "\r\n")
        --#{boundary}
        Content-Disposition: form-data; name="#{name}"

        #{value}
      PART
    end
    parts << [
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"backup_file\"; " \
        "filename=\"#{filename}\"\r\n",
      "Content-Type: application/zip\r\n\r\n",
      content,
      "\r\n"
    ].join
    body = "#{parts.join}--#{boundary}--\r\n"

    uri = URI(
      "http://127.0.0.1:#{DASHBOARD_TEST_PORT}#{path}"
    )
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = body
      http.request(request)
    end
  end

  def test_dashboard_and_static_routes
    dashboard = request("/")
    stylesheet = request("/dashboard.css")
    chart = request("/chart.umd.min.js")
    navigation = request("/navigation.js")
    manifest = request("/manifest.json")
    icon = request("/emberguide-icon.png")
    class_names = request("/settings/classes")
    grades = request("/settings/grades")
    scheduled_emails = request("/settings/emails")
    backup_settings = request("/settings/backup")
    settings = request("/settings")
    calendar = request("/calendar")
    achievements = request("/achievements")
    achievement_settings = request("/settings/achievements")
    calendar_settings = request("/settings/calendar")
    digest_preview = request("/settings/emails/digest-preview")
    backup_download = request("/settings/backup/download")
    old_backup_download = request("/settings/emails/backup-download")

    assert_equal "200", dashboard.code
    assert_includes dashboard.body, "Good"
    assert_includes dashboard.body, "<title>EmberGuide</title>"
    assert_includes dashboard.body, 'rel="stylesheet"'
    dashboard_navigation = dashboard.body[/<nav class="dashboard-nav".*?<\/nav>/m]
    refute_includes dashboard_navigation, ">Grades<"
    refute_includes dashboard_navigation, 'href="/settings/grades"'
    assert_includes dashboard_navigation, "<svg"
    refute_includes dashboard_navigation, '<img src="/emberguide-icon.png"'
    assert_equal "text/css; charset=utf-8", stylesheet["Content-Type"]
    assert_equal "text/javascript; charset=utf-8", chart["Content-Type"]
    assert_includes chart.body, "Chart.js v4.5.1"
    assert_equal "text/javascript; charset=utf-8", navigation["Content-Type"]
    assert_includes navigation.body, "dashboard-nav-toggle"
    assert_equal "EmberGuide", JSON.parse(manifest.body)["name"]
    assert_equal "200", icon.code
    assert_equal "image/png", icon["Content-Type"]
    assert_operator icon.body.bytesize, :>, 0
    assert_equal "200", class_names.code
    assert_includes class_names.body, "Classes Outside Canvas"
    assert_equal "200", grades.code
    assert_includes grades.body, "Edit Assignment Grades"
    assert_equal "200", scheduled_emails.code
    assert_includes scheduled_emails.body, "Scheduled Emails"
    assert_includes scheduled_emails.body, "Backup Email"
    assert_includes scheduled_emails.body, "Preview Daily Digest"
    refute_includes scheduled_emails.body, "Download Backup"
    refute_includes scheduled_emails.body, "Restore Backup"
    assert_equal "200", backup_settings.code
    assert_includes backup_settings.body, "<title>Data Backup</title>"
    assert_includes backup_settings.body, "Export Data"
    assert_includes backup_settings.body, "Download Backup"
    assert_includes backup_settings.body, "Import Data"
    assert_includes backup_settings.body, "Restore Backup"
    assert_includes backup_settings.body, 'class="is-active" href="/settings"'
    assert_equal "200", settings.code
    assert_includes settings.body, "<title>Settings</title>"
    assert_includes settings.body, 'rel="stylesheet"'
    assert_includes settings.body, "Scheduled Emails"
    assert_includes settings.body, 'href="/settings/achievements"'
    assert_includes settings.body, 'href="/settings/backup"'
    assert_includes settings.body, 'href="/settings/calendar"'
    refute_includes settings.body, "Manual Coursework"
    refute_includes settings.body, "District Calendar"
    assert_includes settings.body, 'class="is-active" href="/settings"'
    assert_equal "200", calendar.code
    assert_includes calendar.body, "<title>School Calendar</title>"
    assert_includes calendar.body, 'rel="stylesheet"'
    assert_includes calendar.body, "School Calendar"
    assert_includes calendar.body, 'class="is-active" href="/calendar"'
    assert_equal "200", achievements.code
    assert_includes achievements.body, "<title>Achievements</title>"
    assert_includes achievements.body, "On-Time Run"
    assert_includes achievements.body, "Clear Slate"
    assert_includes achievements.body, "Strong Score Streak"
    assert_equal 5, achievements.body.scan('class="achievement-streak-progress"').length
    assert_includes achievements.body, "Milestones"
    assert_includes achievements.body, "Work Completed"
    assert_includes achievements.body, "School Year Journey"
    assert_includes achievements.body, "Badge Collection"
    assert_equal 20, achievements.body.scan('class="card collectible-badge ').length
    assert_equal(
      %w[Common Rare Epic Legend] * 5,
      achievements.body.scan(/<small>(Common|Rare|Epic|Legend)<\/small>/).flatten
    )
    refute_match(/class="badge-emblem" aria-hidden/, achievements.body)
    assert_includes achievements.body, "is-locked"
    refute_includes achievements.body, 'aria-label="School year progress"'
    refute_match(/<strong>\d+% complete<\/strong>/, achievements.body)
    assert_includes achievements.body, 'class="is-active" href="/achievements"'
    assert_equal "200", achievement_settings.code
    assert_includes achievement_settings.body, "<title>Achievement Settings</title>"
    assert_includes achievement_settings.body, 'value="80"'
    refute_includes achievement_settings.body, 'name="school_year_start"'
    refute_includes achievement_settings.body, "School-Day Overrides"
    assert_includes achievement_settings.body, 'class="is-active" href="/settings"'
    assert_equal "200", calendar_settings.code
    assert_includes calendar_settings.body, "<title>Calendar Settings</title>"
    assert_includes calendar_settings.body, "District Calendar"
    assert_includes calendar_settings.body, 'value="2026-08-12"'
    assert_includes calendar_settings.body, 'value="2027-06-04"'
    assert_includes calendar_settings.body, "School-Day Review"
    assert_includes calendar_settings.body, 'class="is-active" href="/settings"'
    assert_equal "200", digest_preview.code
    assert_equal "text/html; charset=utf-8", digest_preview["Content-Type"]
    assert_equal "no-store", digest_preview["Cache-Control"]
    assert_includes digest_preview.body, "Daily Digest"
    assert_includes digest_preview.body, "Avery &middot;"
    assert_includes digest_preview.body, "Current Grade Snapshot"
    assert_equal "200", backup_download.code
    assert_equal "application/zip", backup_download["Content-Type"]
    assert_match(
      /\Aattachment; filename="emberguide-backup-\d{4}-\d{2}-\d{2}-\d{6}\.zip"\z/,
      backup_download["Content-Disposition"]
    )
    assert_equal "no-store", backup_download["Cache-Control"]
    assert_equal backup_download.body.bytesize.to_s, backup_download["Content-Length"]
    assert_equal "303", old_backup_download.code
    assert_equal(
      "/settings/backup/download",
      URI(old_backup_download["Location"]).request_uri
    )
  end

  def test_achievements_respect_hidden_and_edited_grades
    now = Time.now
    $dashboard_data["grades"] = [
      {
        "assignment_id" => 10,
        "score" => 0,
        "graded_at" => (now + 60).iso8601,
        "assignment" => {
          "id" => 10,
          "course_id" => 1,
          "name" => "Hidden placeholder",
          "points_possible" => 10
        }
      },
      {
        "assignment_id" => 11,
        "score" => 6,
        "graded_at" => now.iso8601,
        "assignment" => {
          "id" => 11,
          "course_id" => 1,
          "name" => "Corrected quiz",
          "points_possible" => 10
        }
      }
    ]
    save_grade_overrides(
      "canvas" => {
        "10" => { "hidden" => true },
        "11" => { "score" => 9 }
      },
      "custom" => {}
    )

    response = request("/achievements")
    score_card = response.body[
      /<article class="card achievement-card achievement-card-scores">.*?<\/article>/m
    ]

    assert_equal "200", response.code
    assert_match(/<strong>\s*1\s*<\/strong>/, score_card)
  end

  def test_calendar_settings_route_saves_dates_overrides_and_rejects_invalid_input
    save_achievement_settings(85)
    save_school_calendar_settings("")
    calendar_settings = load_school_calendar_settings
    fields = {
      "action" => "school_year",
      "school_year_start" => "2026-08-12",
      "school_year_end" => "2027-06-04",
      "no_school_dates" => "2026-10-16",
      "extra_school_dates" => "2026-10-17"
    }
    saved = request("/settings/calendar", Net::HTTP::Post, fields)
    assert_equal "303", saved.code
    assert_equal "/settings/calendar?saved=1", URI(saved["Location"]).request_uri
    settings = load_achievement_settings
    assert_equal 85, settings["strong_score_threshold"]
    assert_equal(
      { "2026-10-16" => "no_school", "2026-10-17" => "school" },
      settings["school_day_overrides"]
    )
    assert_equal calendar_settings, load_school_calendar_settings
    editor = request("/settings/calendar")
    assert_match(/name="no_school_dates"[^>]*>2026-10-16</, editor.body)
    assert_match(/name="extra_school_dates"[^>]*>2026-10-17</, editor.body)

    [
      [{ "school_year_end" => "2026-01-01" }, "must be after"],
      [{ "no_school_dates" => "2028-01-01" }, "outside the school year"],
      [{ "no_school_dates" => "2026-10-17" }, "cannot be both"],
      [{ "no_school_dates" => "not-a-date" }, "YYYY-MM-DD"]
    ].each do |changes, error|
      invalid = request("/settings/calendar", Net::HTTP::Post, fields.merge(changes))
      assert_equal "422", invalid.code
      assert_includes invalid.body, error
      assert_equal settings, load_achievement_settings
      assert_includes invalid.body, changes.values.first
    end
  end

  def test_score_target_updates_preserve_school_year_and_overrides
    save_achievement_settings(
      80, school_year_start: "2026-09-01", school_year_end: "2027-05-31",
      school_day_overrides: { "2026-10-16" => "no_school" },
      no_school_labels: { "2026-10-16" => "Day off" }
    )
    original = load_achievement_settings
    saved = request("/settings/achievements", Net::HTTP::Post, "strong_score_threshold" => "85")
    assert_equal "303", saved.code
    assert_equal original.merge("strong_score_threshold" => 85), load_achievement_settings

    invalid = request("/settings/achievements", Net::HTTP::Post, "strong_score_threshold" => "101")
    assert_equal "422", invalid.code
    assert_includes invalid.body, "60% to 100%"
    assert_equal original.merge("strong_score_threshold" => 85), load_achievement_settings

    feed_saved = request(
      "/settings/calendar", Net::HTTP::Post,
      "calendar_feed_url" => "", "calendar_excluded_keywords" => "Elementary"
    )
    assert_equal "303", feed_saved.code
    assert_equal original.merge("strong_score_threshold" => 85), load_achievement_settings
  end

  def test_labeled_no_school_dates_appear_in_calendar_without_a_feed_and_can_be_removed
    save_school_calendar_settings("", "Labor")
    label = "Labor Day <closed>"
    fields = {
      "action" => "school_year", "school_year_start" => "2026-08-12",
      "school_year_end" => "2027-06-04",
      "no_school_dates" => "2026-09-07 | #{label}\n2026-09-08",
      "extra_school_dates" => "2026-09-12"
    }
    assert_equal "303", request("/settings/calendar", Net::HTTP::Post, fields).code
    editor = request("/settings/calendar")
    assert_includes editor.body, "2026-09-07 | Labor Day &lt;closed&gt;"
    assert_includes editor.body, "<span>Labor Day &lt;closed&gt;</span>"
    page = request("/calendar?month=2026-09")
    assert_equal "200", page.code
    assert_includes page.body, 'data-calendar-date="2026-09-07"'
    assert_includes page.body, 'id="calendar-events-2026-09-07"'
    assert_equal 2, page.body.scan("<strong>Labor Day &lt;closed&gt;</strong>").length
    assert_equal 2, page.body.scan("<strong>No school</strong>").length
    refute_includes page.body, "<closed>"
    refute_includes page.body, 'data-calendar-date="2026-09-12"'
    invalid = request(
      "/settings/calendar", Net::HTTP::Post,
      fields.merge("no_school_dates" => "2026-09-07 | #{"x" * 121}")
    )
    assert_equal "422", invalid.code
    assert_includes invalid.body, "120 characters"
    assert_equal({ "2026-09-07" => label }, load_achievement_settings["no_school_labels"])
    assert_equal "303", request(
      "/settings/calendar", Net::HTTP::Post,
      fields.merge("no_school_dates" => "", "extra_school_dates" => "")
    ).code
    assert_equal({}, load_achievement_settings["no_school_labels"])
    refute_includes request("/calendar?month=2026-09").body, 'data-calendar-date="2026-09-07"'
  end

  def test_achievements_show_calendar_adjustments_review_and_manual_overrides
    save_school_calendar_settings("https://calendar.example.test/events.ics", "Fall Break")
    body = <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART;VALUE=DATE:20261012
      DTEND;VALUE=DATE:20261017
      SUMMARY:Fall Break
      END:VEVENT
      END:VCALENDAR
    ICS
    save_achievement_settings(
      80,
      school_year_start: "2026-10-12", school_year_end: "2026-10-18",
      school_day_overrides: { "2026-10-14" => "school", "2026-10-17" => "school" }
    )
    original_data = deep_copy($dashboard_data)
    $school_calendar_cache = {
      feed_url: "https://calendar.example.test/events.ics",
      fetched_at: Time.now,
      events: parse_school_calendar(body)
    }
    response = request("/achievements")
    assert_equal "200", response.code
    assert_includes response.body, "of 2 school days"
    refute_includes response.body, "Calendar-adjusted estimate"
    refute_includes response.body, 'id="school-days-review"'
    refute_includes response.body, 'href="/settings/calendar#school-days-review"'
    review = request("/settings/calendar")
    assert_equal "200", review.code
    assert_match(/4\s+weekdays excluded/, review.body)
    assert_includes review.body, "Fall Break"
    assert_includes review.body, "Count as a school day"
    assert_includes review.body, 'id="school-days-review"'
    assert_includes review.body, "Calendar-adjusted estimate"
    assert_equal original_data, $dashboard_data
  end

  def test_backup_restore_upload_imports_data
    save_manual_coursework(
      "courses" => {
        "restored" => { "name" => "Restored Music" }
      },
      "assignments" => {}
    )
    archive = build_backup_archive
    save_manual_coursework(empty_manual_coursework)

    response = multipart_request(
      "/settings/backup",
      fields: {
        "action" => "restore_backup",
        "confirm_restore" => "true"
      },
      filename: "emberguide-backup.zip",
      content: archive
    )

    assert_equal "303", response.code
    assert_equal(
      "/settings/backup?restored=1",
      URI(response["Location"]).request_uri
    )
    assert_equal "Restored Music", load_manual_coursework.dig(
      "courses",
      "restored",
      "name"
    )
  end

  def test_calendar_settings_route_saves_feed_without_exposing_it_on_dashboard
    feed_url = "https://calendar.example.test/private.ics?token=secret"
    saved = request(
      "/settings/calendar",
      Net::HTTP::Post,
      "calendar_feed_url" => feed_url,
      "calendar_excluded_keywords" => "Elementary\nHigh School"
    )

    assert_equal "303", saved.code
    assert_equal "/settings/calendar?saved=1", URI(saved["Location"]).request_uri
    assert_equal feed_url, load_school_calendar_settings["feed_url"]
    assert_equal(
      ["Elementary", "High School"],
      load_school_calendar_settings["excluded_keywords"]
    )

    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: []
    }
    body = request("/").body

    assert_includes body, "What to Do Next"
    assert_includes body, 'href="/settings"'
    refute_includes body, feed_url
    refute_includes body, "Edit Class Names"
  end

  def test_schedule_changes_are_shown_in_the_calendar_section
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url)
    today = Date.today
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: [
        {
          "title" => "First Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => today + 2,
          "end_date" => today + 2
        },
        {
          "title" => "Second Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => today + 3,
          "end_date" => today + 3
        }
      ]
    }

    body = request("/").body
    calendar_section = body[/<section class="section calendar-section">.*?<\/section>/m]

    refute_includes body, "schedule-notice"
    assert_includes calendar_section, "Upcoming Schedule Changes"
    assert_includes calendar_section, "First Modified Day"
    assert_includes calendar_section, "Second Modified Day"
  end

  def test_calendar_page_renders_navigable_month_grid_with_event_days
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url)
    today = Date.today
    calendar_month = Date.new(today.year, today.month, 1)
    event_start = calendar_month + 9
    event_end = event_start + 1
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: [
        {
          "title" => "Fall Break",
          "description" => "",
          "location" => "",
          "start_date" => event_start,
          "end_date" => event_end
        }
      ]
    }

    body = request(
      "/calendar?month=#{calendar_month.strftime("%Y-%m")}"
    ).body

    assert_includes body, calendar_month.strftime("%B %Y")
    assert_includes body, "/calendar?month=#{(calendar_month << 1).strftime("%Y-%m")}"
    assert_includes body, "/calendar?month=#{(calendar_month >> 1).strftime("%Y-%m")}"
    assert_includes body, "calendar-month-day has-events"
    assert_includes body, "data-calendar-date=\"#{event_start.iso8601}\""
    assert_includes body, "aria-controls=\"calendar-events-#{event_start.iso8601}\""
    assert_includes body, "id=\"calendar-events-#{event_start.iso8601}\""
    assert_includes body, "Select a highlighted date to see its events."
    assert_includes body, "Fall Break"
    assert_equal "422", request("/calendar?month=not-a-month").code
  end

  def test_grade_editor_can_hide_ungraded_upcoming_assignments
    assignment = {
      "id" => 42, "course_id" => 1,
      "name" => "Ungraded classroom activity",
      "due_at" => (Time.now + 3600).iso8601,
      "points_possible" => nil, "submission_types" => ["not_graded"]
    }
    submission = {
      "assignment_id" => 42, "assignment" => assignment,
      "score" => nil, "graded_at" => nil, "workflow_state" => "unsubmitted"
    }
    $dashboard_data["upcoming"] = [{ "assignment" => assignment }]
    $dashboard_data["submissions"] = { "1" => { "42" => submission } }
    editor = request("/settings/grades?course_id=1")
    assert_includes editor.body, "Ungraded classroom activity"
    assert_equal 1, editor.body.scan('name="canvas_42_hidden"').length
    assert_includes editor.body, "No grade"
    saved = request(
      "/settings/grades", Net::HTTP::Post,
      "course_id" => "1", "canvas_42_hidden" => "true"
    )
    assert_equal "303", saved.code
    assert load_grade_overrides.dig("canvas", "42", "hidden")
    refute_includes request("/").body, "Ungraded classroom activity"
    assert_empty reconcile_canvas_grade_overrides($dashboard_data)
    submission["score"] = 9
    assert_equal ["42"], reconcile_canvas_grade_overrides($dashboard_data)
    assert_includes request("/settings/grades?course_id=1").body, "Ungraded classroom activity"
  end

  def test_calendar_browsing_shows_past_events_in_grid_details_and_list
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url)
    month = Date.new(Date.today.year, Date.today.month, 1) << 2
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: Time.now,
      events: [
        {
          "title" => "Past School Holiday", "description" => "", "location" => "",
          "start_date" => month + 5, "end_date" => month + 5
        },
        {
          "title" => "Break Crossing Month", "description" => "", "location" => "",
          "start_date" => month - 2, "end_date" => month + 1
        },
        {
          "title" => "Future Assembly", "description" => "", "location" => "",
          "start_date" => Date.today + 60, "end_date" => Date.today + 60
        }
      ]
    }
    body = request("/calendar?month=#{month.strftime("%Y-%m")}").body
    assert_includes body, "data-calendar-date=\"#{(month + 5).iso8601}\""
    assert_includes body, "id=\"calendar-events-#{(month + 5).iso8601}\""
    list = body.split('class="calendar-list-heading"').last
    assert_includes list, "Events in #{month.strftime("%B %Y")}"
    assert_includes list, "Past School Holiday"
    assert_includes list, "Break Crossing Month"
    refute_includes list, "Future Assembly"

    upcoming = request("/calendar").body.split('class="calendar-list-heading"').last
    assert_includes upcoming, "Upcoming Events"
    assert_includes upcoming, "Future Assembly"
    refute_includes upcoming, "Past School Holiday"
  end

  def test_next_actions_prioritize_incomplete_work_and_collapse_completed_work
    now = Time.now
    assignment = lambda do |id, name, due_at|
      {
        "id" => id,
        "course_id" => 1,
        "name" => name,
        "due_at" => due_at.iso8601
      }
    end
    overdue = assignment.call(20, "Overdue worksheet", now - 3600)
    due_today = assignment.call(21, "Today practice", now + 3600)
    due_tomorrow = assignment.call(22, "Tomorrow reading", now + 86_400)
    due_later = assignment.call(23, "Later project", now + 172_800)
    completed = assignment.call(24, "Finished quiz", now + 259_200)

    $dashboard_data["missing"] = [overdue]
    $dashboard_data["upcoming"] = [
      due_today,
      due_tomorrow,
      due_later,
      completed
    ]
    $dashboard_data["submissions"] = {
      "1" => {
        "24" => { "workflow_state" => "submitted" }
      }
    }

    body = request("/").body
    next_actions = body[/<section class="today-summary".*?<\/section>/m]
    visible, more = next_actions.split('class="next-actions-more-details"', 2)

    assert_operator visible.index("Overdue worksheet"), :<, visible.index("Today practice")
    assert_operator visible.index("Today practice"), :<, visible.index("Tomorrow reading")
    refute_includes visible, "Later project"
    assert_includes more, "Later project"
    refute_includes next_actions, "Finished quiz"
    assert_match(/1\s+more assignment\s+this week/, more)
    refute_includes body, 'id="this-week"'
    assert_operator body.index("My To-Dos"), :<, body.index('id="this-week-in-class"')
    assert_operator body.index('id="this-week-in-class"'), :<, body.index('id="grades"')
  end

  def test_scheduled_email_route_saves_separate_recipients_and_preferences
    response = request(
      "/settings/emails",
      Net::HTTP::Post,
      "action" => "save",
      "backup_recipients" => "backup@example.com",
      "backup_daily_enabled" => "true",
      "digest_recipients" => "one@example.com\ntwo@example.com",
      "digest_daily_enabled" => "true"
    )

    assert_equal "303", response.code
    assert_equal "/settings/emails?saved=1", URI(response["Location"]).request_uri
    assert_equal(
      {
        "backup_recipients" => ["backup@example.com"],
        "backup_daily_enabled" => true,
        "last_backup_sent_on" => nil,
        "digest_recipients" => ["one@example.com", "two@example.com"],
        "digest_daily_enabled" => true,
        "digest_spark_overview" => false,
        "last_digest_sent_on" => nil
      },
      load_scheduled_email_settings
    )
  end

  def test_low_grades_have_a_persistent_review_queue_and_review_controls_on_the_main_page
    $dashboard_data["grades"].first["score"] = 6
    $dashboard_data["grades"].first["graded_at"] = "2026-01-02T12:00:00Z"
    body = request("/").body
    queue = body[/<section class="card unreviewed-grades".*?<\/section>/m]
    assert_includes queue, "Unreviewed Grades (1)"
    assert_includes queue, "Quiz"
    assert_includes queue, "Mark reviewed"
    assert_equal 2, body.scan('action="/grades/review"').length

    response = request("/grades/review", Net::HTTP::Post, "course_id" => "1",
      "assignment_id" => "10", "score" => "6", "points_possible" => "10",
      "reviewed" => "true", "return_section" => "unreviewed-grades")
    assert_equal "303", response.code
    assert_equal "/#unreviewed-grades", URI(response["Location"]).request_uri + "##{URI(response["Location"]).fragment}"
    body = request("/").body
    queue = body[/<section class="card unreviewed-grades".*?<\/section>/m]
    assert_includes queue, "Unreviewed Grades (0)"
    refute_includes queue, "Quiz"
    assert_includes body, ">Reviewed</button>"
    preview = request("/settings/emails/digest-preview")
    assert_includes preview.body, "No unreviewed grades below 70%."

    response = request("/grades/review", Net::HTTP::Post, "course_id" => "1",
      "assignment_id" => "10", "score" => "6", "points_possible" => "10",
      "reviewed" => "false", "return_section" => "grades")
    assert_equal "303", response.code
    assert_includes request("/").body, "Unreviewed Grades (1)"
    assert_includes request("/settings/emails/digest-preview").body, "Needs review"
  end

  def test_grade_review_route_rejects_stale_scores_and_invalid_actions_without_losing_the_queue
    $dashboard_data["grades"].first["score"] = 6
    request("/")
    $dashboard_data["grades"].first["score"] = 5
    response = request("/grades/review", Net::HTTP::Post, "course_id" => "1",
      "assignment_id" => "10", "score" => "6", "points_possible" => "10", "reviewed" => "true")
    assert_equal "422", response.code
    assert_includes response.body, 'role="alert"'
    assert_includes response.body, "grade changed"
    assert_includes response.body, "Unreviewed Grades (1)"
    assert_equal "405", request("/grades/review").code
    assert_equal "404", request("/grades/review/missing", Net::HTTP::Post).code
    response = request("/grades/review", Net::HTTP::Post, "reviewed" => "invalid")
    assert_equal "422", response.code
    assert_includes response.body, "Choose whether the grade has been reviewed."
  end

  def test_unreviewed_grade_titles_and_course_names_are_escaped
    $dashboard_data["grades"].first["score"] = 6
    $dashboard_data["grades"].first["assignment"]["name"] = "Quiz <script>alert(1)</script>"
    $dashboard_data["course_names"]["1"] = "Math <test>"
    response = request("/")
    assert_equal "200", response.code
    queue = response.body[/<section class="card unreviewed-grades".*?<\/section>/m]
    assert_includes queue, "Quiz &lt;script&gt;"
    assert_includes queue, "Math &lt;test&gt;"
    refute_includes queue, "<script>"
  end

  def test_overview_generation_and_preview_use_the_daily_cache_without_sending_email
    app = TOPLEVEL_BINDING.eval("self")
    calls = 0
    with_replaced_method(app, :digest_spark_overview, ->(*) { calls += 1; { "bullets" => ["Check today's Math notes."] } }) do
      with_replaced_method(app, :deliver_email_messages, ->(*) { flunk "Generation sent email" }) do
        response = request("/settings/emails", Net::HTTP::Post,
          "action" => "generate_overview", "digest_spark_overview" => "true")
        assert_equal "303", response.code
        assert_equal "/settings/emails?generated=overview", URI(response["Location"]).request_uri
      end
    end
    assert_equal 1, calls
    assert load_scheduled_email_settings["digest_spark_overview"]
    with_replaced_method(app, :ai_ask, ->(*) { flunk "Preview invoked AI" }) do
      preview = request("/settings/emails/digest-preview")
      assert_equal "200", preview.code
      assert_includes preview.body, "Today at a glance"
      assert_includes preview.body, "Check today&#39;s Math notes."
      page = request("/settings/emails?generated=overview")
      assert_includes page.body, "No email was sent"
      assert_includes page.body, "Generate Overview Now"
      assert_includes page.body, 'id="overview-generation-status"'
      assert_includes page.body, 'aria-live="polite" hidden'
      assert_includes page.body, '<progress aria-label="Generating Spark overview">'
      assert_includes page.body, "Generating overview..."
      assert_includes page.body, "No email is being sent."
      assert_includes page.body, "Prepared"
      response = request("/settings/emails", Net::HTTP::Post, "action" => "save")
      assert_equal "303", response.code
      refute load_scheduled_email_settings["digest_spark_overview"]
      refute_includes request("/settings/emails/digest-preview").body, "Today at a glance"
    end
  end

  def test_overview_generation_requires_opt_in_and_reports_failure_without_sending
    response = request("/settings/emails", Net::HTTP::Post, "action" => "generate_overview")
    assert_equal "422", response.code
    assert_includes response.body, "Enable Include Spark overview"
    app = TOPLEVEL_BINDING.eval("self")
    with_replaced_method(app, :digest_spark_overview, ->(*) { { "error" => "offline" } }) do
      response = request("/settings/emails", Net::HTTP::Post,
        "action" => "generate_overview", "digest_spark_overview" => "true")
      assert_equal "422", response.code
      assert_includes response.body, "Overview not generated"
      alert = response.body[/<div class="backup-message error".*?<\/div>/m]
      assert_includes alert, "offline"
      assert_includes request("/settings/emails/digest-preview").body, "normal saved school details"
    end
  end

  def test_failed_overview_refresh_displays_escaped_reason_even_when_a_valid_preview_exists
    app = TOPLEVEL_BINDING.eval("self")
    with_replaced_method(app, :digest_spark_overview, ->(*) { { "bullets" => ["Existing saved overview."] } }) do
      assert_equal "303", request("/settings/emails", Net::HTTP::Post,
        "action" => "generate_overview", "digest_spark_overview" => "true").code
    end
    with_replaced_method(app, :digest_spark_overview, ->(*) { { "error" => "Model <study> & notes exceed the context limit." } }) do
      response = request("/settings/emails", Net::HTTP::Post,
        "action" => "generate_overview", "digest_spark_overview" => "true")
      assert_equal "422", response.code
      alert = response.body[/<div class="backup-message error".*?<\/div>/m]
      assert_includes alert, "Model &lt;study&gt; &amp; notes exceed the context limit."
      refute_includes alert, "<study>"
    end
    assert_includes request("/settings/emails/digest-preview").body, "Existing saved overview."
  end

  def test_manual_overview_generation_reports_an_existing_generation
    $daily_overview_generation_mutex.lock
    response = request("/settings/emails", Net::HTTP::Post,
      "action" => "generate_overview", "digest_spark_overview" => "true")
    assert_equal "422", response.code
    assert_includes response.body, "An overview is already being generated."
    assert $daily_overview_generation_mutex.owned?
  ensure
    $daily_overview_generation_mutex.unlock
  end

  def test_unexpected_overview_failure_reports_generation_not_gmail_settings
    app = TOPLEVEL_BINDING.eval("self")
    with_replaced_method(app, :digest_spark_overview, ->(*) { raise "Unexpected model failure" }) do
      response = request("/settings/emails", Net::HTTP::Post,
        "action" => "generate_overview", "digest_spark_overview" => "true")
      assert_equal "502", response.code
      alert = response.body[/<div class="backup-message error".*?<\/div>/m]
      assert_includes alert, "Unable to generate the overview."
      refute_includes alert, "Gmail"
    end
  end

  def test_scheduled_email_route_reports_missing_gmail_configuration
    response = request(
      "/settings/emails",
      Net::HTTP::Post,
      "action" => "send_digest",
      "digest_recipients" => "parent@example.com"
    )

    assert_equal "422", response.code
    assert_includes response.body, "Gmail is not configured"
    assert_includes response.body, "Configure the Gmail sender and app password"
  end

  def test_legacy_backup_route_redirects_to_scheduled_emails
    response = request("/backups")

    assert_equal "303", response.code
    assert_equal "/settings/emails", URI(response["Location"]).request_uri
  end

  def test_grade_snapshot_is_sorted_alphabetically
    $dashboard_data["courses"] << { "id" => 2, "name" => "Science" }
    $dashboard_data["course_names"]["2"] = "Science"
    $dashboard_data["grades"] << {
      "assignment_id" => 20,
      "score" => 10,
      "assignment" => {
        "id" => 20,
        "course_id" => 2,
        "name" => "Lab",
        "points_possible" => 10
      }
    }

    body = request("/").body
    snapshot = body[/<section class="grade-snapshot".*?<\/section>/m]

    assert_operator snapshot.index("Math"), :<, snapshot.index("Science")
  end

  def test_grade_route_saves_and_clears_official_grades
    saved = request(
      "/settings/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "9.2",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "303", saved.code
    assert_equal 9.2, load_grade_overrides.dig("canvas", "10", "score")

    editor = request("/settings/grades")
    assert_includes editor.body, "assignment-grade-row is-edited"
    assert_includes editor.body, ">Edited<"

    cleared = request(
      "/settings/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "303", cleared.code
    assert_equal(
      { "canvas" => {}, "custom" => {} },
      load_grade_overrides
    )
  end

  def test_grade_route_rejects_invalid_percentages
    response = request(
      "/settings/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "invalid",
      "canvas_10_points" => "",
      "new_name" => ""
    )

    assert_equal "422", response.code
    assert_includes response.body, "valid number"
  end

  def test_hidden_assignment_returns_with_latest_canvas_grade_after_refresh
    $dashboard_data["grades"] << {
      "assignment_id" => 11,
      "score" => 10,
      "assignment" => {
        "id" => 11, "course_id" => 1,
        "name" => "Other Quiz", "points_possible" => 10
      }
    }
    $dashboard_data["grades"][0]["assignment"]["name"] = "Premature Grade"
    assignment = deep_copy($dashboard_data["grades"][0]["assignment"])
    assignment["due_at"] = (Time.now + 3600).iso8601
    $dashboard_data["missing"] = [assignment]
    $dashboard_data["upcoming"] = [{ "assignment" => assignment }]
    original = deep_copy($dashboard_data)

    saved = request(
      "/settings/grades", Net::HTTP::Post,
      "canvas_10_hidden" => "true",
      "canvas_10_score" => "9"
    )

    assert_equal "303", saved.code
    assert_equal true, load_grade_overrides.dig("canvas", "10", "hidden")
    assert_equal 8, load_grade_overrides.dig("canvas", "10", "canvas_score")
    assert_equal original, dashboard_data

    editor = request("/settings/grades?course_id=1")
    assert_equal "200", editor.code
    assert_includes editor.body, "Premature Grade"
    assert_includes editor.body, ">Hidden<"
    assert_match(/name="canvas_10_hidden"\s+value="true"\s+checked/, editor.body)

    with_replaced_method(self, :fetch_dashboard_data, -> { deep_copy(original) }) do
      capture_io { refresh_dashboard }
    end

    assert_equal true, load_grade_overrides.dig("canvas", "10", "hidden")
    dashboard = request("/")
    assert_equal "200", dashboard.code
    refute_includes dashboard.body, "Premature Grade"
    assert_includes dashboard.body, "<strong>100%</strong>"

    changed = deep_copy(original)
    changed["grades"][0]["score"] = 6
    changed["grades"][0]["graded_at"] = Time.now.iso8601
    with_replaced_method(self, :fetch_dashboard_data, -> { changed }) do
      capture_io { refresh_dashboard }
    end

    assert_nil dashboard_status[:error]
    refute load_grade_overrides.fetch("canvas").key?("10")
    dashboard = request("/")
    assert_includes dashboard.body, "Premature Grade"
    assert_includes dashboard.body, "<strong>80%</strong>"
    assert_equal [6, 10], combined_grade_submissions(
      dashboard_data, load_grade_overrides
    ).map { |submission| submission["score"] }
  end

  def test_hidden_assignment_can_be_restored_manually
    saved = request("/settings/grades", Net::HTTP::Post, "canvas_10_hidden" => "true")
    assert_equal "303", saved.code
    refute_includes request("/").body, ">Quiz<"

    restored = request(
      "/settings/grades", Net::HTTP::Post,
      "canvas_10_score" => "", "canvas_10_points" => ""
    )

    assert_equal "303", restored.code
    refute load_grade_overrides.fetch("canvas").key?("10")
    assert_includes request("/").body, "Quiz"
  end

  def test_grade_route_adds_infinite_campus_only_assignment
    response = request(
      "/settings/grades",
      Net::HTTP::Post,
      "canvas_10_score" => "",
      "canvas_10_points" => "",
      "new_0_name" => "Unit Test",
      "new_0_course_id" => "1",
      "new_0_score" => "18",
      "new_0_points" => "20",
      "new_0_date" => "2026-10-06",
      "new_1_name" => "Lab Report",
      "new_1_course_id" => "1",
      "new_1_score" => "24",
      "new_1_points" => "25",
      "new_1_date" => "2026-10-05"
    )

    assert_equal "303", response.code

    grades = load_grade_overrides.fetch("custom").values.sort_by { |grade| grade["name"] }
    assert_equal 2, grades.length
    assert_equal ["Lab Report", "Unit Test"], grades.map { |grade| grade["name"] }
    assert_equal [24.0, 18.0], grades.map { |grade| grade["score"] }
    assert_equal [25.0, 20.0], grades.map { |grade| grade["points_possible"] }
  end

  def test_grade_editor_filters_one_class_and_preserves_other_overrides
    $dashboard_data["courses"] << { "id" => 2, "name" => "Science" }
    $dashboard_data["course_names"]["2"] = "Science"
    $dashboard_data["grades"] << {
      "assignment_id" => 20,
      "score" => 7,
      "assignment" => {
        "id" => 20,
        "course_id" => 2,
        "name" => "Lab",
        "points_possible" => 10
      }
    }
    save_grade_overrides(
      "canvas" => {
        "10" => { "score" => 9, "points_possible" => nil },
        "20" => { "score" => 8, "points_possible" => nil, "hidden" => true }
      },
      "custom" => {
        "math-grade" => {
          "course_id" => "1",
          "name" => "Math Test",
          "score" => 18,
          "points_possible" => 20,
          "graded_at" => "2026-10-01"
        },
        "science-grade" => {
          "course_id" => "2",
          "name" => "Science Test",
          "score" => 19,
          "points_possible" => 20,
          "graded_at" => "2026-10-02"
        }
      }
    )

    editor = request("/settings/grades?course_id=1")

    assert_equal "200", editor.code
    assert_includes editor.body, "Edit Math Grades"
    assert_includes editor.body, "Quiz"
    assert_includes editor.body, "Math Test"
    refute_includes editor.body, "Lab"
    refute_includes editor.body, "Science Test"

    saved = request(
      "/settings/grades",
      Net::HTTP::Post,
      "course_id" => "1",
      "canvas_10_score" => "9.5",
      "canvas_10_points" => "",
      "custom_math-grade_name" => "Math Test",
      "custom_math-grade_course_id" => "1",
      "custom_math-grade_score" => "18",
      "custom_math-grade_points" => "20",
      "custom_math-grade_date" => "2026-10-01"
    )

    assert_equal "303", saved.code
    overrides = load_grade_overrides
    assert_equal 9.5, overrides.dig("canvas", "10", "score")
    assert_equal 8, overrides.dig("canvas", "20", "score")
    assert_equal true, overrides.dig("canvas", "20", "hidden")
    assert overrides.fetch("custom").key?("science-grade")
  end

  def test_dashboard_links_each_grade_card_to_its_editor
    dashboard = request("/")

    assert_includes dashboard.body, "/settings/grades?course_id=1"
    assert_includes dashboard.body, "Edit this class"
  end

  def test_grade_editor_rejects_unknown_class
    response = request("/settings/grades?course_id=missing")

    assert_equal "404", response.code
    assert_equal "Class not found", response.body
  end

  def test_status_route_exposes_home_assistant_contract
    response = request("/api/status")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["canvas_available"]
    assert_equal 0, body["latest_event_id"]
    assert_equal 0, body["missing_count"]
    assert_equal "no-cache", response["Cache-Control"]
  end

  def test_class_and_grade_routes_add_manual_class_and_assignment
    course_response = request(
      "/settings/classes",
      Net::HTTP::Post,
      "action" => "create_course",
      "name" => "Piano"
    )

    assert_equal "303", course_response.code
    course_id = load_manual_coursework.fetch("courses").keys.first

    assignment_response = request(
      "/settings/grades",
      Net::HTTP::Post,
      "action" => "create_assignment",
      "course_id" => course_id,
      "name" => "Practice scales",
      "due_at" => (Time.now + 86_400).strftime("%Y-%m-%dT%H:%M")
    )

    assert_equal "303", assignment_response.code

    classes = request("/settings/classes")
    grades = request("/settings/grades")
    dashboard = request("/")

    assert_equal "/settings/classes", URI(course_response["Location"]).request_uri
    assert_equal "/settings/grades", URI(assignment_response["Location"]).request_uri
    assert_includes classes.body, "Piano"
    assert_includes grades.body, "Practice scales"
    assert_includes dashboard.body, "Practice scales"
    assert_includes dashboard.body, "Piano"
  end

  def test_grade_route_validates_manual_assignment_course
    response = request(
      "/settings/grades",
      Net::HTTP::Post,
      "action" => "create_assignment",
      "course_id" => "missing",
      "name" => "Practice scales",
      "due_at" => (Time.now + 86_400).strftime("%Y-%m-%dT%H:%M")
    )

    assert_equal "422", response.code
    assert_includes response.body, "valid class"
  end

  def test_removed_settings_routes_return_not_found
    %w[/grades /class-names /scheduled-emails /coursework].each do |path|
      assert_equal "404", request(path).code
    end
  end

  def test_class_settings_hide_and_restore_canvas_course
    $dashboard_data["upcoming"] = [{
      "assignment" => {
        "id" => 11,
        "course_id" => 1,
        "name" => "Homework",
        "due_at" => (Time.now + 86_400).iso8601
      }
    }]

    hidden = request(
      "/settings/classes",
      Net::HTTP::Post,
      "course_1" => "",
      "hidden_course_1" => "true"
    )

    assert_equal "303", hidden.code
    assert_equal ["1"], load_hidden_course_ids
    refute_includes request("/").body, "Homework"
    refute_includes request("/settings/grades").body, "Quiz"

    settings = request("/settings/classes")
    assert_includes settings.body, "Math"
    assert_match(/hidden_course_1[^>]+checked/, settings.body)

    restored = request(
      "/settings/classes",
      Net::HTTP::Post,
      "course_1" => ""
    )

    assert_equal "303", restored.code
    assert_empty load_hidden_course_ids
    assert_includes request("/").body, "Homework"
  end

  def test_events_route_filters_by_cursor_and_limit
    append_dashboard_events([
      { "type" => "grade_posted" },
      { "type" => "assignment_submitted" },
      { "type" => "assignment_missing" }
    ])

    response = request("/api/events?after=1&limit=1")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal [3], body["events"].map { |event| event["id"] }
    assert_equal 3, body["latest_event_id"]
  end

  def test_api_routes_validate_methods_and_parameters
    assert_equal "405", request("/api/status", Net::HTTP::Post).code
    assert_equal "400", request("/api/events?after=bad").code
    assert_equal "400", request("/api/events?limit=bad").code
  end
end