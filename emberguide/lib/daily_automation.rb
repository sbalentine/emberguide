DAILY_OVERVIEW_FILE = ENV.fetch("DAILY_OVERVIEW_FILE") do
  File.join(File.dirname(CACHE_FILE), "daily_overview.json")
end
DAILY_AUTOMATION_HOUR = 5
DAILY_OVERVIEW_MAX_ATTEMPTS = 3
DAILY_OVERVIEW_RETRY_SECONDS = 20 * 60
$daily_overview_cache_mutex = Mutex.new
$daily_overview_generation_mutex = Mutex.new

class DailyAutomationError < StandardError; end

def load_daily_overview_state
  $daily_overview_cache_mutex.synchronize do
    return {} unless File.exist?(DAILY_OVERVIEW_FILE)

    state = JSON.parse(File.read(DAILY_OVERVIEW_FILE))
    valid = state.is_a?(Hash) && state["date"].is_a?(String) &&
      Date.iso8601(state["date"]).iso8601 == state["date"] &&
      state["attempts"].is_a?(Integer) && state["attempts"].positive? &&
      state["attempted_at"].is_a?(String) &&
      parse_canvas_time(state["attempted_at"])
    if valid && state.key?("error")
      valid = state["error"].is_a?(String) && !state["error"].strip.empty?
    end
    if valid && state["overview"]
      valid = state["overview"].is_a?(Hash) &&
        valid_digest_overview_bullets?(state["overview"]["bullets"]) &&
        state["generated_at"].is_a?(String) &&
        (state["canvas_updated_at"].nil? || state["canvas_updated_at"].is_a?(String)) &&
        parse_canvas_time(state["generated_at"])&.getlocal&.to_date&.iso8601 == state["date"]
    end
    raise DailyAutomationError, "The daily overview cache is invalid." unless valid

    state
  end
rescue JSON::ParserError, Date::Error, SystemCallError, IOError => e
  raise DailyAutomationError, "Unable to read the daily overview cache (#{e.class})."
end

def save_daily_overview_state(state)
  $daily_overview_cache_mutex.synchronize do
    FileUtils.mkdir_p(File.dirname(DAILY_OVERVIEW_FILE))
    temporary = "#{DAILY_OVERVIEW_FILE}.tmp.#{SecureRandom.hex(8)}"
    begin
      File.write(temporary, JSON.pretty_generate(state), mode: "w", perm: 0o600)
      File.rename(temporary, DAILY_OVERVIEW_FILE)
    ensure
      FileUtils.rm_f(temporary)
    end
  end
rescue SystemCallError, IOError => e
  raise DailyAutomationError, "Unable to save the daily overview cache (#{e.class})."
end

def daily_overview_for_digest(now: Time.now)
  state = load_daily_overview_state
  if state["date"] == now.getlocal.to_date.iso8601 && state["overview"] &&
     parse_canvas_time(state["generated_at"]) <= now
    return state["overview"].merge(
      "generated_at" => state["generated_at"],
      "canvas_updated_at" => state["canvas_updated_at"]
    )
  end

  if state["date"] == now.getlocal.to_date.iso8601 && state["error"]
    return { "error" => "Spark couldn't prepare today's overview. Reason: #{state["error"]} The normal saved school details are included below." }
  end
  { "error" => "Today's Spark overview is not ready. The normal saved school details are included below." }
rescue DailyAutomationError => e
  puts "Daily digest overview unavailable: #{e.message}"
  { "error" => "Spark's cached overview is unavailable. Reason: #{e.message} The normal saved school details are included below." }
end

def clear_daily_overview_cache
  $daily_overview_cache_mutex.synchronize do
    File.delete(DAILY_OVERVIEW_FILE) if File.exist?(DAILY_OVERVIEW_FILE)
  end
rescue SystemCallError, IOError => e
  raise DailyAutomationError, "Unable to clear the daily overview cache (#{e.class})."
end

def generate_daily_overview(now: Time.now, force: false, raise_on_error: false)
  unless load_scheduled_email_settings["digest_spark_overview"]
    raise DailyAutomationError, "Enable Include Spark overview before generating it." if raise_on_error
    return false
  end
  unless $daily_overview_generation_mutex.try_lock
    raise DailyAutomationError, "An overview is already being generated. Wait for it to finish before trying again." if raise_on_error
    return false
  end

  begin
    today = now.getlocal.to_date.iso8601
    state = begin
      load_daily_overview_state
    rescue DailyAutomationError => e
      raise unless force

      puts "Daily overview cache will be regenerated on request: #{e.message}"
      {}
    end
    state = { "date" => today, "attempts" => 0 } unless state["date"] == today
    unless force
      return false if now.getlocal.hour < DAILY_AUTOMATION_HOUR || state["overview"]
      return false if state["attempts"] >= DAILY_OVERVIEW_MAX_ATTEMPTS
      attempted_at = parse_canvas_time(state["attempted_at"])
      return false if attempted_at && now - attempted_at < DAILY_OVERVIEW_RETRY_SECONDS
    end

    state["attempts"] += 1
    state["attempted_at"] = now.iso8601
    save_daily_overview_state(state)
    digest = digest_data(now: now, include_overview: false)
    overview = digest_spark_overview(digest, now)
    if overview["error"]
      state["error"] = overview["error"]
    else
      state["overview"] = overview
      state["generated_at"] = now.iso8601
      state["canvas_updated_at"] = digest["data"]["updated_at"]
      state.delete("error")
    end
    save_daily_overview_state(state)
    raise DailyAutomationError, overview["error"] if overview["error"] && raise_on_error
    !overview["error"]
  ensure
    $daily_overview_generation_mutex.unlock
  end
end

def run_daily_automations(now = Time.now)
  generate_daily_overview(now: now)
rescue DailyAutomationError => e
  puts "Daily automation failed: #{e.message}"
  false
end

def start_daily_automation_thread
  Thread.new do
    loop do
      run_daily_automations
      sleep 60
    end
  end
end
