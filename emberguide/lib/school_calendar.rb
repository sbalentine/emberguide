require "date"
require "json"
require "net/http"
require "time"
require "uri"
require "fileutils"

SCHOOL_CALENDAR_SETTINGS_FILE = ENV.fetch("SCHOOL_CALENDAR_SETTINGS_FILE") do
  if File.directory?("/data")
    "/data/school_calendar_settings.json"
  else
    File.expand_path("../tmp/school_calendar_settings.json", __dir__)
  end
end

SCHOOL_CALENDAR_CACHE_SECONDS = 15 * 60
SCHOOL_CALENDAR_MAX_BYTES = 2 * 1024 * 1024
SCHOOL_CALENDAR_CHANGE_PATTERN = /
  \b(
    holiday|no\ school|school\ closed|district\ closed|recess|break|
    minimum\ day|early\ (?:release|dismissal)|late\ start|
    non-student|nonstudent|staff\ development|teacher\ workday|
    modified\ (?:day|schedule)
  )\b
/ix

$school_calendar_cache = nil
$school_calendar_mutex = Mutex.new

def load_school_calendar_settings
  return empty_school_calendar_settings unless File.exist?(SCHOOL_CALENDAR_SETTINGS_FILE)

  settings = JSON.parse(File.read(SCHOOL_CALENDAR_SETTINGS_FILE))
  {
    "feed_url" => settings.fetch("feed_url", "").to_s,
    "excluded_keywords" => Array(settings["excluded_keywords"]).map(&:to_s)
  }
rescue JSON::ParserError, TypeError
  puts "Unable to load school calendar settings."
  empty_school_calendar_settings
end

def empty_school_calendar_settings
  {
    "feed_url" => "",
    "excluded_keywords" => []
  }
end

def school_calendar_feed_url(value)
  url = value.to_s.strip
  return "" if url.empty?

  uri = URI.parse(url)
  unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil?
    raise ArgumentError, "Enter a valid HTTP or HTTPS calendar feed URL"
  end

  url
rescue URI::InvalidURIError
  raise ArgumentError, "Enter a valid HTTP or HTTPS calendar feed URL"
end

def school_calendar_excluded_keywords(value)
  keywords = value.to_s.split(/[\n,]/).map(&:strip).reject(&:empty?).uniq
  raise ArgumentError, "Add no more than 25 excluded keywords" if keywords.length > 25

  if keywords.any? { |keyword| keyword.length > 80 }
    raise ArgumentError, "Excluded keywords must be 80 characters or fewer"
  end

  keywords
end

def save_school_calendar_settings(feed_url, excluded_keywords = "")
  settings = {
    "feed_url" => school_calendar_feed_url(feed_url),
    "excluded_keywords" => school_calendar_excluded_keywords(excluded_keywords)
  }
  FileUtils.mkdir_p(File.dirname(SCHOOL_CALENDAR_SETTINGS_FILE))
  temporary_file = "#{SCHOOL_CALENDAR_SETTINGS_FILE}.tmp"
  File.write(temporary_file, JSON.pretty_generate(settings))
  File.rename(temporary_file, SCHOOL_CALENDAR_SETTINGS_FILE)

  $school_calendar_mutex.synchronize { $school_calendar_cache = nil }
  settings
end

def fetch_school_calendar(feed_url)
  uri = URI.parse(feed_url)
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "text/calendar"
  request["User-Agent"] = "EmberGuide"

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: 5,
    read_timeout: 10
  ) { |http| http.request(request) }

  unless response.is_a?(Net::HTTPSuccess)
    raise "Calendar feed returned HTTP #{response.code}"
  end

  body = response.body.to_s
  raise "Calendar feed is too large" if body.bytesize > SCHOOL_CALENDAR_MAX_BYTES

  body
end

def unfold_ics_lines(body)
  body.gsub(/\r\n?/, "\n").split("\n").each_with_object([]) do |line, lines|
    if line.start_with?(" ", "\t") && !lines.empty?
      lines[-1] += line[1..]
    else
      lines << line
    end
  end
end

def ics_text(value)
  value.to_s
    .gsub(/\\[nN]/, "\n")
    .gsub("\\,", ",")
    .gsub("\\;", ";")
    .gsub("\\\\", "\\")
    .strip
end

def ics_date(value)
  raw = value.to_s.strip
  return Date.strptime(raw, "%Y%m%d") if raw.match?(/\A\d{8}\z/)

  Time.strptime(raw, raw.end_with?("Z") ? "%Y%m%dT%H%M%SZ" : "%Y%m%dT%H%M%S")
    .getlocal
    .to_date
rescue ArgumentError
  nil
end

