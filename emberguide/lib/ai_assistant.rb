require "date"
require "fileutils"
require "net/http"
require "set"
require "json"
require "uri"

# Spark: optional homework helper backed by a llama.cpp server (llama-server) or any
# OpenAI-compatible chat endpoint on the local network. Answers come only from
# the class data EmberGuide has already saved; nothing is fetched from Canvas
# at question time and the Canvas token is never sent.

# Instructions are never cut short; this only guards against a runaway cache.
AI_CONTEXT_MAX_CHARS = 400_000
AI_MAX_MESSAGES = 12
AI_MAX_MESSAGE_CHARS = 2_000
AI_RECENT_GRADES = 12
AI_NAME = "Spark"
AI_OPEN_TIMEOUT = 3
AI_READ_TIMEOUT = 120
AI_DEFAULT_MODEL_SECONDS = 300
# Router-mode llama-server reports each model as loaded, sleeping, or unloaded;
# Automatic prefers a model that can answer without loading first.
AI_MODEL_STATE_ORDER = %w[loaded sleeping].freeze

SPARK_SETTINGS_FILE = ENV.fetch("SPARK_SETTINGS_FILE") do
  if File.directory?("/data")
    "/data/spark_settings.json"
  else
    File.expand_path("../tmp/spark_settings.json", __dir__)
  end
end

$ai_default_model = nil

class AiUnavailable < StandardError; end
class AiContextTooSmall < AiUnavailable; end
# Raised when the browser disconnects mid-stream; kept apart from network
# errors so it isn't reported as the server being offline.
class AiClientGone < StandardError; end

# The server address and key live in add-on options or .env; the model is
# picked on Settings → Spark from what the server has installed.
def ai_settings
  settings = options
  url = (settings["llm_url"] || ENV["LLM_URL"]).to_s.strip
  {
    "url" => url.empty? ? nil : url.sub(%r{/+\z}, "").sub(%r{/v1\z}, ""),
    "api_key" => (settings["llm_api_key"] || ENV["LLM_API_KEY"]).to_s.strip,
    "model" => load_spark_settings["model"].to_s.strip
  }
end

def load_spark_settings
  saved = JSON.parse(File.read(SPARK_SETTINGS_FILE))
  saved.is_a?(Hash) ? saved : {}
rescue Errno::ENOENT, JSON::ParserError
  {}
end

# Saves the chosen model, or "" for Automatic. Only models the server lists
# can be chosen, so the page can't be used to send arbitrary values.
def save_spark_model(model, available_ids)
  model = model.to_s.strip
  raise ArgumentError, "That model isn't installed on the Spark server." unless model.empty? || available_ids.include?(model)

  FileUtils.mkdir_p(File.dirname(SPARK_SETTINGS_FILE))
  temporary_file = "#{SPARK_SETTINGS_FILE}.tmp"
  File.write(temporary_file, JSON.pretty_generate("model" => model))
  File.rename(temporary_file, SPARK_SETTINGS_FILE)
  $ai_default_model = nil
  model
end

def ai_enabled?
  !ai_settings["url"].nil?
end

def ai_http(uri, request, read_timeout: AI_READ_TIMEOUT, &block)
  settings = ai_settings
  request["Authorization"] = "Bearer #{settings["api_key"]}" unless settings["api_key"].empty?
  Net::HTTP.start(
    uri.host, uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: AI_OPEN_TIMEOUT,
    read_timeout: read_timeout
  ) { |http| http.request(request, &block) }
rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, IOError => e
  puts "#{AI_NAME} unreachable: #{e.class}: #{e.message}"
  raise AiUnavailable, "#{AI_NAME} is offline. Make sure the gaming PC is on and llama-server is running."
end

def ai_online?
  url = ai_settings["url"]
  return false unless url

  ai_http(URI("#{url}/health"), Net::HTTP::Get.new("/health"), read_timeout: 3).is_a?(Net::HTTPSuccess)
rescue AiUnavailable, URI::InvalidURIError
  false
end

def ai_status(check_server: false)
  settings = ai_settings
  return { "enabled" => false, "online" => false } unless settings["url"]

  status = { "enabled" => true, "online" => ai_online?, "checked_at" => Time.now.iso8601 }
  status.merge!(ai_server_check(settings)) if check_server && status["online"]
  status
