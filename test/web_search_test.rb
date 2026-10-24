require_relative "test_helper"

class WebSearchTest < Minitest::Test
  def setup
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
  end

  def search_result(text: "The Nile supported agriculture.")
    { "content" => [{ "type" => "text", "text" => "Title: Geography guide\nURL: https://example.com/geography\nHighlights:\n#{text}" }] }
  end

  def test_search_is_explicit_and_ignores_browser_search_queries
    refute ai_web_requested?("messages" => [])
    refute ai_web_requested?("web_search" => false, "web_query" => "ignored")
    assert ai_web_requested?("web_search" => true, "web_query" => "Private browser data ignored")
    ["true", nil, 1].each do |value|
      assert_raises(ArgumentError) { ai_web_requested?("web_search" => value) }
    end
    [nil, [], " ", "ab", "x" * (WEB_SEARCH_MAX_QUERY_CHARS + 1)].each do |query|
      assert_raises(WebSearchUnavailable) { ai_validate_public_query(query, {}) }
    end
    assert_equal WEB_SEARCH_MAX_QUERY_CHARS, ai_validate_public_query("x" * WEB_SEARCH_MAX_QUERY_CHARS, {}).length
    with_replaced_method(self, :exa_search_response, ->(*) { flunk "Search was not requested" }) do
      assert_nil ai_web_search(nil)
    end
  end

  def test_local_handoff_uses_class_material_but_sends_only_public_query
    data = {
      "profile" => { "name" => "Private Learner" },
      "courses" => [{ "id" => 7, "name" => "History" }],
      "modules" => { "7" => [{ "name" => "Week", "items" => [
        { "type" => "Page", "title" => "Vocabulary", "content" => { "text" => "topography, vegetation, factors" } }
      ] }] }
    }
    messages = [{ "role" => "user", "content" => "What vocab do I need to study? Give me definitions." }]
    query = "Middle school definitions: topography, vegetation, factors"
    observed = []
    planner = lambda do |local_data, local_messages, system_prompt:, response_format:|
      assert_equal data, local_data
      assert_equal messages, local_messages
      assert_includes system_prompt, "topography, vegetation, factors"
      assert_includes system_prompt, "no grades, scores"
      assert_includes system_prompt, "Anonymize the request yourself BEFORE returning JSON"
      assert_includes system_prompt, "Remove identifying details rather than refusing to search"
      assert_includes system_prompt, "Do not return null merely"
      assert_includes system_prompt, "not answering the question or writing the assignment"
      assert_equal({ "type" => "json_object" }, response_format)
      JSON.generate("query" => query)
    end
    with_replaced_method(self, :ai_ask, planner) do
      with_replaced_method(self, :exa_search_response, ->(outgoing) { observed << outgoing; search_result }) do
        events = []
        result = ai_prepare_web_search(data, messages) { |event| events << event }
        assert_equal query, result["query"]
        assert_equal %w[preparing_search searching sources], events.map { |event| event["type"] }
      end
    end
    assert_equal [query], observed
  end

  def test_handoff_automatically_removes_known_names_and_credentials_before_search
    data = { "profile" => { "name" => "Emberlynn Example" }, "course_names" => { "7" => "History - Bush" } }
    generated = "  EMBERLYNN Example's Bush's definitions: 3/4 and 50% #{TOKEN}  "
    query = "definitions: 3/4 and 50%"
    calls = []
    with_replaced_method(self, :ai_ask, ->(*) { JSON.generate("query" => generated) }) do
      with_replaced_method(self, :exa_search_response, ->(outgoing) { calls << outgoing; search_result }) do
        result = ai_prepare_web_search(data, [])
        assert_equal query, result["query"]
      end
    end
    assert_equal [query], calls
  end

  def test_uncertain_or_empty_material_never_reaches_search
    data = { "profile" => { "name" => "Emberlynn Example" } }
    with_replaced_method(self, :exa_search_response, ->(*) { flunk "Private or uncertain query was sent" }) do
      [nil, [], {}, 42, "", "ab", "Emberlynn Example", TOKEN, "x" * (WEB_SEARCH_MAX_QUERY_CHARS + 1)].each do |query|
        with_replaced_method(self, :ai_ask, ->(*) { JSON.generate("query" => query) }) do
          assert_raises(WebSearchUnavailable) { ai_prepare_web_search(data, []) }
        end
      end
      ["Not valid JSON", "[]", "null"].each do |answer|
        with_replaced_method(self, :ai_ask, ->(*) { answer }) do
          assert_raises(WebSearchUnavailable) { ai_prepare_web_search(data, []) }
        end
      end
    end
  end

  def test_only_known_student_and_teacher_names_trigger_the_privacy_check
    data = {
      "profile" => { "name" => "Emberlynn Example", "short_name" => "Emmy", "sortable_name" => "Example, Emberlynn" },
      "course_names" => { "7" => "History - Bush", "8" => "Science – Li", "9" => "Math - O'Neil", "10" => "Art - García" }
    }
    %w[Emberlynn EXAMPLE emmy Bush Li O'Neil García].each do |name|
      query = "Practice for #{name}'s class"
      assert_raises(WebSearchUnavailable, name) { ai_validate_public_query(query, data) }
      cleaned = ai_sanitize_public_query(query, data)
      assert_equal "Practice for class", cleaned
      assert_equal cleaned, ai_validate_public_query(cleaned, data)
    end
    query = "History of bushland and lithium in science"
    assert_equal query, ai_sanitize_public_query(query, data)
    assert_equal query, ai_validate_public_query(query, data)
    assert_equal "Nile River", ai_validate_public_query("Nile River", {})
  end

    def test_malformed_handoff_is_retried_locally_before_one_external_search
      attempts = []
      calls = []
      responses = ["I can help you outline the assignment, but cannot write it for you.", '{"query":"middle school theatre reflection writing structure"}']
      planner = lambda do |_data, messages, system_prompt:, response_format:|
        attempts << system_prompt
        assert_equal [{ "role" => "user", "content" => "Show me a six sentence response" }], messages
        assert_equal({ "type" => "json_object" }, response_format)
        responses.shift
      end
      with_replaced_method(self, :ai_ask, planner) do
        with_replaced_method(self, :exa_search_response, ->(query) { calls << query; search_result }) do
          events = []
          capture_io do
            result = ai_prepare_web_search({}, [{ "role" => "user", "content" => "Show me a six sentence response" }]) { |event| events << event }
            assert_equal "middle school theatre reflection writing structure", result["query"]
          end
          assert_equal %w[preparing_search retrying_search searching sources], events.map { |event| event["type"] }
          assert_equal "format", events[1]["reason"]
          assert_equal "Fixing search formatting locally", events[1]["message"]
        end
      end
      assert_equal 2, attempts.length
      assert_includes attempts.last, "Correct the previous local preparation issue"
      assert_equal ["middle school theatre reflection writing structure"], calls
    end

    def test_persistent_format_failure_explains_that_it_is_not_a_privacy_violation
      count = 0
      with_replaced_method(self, :ai_ask, ->(*) { count += 1; "Unstructured response with private details" }) do
        with_replaced_method(self, :exa_search_response, ->(*) { flunk "Unreadable handoff was sent to the web" }) do
          output, = capture_io do
            error = assert_raises(WebSearchPreparationError) { ai_prepare_web_search({}, []) }
            assert_equal :format, error.reason
            assert_includes error.message, "not a privacy violation"
            assert_includes error.message, "turn off Search the web"
            refute_includes error.message, "private details"
          end
          refute_includes output, "private details"
        end
      end
      assert_equal 2, count
    end

    def test_format_topic_length_and_names_failures_have_distinct_feedback
      ["not JSON", "[]", "null", '{"topic":"fractions"}', '{"query":42}'].each do |answer|
        error = assert_raises(WebSearchPreparationError) { ai_public_query_from_response(answer, {}) }
        assert_equal :format, error.reason
      end
      error = assert_raises(WebSearchPreparationError) { ai_public_query_from_response('{"query":null}', {}) }
      assert_equal :topic, error.reason
      assert_includes error.message, "lesson, assignment topic, or vocabulary words"
      error = assert_raises(WebSearchPreparationError) { ai_validate_public_query("x" * (WEB_SEARCH_MAX_QUERY_CHARS + 1), {}) }
      assert_equal :length, error.reason
      assert_includes error.message, "too long"
      data = { "profile" => { "name" => "Avery Student" } }
      error = assert_raises(WebSearchPreparationError) { ai_validate_public_query("Study for Avery", data) }
      assert_equal :names, error.reason
      assert_includes error.message, "student or teacher name"
      refute_includes error.message, "Avery"
      error = assert_raises(WebSearchPreparationError) { ai_public_query_from_response('{"query":"Avery Student"}', data) }
      assert_equal :topic, error.reason
      assert_includes error.message, "After removing a student or teacher name"
    end

    def test_unclear_and_overlong_requests_can_be_repaired_locally
      [nil, "x" * (WEB_SEARCH_MAX_QUERY_CHARS + 1)].each do |first_query|
        responses = [JSON.generate("query" => first_query), '{"query":"fraction practice"}']
        calls = []
        with_replaced_method(self, :ai_ask, ->(*) { responses.shift }) do
          with_replaced_method(self, :exa_search_response, ->(query) { calls << query; search_result }) do
            capture_io { assert_equal "fraction practice", ai_prepare_web_search({}, [])["query"] }
          end
        end
        assert_empty responses
        assert_equal ["fraction practice"], calls
      end
    end

  def test_configured_secrets_are_removed_without_privacy_warnings
    saved_password = ENV["GMAIL_APP_PASSWORD"]
    ENV["GMAIL_APP_PASSWORD"] = "environment-password"
    with_replaced_method(self, :ai_settings, -> { { "api_key" => "local-api-secret" } }) do
      with_replaced_method(self, :options, -> { { "gmail_app_password" => "configured-password" } }) do
        query = "#{TOKEN} local-api-secret configured-password environment-password study guide"
        assert_equal "study guide", ai_sanitize_public_query(query, {})
      end
    end
  ensure
    ENV["GMAIL_APP_PASSWORD"] = saved_password
  end

  def test_public_educational_wording_is_allowed_without_changing_the_query
    [
      "6th grade vocabulary definitions for Egypt and Kush",
      "sixth-grade student study guide for geography",
      "Grade 6 teacher resources about vegetation",
      "Percent practice and missing number problems",
      "Definitions of grade, score, submitted, and overdue",
      "What factors affect river grades and musical scores?"
    ].each do |query|
      assert_equal query, ai_validate_public_query(query, {})
    end
  end

  def test_study_queries_no_longer_trigger_broad_private_data_patterns
    [
      "6th grade vocabulary; her grade is B",
      "Grade 6 student guide; my science score is 89",
      "Her current math grade needs help",
      "Avery's quiz score is low",
      "missing assignments about geography",
      "overdue homework on Egypt",
      "submitted work about rivers",
      "student name Avery geography",
      "teacher email for study guide",
      "grade: 89 geography help",
      "score A geography",
      "6th grade guide with 89%",
      "6th grade guide; score 9/10",
      "student guide; contact parent@example.com",
      "Read https://school.example/study",
      "Student ID 12345678",
      "Quiz on 2026-10-23",
      "How to calculate GPA",
      "What is an API key or password token?",
      "Convert 3/4 to 75%"
    ].each do |query|
      assert_equal query, ai_validate_public_query(query, {})
      assert_equal query, ai_sanitize_public_query(query, {})
    end
  end

  def test_handoff_sends_study_terms_that_previously_triggered_privacy_blocks
    queries = ["Practice 3/4 and 50%", "Missing assignments study planning", "History timeline 2026-10-23", "My grade is 89%"]
    calls = []
    with_replaced_method(self, :exa_search_response, ->(query) { calls << query; search_result }) do
      queries.each do |query|
        with_replaced_method(self, :ai_ask, ->(*) { JSON.generate("query" => query) }) do
          assert_equal query, ai_prepare_web_search({}, [])["query"]
        end
      end
    end
    assert_equal queries, calls
  end

  def test_search_returns_bounded_deduplicated_numbered_sources
    body = search_result
    body["content"][0]["text"] += <<~TEXT

      ---

      Title: Unsafe
      URL: javascript:alert(1)
      Highlights:
      No

      Title: Long source
      URL: https://example.com/long
      Highlights:
      #{"x" * 5000}

      Title: Duplicate
      URL: https://example.com/geography
      Highlights:
      Again
    TEXT
    calls = []
    events = []
    result = with_replaced_method(self, :exa_search_response, ->(query) { calls << query; body }) do
      ai_web_search("Egypt geography") { |event| events << event }
    end
    assert_equal ["Egypt geography"], calls
    assert_equal %w[searching sources], events.map { |event| event["type"] }
    assert_equal [1, 2], result["sources"].map { |source| source["id"] }
    assert_equal WEB_SEARCH_MAX_TEXT_CHARS, result["sources"].last["text"].length
    refute events.last["sources"].first.key?("text")
    assert_equal "Egypt geography", events.last["query"]
    prompt = ai_system_prompt({}, "PRIVATE CLASS NOTES", web_search: result)
    assert_includes prompt, "PRIVATE CLASS NOTES"
    assert_includes prompt, "The Nile supported agriculture."
    assert_includes prompt, "untrusted reference material"
    assert_includes prompt, "authoritative"
    many = { "content" => 8.times.map { |i| { "type" => "text", "text" => "Title: Page #{i}\nURL: https://example.com/#{i}\nHighlights:\nUseful text" } } }
    assert_equal 4, web_search_sources(many).length
  end

  def test_unreadable_or_empty_sources_fail_explicitly
    [nil, [], {}, { "content" => nil }, { "content" => [] },
     { "content" => [{ "type" => "text", "text" => "Unknown result format" }] }].each do |body|
      with_replaced_method(self, :exa_search_response, ->(*) { body }) do
        assert_raises(WebSearchUnavailable) { ai_web_search("geography") }
      end
    end
    ["data:text/html,hello", "javascript:alert(1)", "https://user:pass@example.com", "http://[", nil].each do |url|
      assert_nil web_search_source_url(url)
    end
  end

  def with_mcp_responses(responses)
    requests = []
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      requests << request
      response, body, headers = responses.shift
      raise "Unexpected request" unless response

      reply = Net::HTTPResponse::CODE_TO_OBJ.fetch(response).new("1.1", response, "test")
      (headers || {}).each { |name, value| reply[name] = value }
      reply.define_singleton_method(:read_body) { |&read| read.call(body) }
      block.call(reply)
    end
    start = lambda do |host, port, **kwargs, &block|
      assert_equal "mcp.exa.ai", host
      assert_equal 443, port
      assert_equal true, kwargs[:use_ssl]
      block.call(http)
    end
    with_replaced_method(Net::HTTP, :start, start) { yield requests }
  end

  def rpc(id, result)
    JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
  end

  def handshake_responses
    [
      ["200", rpc(1, "protocolVersion" => "2025-03-26"), { "Mcp-Session-Id" => "test-session" }],
      ["202", ""],
      ["200", rpc(2, "tools" => [{
        "name" => "web_search_exa",
        "inputSchema" => { "properties" => { "query" => {}, "numResults" => {}, "objective" => {} } }
      }])]
    ]
  end

  def test_keyless_mcp_handshake_session_and_sse_search
    result = search_result
    sse = ": keepalive\r\n\r\nevent: message\r\ndata: #{rpc(3, result)}\r\n\r\n"
    with_mcp_responses(handshake_responses + [["200", sse]]) do |requests|
      assert_equal result, exa_search_response("Egypt geography")
      payloads = requests.map { |request| JSON.parse(request.body) }
      assert_equal %w[initialize notifications/initialized tools/list tools/call], payloads.map { |payload| payload["method"] }
      refute payloads[1].key?("id")
      assert_equal "test-session", requests.last["Mcp-Session-Id"]
      assert_equal "2025-03-26", requests.last["MCP-Protocol-Version"]
      assert_equal "/mcp?tools=web_search_exa", requests.last.path
      assert_nil requests.last["Authorization"]
      assert_nil requests.last["x-api-key"]
      assert_equal "web_search_exa", payloads.last.dig("params", "name")
      arguments = payloads.last.dig("params", "arguments")
      assert_equal "Egypt geography", arguments["query"]
      assert_equal 4, arguments["numResults"]
      assert_equal %w[numResults objective query], arguments.keys.sort
      refute_includes requests.map(&:body).join, "test-token"
    end
  end

  def test_http_errors_oversize_and_network_failures_are_visible_without_provider_body
    %w[401 403 402 429 500].each do |code|
      with_mcp_responses([[code, "private provider error"]]) do
        error = assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
        refute_includes error.message, "private provider error"
        refute_match(/\bExa\b/, error.message)
      end
    end
    with_mcp_responses([["200", "x" * (WEB_SEARCH_MAX_RESPONSE_BYTES + 1)]]) do
      assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
    end
    with_replaced_method(Net::HTTP, :start, ->(*) { raise Net::ReadTimeout }) do
      error = assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
      assert_includes error.message, "Couldn't reach the web-search service"
    end
  end

  def test_malformed_rpc_tool_error_and_missing_tool_do_not_silently_succeed
    ["not json", rpc(5, {}), '{"jsonrpc":"2.0","id":1,"error":{"message":"private"}}'].each do |body|
      with_mcp_responses([["200", body]]) { assert_raises(WebSearchUnavailable) { exa_search_response("geography") } }
    end
    with_mcp_responses([["200", rpc(1, "protocolVersion" => "unknown")]]) do
      assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
    end
    responses = handshake_responses
    responses[2] = ["200", rpc(2, "tools" => [])]
    with_mcp_responses(responses) { assert_raises(WebSearchUnavailable) { exa_search_response("geography") } }
    with_mcp_responses(handshake_responses + [["200", rpc(3, "isError" => true, "content" => [])]]) do
      assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
    end
  end
end
