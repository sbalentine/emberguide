require "net/http"
require "json"
require "uri"
require "date"

# ============================================================
# Configuration
# ============================================================

def options
  if File.exist?("/data/options.json")
    JSON.parse(
      File.read("/data/options.json")
    )
  else
    {
      "canvas_token" => ENV["CANVAS_TOKEN"],
      "token_expires" => ENV["TOKEN_EXPIRES"],
      "canvas_url" => ENV["CANVAS_URL"],
      "gmail_sender" => ENV["GMAIL_SENDER"],
      "gmail_app_password" => ENV["GMAIL_APP_PASSWORD"]
    }
  end
end

def load_token
  token = options["canvas_token"]

  if token.nil? || token.strip.empty?
    raise(
      "Canvas token is not configured. " \
      "Set CANVAS_TOKEN locally or configure " \
      "canvas_token in Home Assistant."
    )
  end

  token
end

def load_base_url
  url = options["canvas_url"]

  if url.nil? || url.strip.empty?
    raise(
      "Canvas base URL is not configured. " \
      "Set CANVAS_URL locally or configure " \
      "canvas_url in Home Assistant."
    )
  end

  url = url.strip.sub(%r{/+\z}, "")
  uri = URI.parse(url)

  unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
    raise(
      "Canvas base URL must be an https URL, " \
      "for example https://your-school.instructure.com."
    )
  end

  url
rescue URI::InvalidURIError
  raise(
    "Canvas base URL must be an https URL, " \
    "for example https://your-school.instructure.com."
  )
end

def token_expiration
  value = options["token_expires"]

  return nil if value.nil? || value.strip.empty?

  Date.parse(value)
rescue ArgumentError
  nil
end

def token_days_remaining
  expiration = token_expiration

  return nil unless expiration

  (expiration - Date.today).to_i
end

BASE_URL = load_base_url
TOKEN = load_token

# ============================================================
# Canvas API
# ============================================================

def canvas_get(path)
  JSON.parse(canvas_get_response(path).body)
end

def canvas_get_all(path)
  items = []
  visited = {}

  while path
    raise "Canvas pagination repeated a page." if visited[path]

    visited[path] = true
    response = canvas_get_response(path)
    page = JSON.parse(response.body)
    raise "Canvas returned an invalid collection." unless page.is_a?(Array)

    items.concat(page)
    next_link = response["Link"].to_s.split(",").find do |link|
      link.match?(/;\s*rel="next"/)
    end
    path = nil
    next unless next_link

    next_url = next_link[/<([^>]+)>/, 1]
    raise "Canvas returned an invalid pagination link." unless next_url

    uri = URI.join("#{BASE_URL}/", next_url)
    base = URI(BASE_URL)
    unless uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port
      raise "Canvas pagination link points outside the configured Canvas site."
    end

    path = uri.request_uri
  end

  items
end

def canvas_get_response(path)
  uri = URI("#{BASE_URL}#{path}")

  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{TOKEN}"

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: true,
    open_timeout: 10,
    read_timeout: 30
  ) do |http|
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    raise(
      "Canvas API error: " \
      "#{response.code} #{response.message}"
    )
  end

  response
end

def canvas_form_request(method, path, fields)
  uri = URI("#{BASE_URL}#{path}")

  request_class =
    case method
    when :post
      Net::HTTP::Post
    when :put
      Net::HTTP::Put
    else
      raise ArgumentError, "Unsupported Canvas request method"
    end

  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{TOKEN}"
  request.set_form_data(fields)

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: true,
    open_timeout: 10,
    read_timeout: 30
  ) do |http|
    http.request(request)
  end

  unless response.is_a?(Net::HTTPSuccess)
    raise(
      "Canvas API error: " \
      "#{response.code} #{response.message}"
    )
  end

  JSON.parse(response.body)
end