end

# Lists installed models as [{"id", "state", "context"}], or returns
# {"key_accepted" => false} / {} when the key is rejected or the server can't
# be read. Only these fields are kept; router mode also reports local paths.
# "context" is the context size the model was last loaded with, when known.
def ai_list_models(settings = ai_settings)
  response = ai_http(URI("#{settings["url"]}/v1/models"), Net::HTTP::Get.new("/v1/models"), read_timeout: 5)
  return { "key_accepted" => false } if [401, 403].include?(response.code.to_i)
  return {} unless response.is_a?(Net::HTTPSuccess)

  models = Array(JSON.parse(response.body)["data"]).filter_map do |model|
    next unless model.is_a?(Hash) && model["id"].is_a?(String)

    state = model["status"].is_a?(Hash) ? model.dig("status", "value").to_s : ""
    context = model["meta"].is_a?(Hash) ? model.dig("meta", "n_ctx") : nil
    { "id" => model["id"], "state" => state }.tap { |entry| entry["context"] = context if context.is_a?(Integer) }
  end
  { "key_accepted" => true, "models" => models }
rescue AiUnavailable, JSON::ParserError, URI::InvalidURIError
  {}
end

# Running models first, then sleeping ones; among those, the one with the most
# room for class notes.
def ai_default_model_id(models)
  models.min_by.with_index do |model, index|
    [AI_MODEL_STATE_ORDER.index(model["state"]) || AI_MODEL_STATE_ORDER.length, -model["context"].to_i, index]
  end&.fetch("id")
end

# Runs the block with the model to use. In Automatic mode, a model whose
# context is too small for the class notes is swapped for another installed
# model once.
def ai_with_model(settings)
  model = ai_model_for_request(settings)
  yield model
rescue AiContextTooSmall
  raise unless settings["model"].empty?

  fallback = ai_default_model_id(Array(ai_list_models(settings)["models"]).reject { |entry| entry["id"] == model })
  raise unless fallback

  $ai_default_model = [settings["url"], fallback, Time.now]
  yield fallback
end

# Turns a failed llama-server response into a message for the page.
def ai_response_error(response, body, model)
  error = JSON.parse(body.to_s)["error"]
  error = {} unless error.is_a?(Hash)
  if error["type"] == "exceed_context_size_error"
    raise AiContextTooSmall, "#{model} on the PC only has room for #{error["n_ctx"]} tokens, but #{AI_NAME}'s class notes need about " \
                             "#{error["n_prompt_tokens"]}. Pick a different model on Settings → #{AI_NAME}, or load this one with a larger --ctx-size."
  end
  detail = ai_trim(error["message"].to_s, 200)
  raise AiUnavailable, "#{AI_NAME} returned an error (HTTP #{response.code})#{": #{detail}" unless detail.empty?}."
rescue JSON::ParserError
  raise AiUnavailable, "#{AI_NAME} returned an error (HTTP #{response.code})."
end

# The chosen model, or for Automatic the server's best current choice,
# remembered briefly so each question doesn't list models first.
def ai_model_for_request(settings)
  return settings["model"] unless settings["model"].empty?

  cached_url, cached_model, cached_at = $ai_default_model
  return cached_model if cached_url == settings["url"] && cached_at && Time.now - cached_at < AI_DEFAULT_MODEL_SECONDS

  model = ai_default_model_id(Array(ai_list_models(settings)["models"]))
  $ai_default_model = [settings["url"], model, Time.now] if model
  model || "local"
end

# Confirms the API key is accepted and the chosen model is installed.
def ai_server_check(settings = ai_settings)
  listing = ai_list_models(settings)
  return listing unless listing["models"]

  ids = listing["models"].map { |model| model["id"] }
  result = { "key_accepted" => true, "models" => ids }
  if settings["model"].empty?
    result["model"] = ai_default_model_id(listing["models"])
    result["automatic"] = true
  else
    result["model"] = settings["model"]
    result["model_available"] = ids.include?(settings["model"])
  end
  result
end

