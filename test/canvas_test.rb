require_relative "test_helper"

class CanvasTest < Minitest::Test
  def test_collection_follows_pagination
    first = http_response(Net::HTTPOK, '[{"id":1}]', "200", "OK")
    first["Link"] = "<#{BASE_URL}/api/v1/courses/1/modules?page=2>; rel=\"next\""
    second = http_response(Net::HTTPOK, '[{"id":2}]', "200", "OK")
    paths = []
    responses = [first, second]
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      paths << request.path
      responses.shift
    end
    result = with_replaced_method(Net::HTTP, :start, ->(*, **, &block) { block.call(fake_http) }) do
      canvas_get_all("/api/v1/courses/1/modules")
    end
    assert_equal [1, 2], result.map { |item| item["id"] }
    assert_equal ["/api/v1/courses/1/modules", "/api/v1/courses/1/modules?page=2"], paths
  end

  def test_collection_rejects_external_and_cyclic_pagination_and_non_arrays
    [
      ['[]', '<https://other.example/api>; rel="next"', /outside/],
      ['[]', "<#{BASE_URL}/api/test>; rel=\"next\"", /repeated/],
      ['{}', nil, /invalid collection/]
    ].each do |body, link, message|
      response = http_response(Net::HTTPOK, body, "200", "OK")
      response["Link"] = link if link
      error = with_replaced_method(self, :canvas_get_response, ->(_) { response }) do
        assert_raises(RuntimeError) { canvas_get_all("/api/test") }
      end
      assert_match message, error.message
    end
  end

  def http_response(response_class, body, code, message)
    response = response_class.new("1.1", code, message)
    response.instance_variable_set(:@read, true)
    response.body = body
    response
  end

  def test_options_and_token_expiration_use_environment
    ENV["CANVAS_TOKEN"] = "environment-token"
    ENV["TOKEN_EXPIRES"] = (Date.today + 5).iso8601

    assert_equal "environment-token", options["canvas_token"]
    assert_equal Date.today + 5, token_expiration
    assert_equal 5, token_days_remaining
  ensure
    ENV["CANVAS_TOKEN"] = "test-token"
    ENV.delete("TOKEN_EXPIRES")
  end

  def test_invalid_or_missing_token_values
    ENV["CANVAS_TOKEN"] = " "
    error = assert_raises(RuntimeError) { load_token }
    assert_match(/not configured/, error.message)

    ENV["TOKEN_EXPIRES"] = "not-a-date"
    assert_nil token_expiration
  ensure
    ENV["CANVAS_TOKEN"] = "test-token"
    ENV.delete("TOKEN_EXPIRES")
  end

  def test_base_url_uses_environment
    ENV["CANVAS_URL"] = " https://example.instructure.com/ "

    assert_equal "https://example.instructure.com", load_base_url
  ensure
    ENV["CANVAS_URL"] = "https://temecula.instructure.com"
  end

  def test_base_url_uses_home_assistant_options
    ENV["CANVAS_URL"] = "https://environment.instructure.com"
    options_path = "/data/options.json"
    exist = ->(path) { path == options_path }
    read = lambda do |path|
      assert_equal options_path, path
      JSON.generate("canvas_url" => "https://ha.instructure.com")
    end

    result = with_replaced_method(File, :exist?, exist) do
      with_replaced_method(File, :read, read) { load_base_url }
    end

    assert_equal "https://ha.instructure.com", result
  ensure
    ENV["CANVAS_URL"] = "https://temecula.instructure.com"
  end

  def test_missing_or_blank_base_url
    [nil, " "].each do |value|
      value.nil? ? ENV.delete("CANVAS_URL") : ENV["CANVAS_URL"] = value

      error = assert_raises(RuntimeError) { load_base_url }
      assert_match(/Canvas base URL is not configured/, error.message)
      assert_match(/CANVAS_URL/, error.message)
      assert_match(/canvas_url in Home Assistant/, error.message)
    end
  ensure
    ENV["CANVAS_URL"] = "https://temecula.instructure.com"
  end

  def test_invalid_base_url
    ["temecula.instructure.com", "http://temecula.instructure.com", "https://", "https://bad host"].each do |value|
      ENV["CANVAS_URL"] = value

      error = assert_raises(RuntimeError) { load_base_url }
      assert_match(/must be an https URL/, error.message)
    end
  ensure
    ENV["CANVAS_URL"] = "https://temecula.instructure.com"
  end

  def test_canvas_get_sends_bearer_token_and_parses_json
    response = http_response(Net::HTTPOK, '{"id":123}', "200", "OK")
    request_seen = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      request_seen = request
      response
    end

    start = lambda do |host, port, **options, &block|
      assert_equal "temecula.instructure.com", host
      assert_equal 443, port
      assert_equal true, options[:use_ssl]
      block.call(fake_http)
    end

    result = with_replaced_method(Net::HTTP, :start, start) do
      canvas_get("/api/v1/users/self/profile")
    end

    assert_equal({ "id" => 123 }, result)
    assert_equal "Bearer test-token", request_seen["Authorization"]
  end

  def test_canvas_form_request_encodes_fields_and_rejects_unknown_method
    response = http_response(Net::HTTPOK, '{"id":7}', "200", "OK")
    request_seen = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      request_seen = request
      response
    end

    result = with_replaced_method(Net::HTTP, :start, ->(*, **, &block) { block.call(fake_http) }) do
      canvas_form_request(:post, "/api/v1/planner_notes", "title" => "Read chapter")
    end

    assert_equal({ "id" => 7 }, result)
    assert_instance_of Net::HTTP::Post, request_seen
    assert_equal "title=Read+chapter", request_seen.body
    assert_raises(ArgumentError) { canvas_form_request(:delete, "/anything", {}) }
  end

  def test_canvas_errors_include_http_status
    response = http_response(Net::HTTPUnauthorized, "no", "401", "Unauthorized")
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_request| response }

    error = with_replaced_method(Net::HTTP, :start, ->(*, **, &block) { block.call(fake_http) }) do
      assert_raises(RuntimeError) { canvas_get("/api/v1/users/self/profile") }
    end

    assert_match(/401 Unauthorized/, error.message)
  end
end