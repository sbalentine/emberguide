require_relative "test_helper"

class WebSearchTest < Minitest::Test
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
    planner = lambda do |local_data, local_messages, system_prompt:|
      assert_equal data, local_data
      assert_equal messages, local_messages
      assert_includes system_prompt, "topography, vegetation, factors"
      assert_includes system_prompt, "no grades, scores"
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

  def test_handoff_rejects_private_data_or_uncertain_material_before_any_search
    data = { "profile" => { "name" => "Emberlynn Example" }, "course_names" => { "7" => "History - Bush" } }
    rejected = [
      "Definitions for Emberlynn", "Definitions for Bush", "My grade is 89%", "Score 9/10",
      "Contact parent@example.com", "Read https://school.example/study", "Student ID 12345678",
      "Definitions and #{TOKEN}", "Quiz on 2026-10-23", nil
    ]
    with_replaced_method(self, :exa_search_response, ->(*) { flunk "Private or uncertain query was sent" }) do
      rejected.each do |query|
        with_replaced_method(self, :ai_ask, ->(*) { JSON.generate("query" => query) }) do
          assert_raises(WebSearchUnavailable) { ai_prepare_web_search(data, []) }
        end
      end
      with_replaced_method(self, :ai_ask, ->(*) { "Not valid JSON" }) do
        assert_raises(WebSearchUnavailable) { ai_prepare_web_search(data, []) }
      end
    end
    assert_equal "Definitions for Nile River", ai_validate_public_query("Definitions for Nile River", data)
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
      end
    end
    with_mcp_responses([["200", "x" * (WEB_SEARCH_MAX_RESPONSE_BYTES + 1)]]) do
      assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
    end
    with_replaced_method(Net::HTTP, :start, ->(*) { raise Net::ReadTimeout }) do
      error = assert_raises(WebSearchUnavailable) { exa_search_response("geography") }
      assert_includes error.message, "Couldn't reach Exa"
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