def ai_system_prompt(data, context)
  name = profile_first_name(data)
  <<~PROMPT
    You are #{AI_NAME}, EmberGuide's homework helper for #{name}, a middle school student, and their parent.
    Answer using only the class data below. If the answer isn't in the data, say you don't see it in EmberGuide and suggest checking Canvas or asking the teacher.
    Tests, quizzes, and benchmarks matter most. When asked what to focus on, study, or prepare, check "Tests and quizzes coming up" first and lead with any test or quiz today or tomorrow, then later this week, then other due work and missing work. Weekday names in class announcements refer to the current week; that section shows which date each one falls on.
    Name the class and assignment you are talking about. Keep answers short, friendly, and clear for a middle schooler. Use short bullet lists for multiple items.
    Help #{name} understand and plan the work; don't write finished answers for graded assignments.

    #{context}
  PROMPT
end

# Keeps only well-formed chat turns from the browser, newest last, so a page
# can't inject system instructions or send an unbounded history.
def ai_clean_messages(messages)
  cleaned = Array(messages).filter_map do |message|
    next unless message.is_a?(Hash) && %w[user assistant].include?(message["role"])

    content = message["content"].to_s.strip[0, AI_MAX_MESSAGE_CHARS]
    { "role" => message["role"], "content" => content } unless content.empty?
  end.last(AI_MAX_MESSAGES)
  cleaned.shift while cleaned.first && cleaned.first["role"] != "user"
  raise ArgumentError, "Ask a question first." unless cleaned.last&.fetch("role") == "user"

  cleaned
end

def ai_chat_request(settings, model, data, messages, stream:)
  uri = URI("#{settings["url"]}/v1/chat/completions")
  request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
  body = {
    "model" => model,
    "messages" => [{ "role" => "system", "content" => ai_system_prompt(data, ai_class_context(data)) }] +
      ai_clean_messages(messages),
    "temperature" => 0.3,
    "max_tokens" => 800,
    "stream" => stream,
    "cache_prompt" => true,
    # Qwen3 and similar models otherwise write long hidden reasoning first.
    "chat_template_kwargs" => { "enable_thinking" => false }
  }
  # llama-server reports prompt-reading progress while streaming.
  body["return_progress"] = true if stream
  request.body = JSON.generate(body)
  [uri, request]
end

def ai_strip_thinking(text)
  text.gsub(%r{<think>.*?(</think>|\z)}m, "").strip
end

def ai_ask(data, messages)
  settings = ai_settings
  raise AiUnavailable, "#{AI_NAME} isn't set up." unless settings["url"]

  response = ai_with_model(settings) do |model|
    ai_http(*ai_chat_request(settings, model, data, messages, stream: false)).tap do |reply|
      ai_response_error(reply, reply.body, model) unless reply.is_a?(Net::HTTPSuccess)
    end
  end

  answer = ai_strip_thinking(JSON.parse(response.body).dig("choices", 0, "message", "content").to_s)
  raise AiUnavailable, "#{AI_NAME} sent back an empty answer." if answer.empty?

  answer
rescue JSON::ParserError
  raise AiUnavailable, "#{AI_NAME} sent back something EmberGuide couldn't read."
end

# Streams an answer, yielding progress and text events as llama-server sends
# them:
#   { "type" => "progress", "total", "cache", "processed", "time_ms" }
#   { "type" => "token", "text" }
# Returns the full answer.
def ai_ask_stream(data, messages)
  settings = ai_settings
  raise AiUnavailable, "#{AI_NAME} isn't set up." unless settings["url"]

  raw = +""
  # Errors arrive before any streamed text, so a retry never repeats output.
  ai_with_model(settings) do |model|
    ai_stream_answer(*ai_chat_request(settings, model, data, messages, stream: true), model, raw) { |event| yield event }
  end
  answer = ai_strip_thinking(raw)
  raise AiUnavailable, "#{AI_NAME} sent back an empty answer." if answer.empty?

  answer
rescue JSON::ParserError
  raise AiUnavailable, "#{AI_NAME} sent back something EmberGuide couldn't read."
end