def monthly_recurrence_date(month, by_day)
  match = by_day.to_s.match(/\A([1-5])(SU|MO|TU|WE|TH|FR|SA)\z/)
  return month unless match

  weekday = %w[SU MO TU WE TH FR SA].index(match[2])
  first = Date.new(month.year, month.month, 1)
  first + ((weekday - first.wday) % 7) + ((match[1].to_i - 1) * 7)
end

def ics_recurrence_dates(start_date, rule)
  fields = rule.to_s.split(";").filter_map do |part|
    key, value = part.split("=", 2)
    [key, value] if key && value
  end.to_h
  frequency = fields["FREQ"]
  return [] unless %w[DAILY MONTHLY].include?(frequency)

  interval = [fields.fetch("INTERVAL", "1").to_i, 1].max
  count = fields["COUNT"]&.to_i
  until_date = ics_date(fields["UNTIL"])
  max_occurrences = count ? [count, 500].min : 500
  dates = []

  (1...max_occurrences).each do |index|
    date =
      if frequency == "DAILY"
        start_date + (index * interval)
      else
        month = start_date >> (index * interval)
        monthly_recurrence_date(month, fields["BYDAY"])
      end

    break if until_date && date > until_date

    dates << date
    break if count.nil? && until_date.nil?
  end

  dates
end

def parse_school_calendar(body)
  events = []
  properties = nil

  unfold_ics_lines(body).each do |line|
    case line
    when "BEGIN:VEVENT"
      properties = {}
    when "END:VEVENT"
      if properties
        start_date = ics_date(properties["DTSTART"])
        summary = ics_text(properties["SUMMARY"])
        if start_date && !summary.empty?
          end_date = ics_date(properties["DTEND"])
          event = {
            "title" => summary,
            "description" => ics_text(properties["DESCRIPTION"]),
            "location" => ics_text(properties["LOCATION"]),
            "start_date" => start_date,
            "end_date" => end_date && end_date > start_date ? end_date - 1 : start_date
          }
          events << event

          duration = event["end_date"] - event["start_date"]
          ics_recurrence_dates(start_date, properties["RRULE"]).each do |date|
            events << event.merge(
              "start_date" => date,
              "end_date" => date + duration
            )
          end
        end
      end
      properties = nil
    else
      next unless properties

      name_and_params, value = line.split(":", 2)
      next unless value

      name = name_and_params.split(";", 2).first
      properties[name] ||= value if %w[DTSTART DTEND SUMMARY DESCRIPTION LOCATION RRULE].include?(name)
    end
  end

  events.sort_by { |event| [event["start_date"], event["title"]] }
end

def filter_school_calendar_events(events, excluded_keywords)
  normalized_keywords = excluded_keywords.map(&:downcase)
  return events if normalized_keywords.empty?

  events.reject do |event|
    searchable = [
      event["title"],
      event["description"],
      event["location"]
    ].join(" ").downcase

    normalized_keywords.any? { |keyword| searchable.include?(keyword) }
  end
end

def school_calendar_snapshot(now: Time.now, force: false)
  settings = load_school_calendar_settings
  feed_url = settings["feed_url"]
  return { events: [], status: :not_configured } if feed_url.empty?

  cached = $school_calendar_mutex.synchronize { $school_calendar_cache }
  if !force && cached && cached[:feed_url] == feed_url &&
      now - cached[:fetched_at] < SCHOOL_CALENDAR_CACHE_SECONDS
    return { events: cached[:events], status: :fresh }
  end

  events = parse_school_calendar(fetch_school_calendar(feed_url))
  $school_calendar_mutex.synchronize do
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: now,
      events: events
    }
  end
  { events: events, status: :fresh }
rescue => e
  puts "Unable to refresh school calendar: #{e.class}: #{e.message}"
  if cached && cached[:feed_url] == feed_url
    { events: cached[:events], status: :stale }
  else
    { events: [], status: :unavailable }
  end
end

def school_calendar_events(now: Time.now, force: false)
  snapshot = school_calendar_snapshot(now: now, force: force)
  feed_events = filter_school_calendar_events(
    snapshot[:events],
    load_school_calendar_settings["excluded_keywords"]
  )
  (feed_events + manual_no_school_calendar_events).sort_by do |event|
    [event["start_date"], event["title"]]
  end
end

def upcoming_school_calendar_events(events, today: Date.today, days: 30, limit: 3)
  last_day = today + days
  upcoming = events.select do |event|
    event["end_date"] >= today && event["start_date"] <= last_day
  end

  limit ? upcoming.first(limit) : upcoming
end

def upcoming_schedule_changes(events, today: Date.today, days: 7)
  last_day = today + days
  events.select do |event|
    searchable = [event["title"], event["description"]].join(" ")
    event["end_date"] >= today &&
      event["start_date"] <= last_day &&
      searchable.match?(SCHOOL_CALENDAR_CHANGE_PATTERN)
  end
end