# Reads one streamed llama-server reply into raw, yielding events.
def ai_stream_answer(uri, request, model, raw)
  sent = 0
  ai_http(uri, request) do |response|
    ai_response_error(response, response.read_body, model) unless response.is_a?(Net::HTTPSuccess)

    buffer = +""
    response.read_body do |chunk|
      buffer << chunk
      while (line_end = buffer.index("\n"))
        line = buffer.slice!(0..line_end).strip
        next unless line.start_with?("data:")

        payload = line.delete_prefix("data:").strip
        next if payload.empty? || payload == "[DONE]"

        event = JSON.parse(payload)
        if (progress = event["prompt_progress"]).is_a?(Hash)
          yield({ "type" => "progress" }.merge(progress.slice("total", "cache", "processed", "time_ms")))
        end
        delta = event.dig("choices", 0, "delta", "content")
        next unless delta.is_a?(String) && !delta.empty?

        raw << delta
        # Hold back a possible opening <think> tag until it's complete.
        next if raw.lstrip.length < 7 && "<think>".start_with?(raw.lstrip)

        visible = raw.gsub(%r{<think>.*?(</think>|\z)}m, "").lstrip
        if visible.length > sent
          yield({ "type" => "token", "text" => visible[sent..] })
          sent = visible.length
        end
      end
    end
  end
end

# ============================================================
# Class context
# ============================================================

def ai_time(time)
  time&.getlocal&.strftime("%a %b %-d, %-l:%M %p")
end

def ai_trim(text, limit)
  text = text.to_s.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
  text.length > limit ? "#{text[0, limit].rstrip}…" : text
end

def ai_course_names(data)
  data.fetch("course_names", {}).merge(load_course_name_mappings)
end

def ai_grade_lines(data, course_names, overrides)
  grades = combined_grade_submissions(data, overrides)
  by_course = grades.group_by { |submission| submission.dig("assignment", "course_id").to_s }
  summary = by_course.filter_map do |course_id, submissions|
    earned = submissions.sum { |submission| submission["score"].to_f }
    possible = submissions.sum { |submission| submission.dig("assignment", "points_possible").to_f }
    value = percentage(earned, possible)
    next unless value

    "- #{course_names[course_id] || course_id}: #{value.round}% (#{letter_grade(value)}), #{submissions.length} graded"
  end.sort

  recent = grades.sort_by { |submission| submission["graded_at"].to_s }.last(AI_RECENT_GRADES).reverse
  recent_lines = recent.map do |submission|
    course = course_names[submission.dig("assignment", "course_id").to_s]
    "- #{course}: #{submission.dig("assignment", "name")}: #{submission_status(submission)[:label]}"
  end
  [summary, recent_lines]
end

def ai_event_line(data, event, course_names)
  course = course_names[assignment_course_id(event).to_s] || event["context_name"]
  status = submission_status(submission_for(data, assignment_course_id(event), assignment_id(event)))[:label]
  "- #{course}: #{assignment_name(event)} (due #{ai_time(assignment_due_time(event)) || "no date"}; #{status})"
end

def ai_instruction_text(text)
  lines = text.to_s.lines.map { |line| line.gsub(/[ \t]+/, " ").strip }.reject { |line| line.empty? || line == "[Image]" }
  lines.map { |line| line.sub(/\A#+\s*(.+)\z/, '\1:') }.join("\n")
end

def ai_indented_instructions(text, indent)
  text = ai_instruction_text(text)
  text.empty? ? "" : "\n#{indent}  Instructions:\n#{text.gsub(/^/, "#{indent}    ")}"
end

def ai_module_item_line(item, overrides)
  return if item["type"] == "SubHeader"

  details = [item["type"]]
  due = parse_canvas_time(item.dig("content_details", "due_at"))
  details << "due #{ai_time(due)}" if due
  label, = module_item_status(item)
  details << [label, module_item_score(item, overrides)].compact.join(" ") if label
  indent = "  " * [item["indent"].to_i, 3].min
  "#{indent}- #{item["title"]} (#{details.join("; ")})#{ai_indented_instructions(item.dig("content", "text"), indent)}"
end

# Every open assignment (not graded, not locked) in visible classes with its
# full instructions, soonest due first. Assignments whose instructions already
# appear under this week's modules point there instead of repeating them.
def ai_open_assignment_lines(data, course_names, overrides, shown_ids)
  visible_ids = visible_module_courses(data).map { |course| course["id"].to_s }
  records = data.fetch("assignments", {}).flat_map do |course_id, assignments|
    next [] unless visible_ids.include?(course_id.to_s)

    Array(assignments).select do |record|
      assignment_open_for_ai?(record) && !canvas_assignment_hidden?(record, overrides)
    end.map { |record| [course_id.to_s, record] }
  end
  records.sort_by! do |_course_id, record|
    due = parse_canvas_time(record["due_at"])
    [due ? 0 : 1, due.to_i, record["name"].to_s]
  end

  records.map do |course_id, record|
    details = ["due #{ai_time(parse_canvas_time(record["due_at"])) || "no date"}", submission_status(record["submission"])[:label]]
    details << "#{format_number(record["points_possible"])} pts" if record["points_possible"].to_f.positive?
    line = "- #{course_names[course_id] || course_id}: #{record["name"]} (#{details.join("; ")})"
    if shown_ids.include?("#{course_id}:#{record["id"]}")
      "#{line}\n  Instructions: listed under This week in class."
    else
      line + ai_indented_instructions(record.dig("content", "text"), "")
    end
  end
end

AI_TEST_PATTERN = /\b(tests?|quiz(?:zes)?|exams?|benchmarks?|assessments?|midterms?)\b/i
AI_TEST_NOTE_MAX_CHARS = 140
AI_TESTS_PER_CLASS = 6
AI_WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

# Teachers usually announce tests in module headers and notes ("Unit 2 Test on
# Friday") rather than as Canvas assignments, so this pulls them together and
# says which date each weekday means. Weekdays refer to the current module's
# week; earlier days this week are skipped as already past.
def ai_test_day(text, now)
  today = now.getlocal.to_date
  return "" if text.match?(/\bnext\s+week\b/i)

  weekday = text.downcase[/\b(#{AI_WEEKDAYS.join("|")})\b/, 1] ||
    text.downcase[/\b(mon|tues|wednes|thurs|fri)(?:'s)?\b/, 1]&.then { |stem| "#{stem}day" }
  return "" unless weekday && (target = AI_WEEKDAYS.index(weekday))
  return :past if today.wday.between?(1, 5) && target < today.wday

  date = today + ((target - today.wday) % 7)
  when_text = case (date - today).to_i
              when 0 then "today"
              when 1 then "tomorrow"
              else date.strftime("%a %b %-d")
              end
  " (#{weekday.capitalize} = #{when_text}, #{date.strftime("%b %-d")})"
end

def ai_test_lines(data, upcoming_events, week_modules, course_names, now)
  seen = Hash.new { |hash, key| hash[key] = [] }
  lines = []
  add = lambda do |course, text, source|
    key = text.downcase.gsub(/[^a-z0-9]+/, " ").strip
    return if key.empty? || seen[course].include?(key) || seen[course].length >= AI_TESTS_PER_CLASS

    day = ai_test_day(text, now)
    return if day == :past

    seen[course] << key
    rank = day.include?("= today") ? 0 : day.include?("= tomorrow") ? 1 : 2
    lines << [rank, lines.length, "- #{course}: #{text}#{day} [#{source}]"]
  end

  upcoming_events.each do |event|
    next unless assignment_name(event).to_s.match?(AI_TEST_PATTERN)

    course = course_names[assignment_course_id(event).to_s] || event["context_name"]
    status = submission_status(submission_for(data, assignment_course_id(event), assignment_id(event)))[:label]
    next if status.start_with?("Graded", "Submitted")

    add.call(course, "#{assignment_name(event)} (due #{ai_time(assignment_due_time(event))}; #{status})", "assignment")
  end

  week_modules.each do |course, mod|
    module_announcements(mod).each do |note|
      add.call(course, note["title"].to_s.strip, "announcement") if note["title"].to_s.match?(AI_TEST_PATTERN)
    end
    Array(mod["items"]).each do |item|
      title = item["title"].to_s.strip
      if title.match?(AI_TEST_PATTERN)
        due = parse_canvas_time(item.dig("content_details", "due_at"))
        label, = module_item_status(item)
        next if (due && due < now) || %w[Graded Submitted].include?(label)

        add.call(course, due ? "#{title} (due #{ai_time(due)})" : title, "module")
      end
      ai_instruction_text(item.dig("content", "text")).each_line do |line|
        line = line.strip.sub(/\A[•*-]\s*/, "")
        add.call(course, line, "class notes") if line.length <= AI_TEST_NOTE_MAX_CHARS && line.match?(AI_TEST_PATTERN)
      end
      Array(item.dig("content", "linked_pages")).each do |page|
        title = page["title"].to_s
        add.call(course, title, "linked class page") if title.match?(AI_TEST_PATTERN)
        ai_instruction_text(page["text"]).each_line do |line|
          line = line.strip.sub(/\A[•*-]\s*/, "")
          add.call(course, line, "linked class page") if line.length <= AI_TEST_NOTE_MAX_CHARS && line.match?(AI_TEST_PATTERN)
        end
      end
    end
  end
  lines.sort.map(&:last)
end

def ai_class_context(data, now: Time.now)
  data = data || {}
  overrides = load_grade_overrides
  data = hide_assignments_from_dashboard(data, overrides)
  course_names = ai_course_names(data)
  week_end = now + (7 * 24 * 60 * 60)

  missing = Array(data["missing"]).map { |event| ai_event_line(data, event, course_names) }
  upcoming_events = Array(data["upcoming"]).select do |event|
    due = assignment_due_time(event)
    due && due >= now && due <= week_end
  end.sort_by { |event| assignment_due_time(event) }
  upcoming = upcoming_events.map { |event| ai_event_line(data, event, course_names) }
  grade_summary, recent_grades = ai_grade_lines(data, course_names, overrides)

  shown_ids = Set.new
  week_modules = visible_module_courses(data).filter_map do |course|
    course_id = course["id"].to_s
    mod = current_week_module(data.dig("modules", course_id))
    next unless mod

    items = Array(mod["items"]).map do |item|
      content = module_item_saved_content(data, course_id, item)
      assignment = module_item_assignment_id(item)
      shown_ids << "#{course_id}:#{assignment}" if assignment && !ai_instruction_text(content&.dig("text")).empty?
      content ? item.merge("content" => content) : item
    end
    [course_names[course_id] || course["name"], mod.merge("items" => items)]
  end
  weeks = week_modules.map do |course_name, mod|
    lines = ["### #{course_name}: #{mod["name"]}"]
    module_announcements(mod).each { |note| lines << "Announcement: #{note["title"]}" }
    lines.concat(Array(mod["items"]).filter_map { |item| ai_module_item_line(item, overrides) })
    linked_pages = Array(mod["items"]).flat_map { |item| Array(item.dig("content", "linked_pages")) }
      .uniq { |page| page["url"] }
    linked_pages.each do |page|
      lines << "Linked class page: #{page["title"]} (#{page["url"]})#{ai_indented_instructions(page["text"], "")}"
      lines << "  #{page["error"]}" if page["error"]
    end
    lines.join("\n")
  end
  tests = ai_test_lines(data, upcoming_events, week_modules, course_names, now)
  open_work = ai_open_assignment_lines(data, course_names, overrides, shown_ids)

  sections = [
    "# EmberGuide class data",
    "Today is #{now.getlocal.strftime("%A, %B %-d, %Y, %-l:%M %p")}. Canvas data last refreshed #{ai_time(parse_canvas_time(data["updated_at"])) || "unknown"}.",
    "## Tests and quizzes coming up (most important)\n#{tests.empty? ? "None found." : tests.join("\n")}",
    "## Classes and current grades\n#{grade_summary.empty? ? "No grades yet." : grade_summary.join("\n")}",
    "## Missing work\n#{missing.empty? ? "None." : missing.join("\n")}",
    "## Due in the next 7 days\n#{upcoming.empty? ? "Nothing due." : upcoming.join("\n")}",
    "## This week in class (each class's current module, in the teacher's order)\n#{weeks.empty? ? "No modules loaded." : weeks.join("\n\n")}",
    "## Open assignments and their instructions (not graded yet, soonest due first)\n#{open_work.empty? ? "None saved yet." : open_work.join("\n")}",
    "## Recently graded\n#{recent_grades.empty? ? "None." : recent_grades.join("\n")}"
  ]
  context = sections.join("\n\n")
  return context if context.length <= AI_CONTEXT_MAX_CHARS

  "#{context[0, AI_CONTEXT_MAX_CHARS].rstrip}\n…(trimmed to fit)"
end
