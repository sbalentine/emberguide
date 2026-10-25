require "date"
require "fileutils"
require "json"

ACHIEVEMENT_HISTORY_FILE = ENV.fetch("ACHIEVEMENT_HISTORY_FILE") do
  if File.directory?("/data")
    "/data/achievement_history.json"
  else
    File.expand_path("../tmp/achievement_history.json", __dir__)
  end
end

ACHIEVEMENT_SETTINGS_FILE = ENV.fetch("ACHIEVEMENT_SETTINGS_FILE") do
  if File.directory?("/data")
    "/data/achievement_settings.json"
  else
    File.expand_path("../tmp/achievement_settings.json", __dir__)
  end
end

ACHIEVEMENT_HISTORY_DAYS = 400
DEFAULT_STRONG_SCORE_THRESHOLD = 80
DEFAULT_SCHOOL_YEAR_START = "2026-08-12"
DEFAULT_SCHOOL_YEAR_END = "2027-06-04"
$achievement_history_mutex = Mutex.new

ACHIEVEMENT_BADGE_GROUPS = [
  {
    "id" => "on_time", "title" => "On-Time Run", "icon" => "🔥",
    "unit" => "on-time assignments", "goals" => [5, 10, 25, 50],
    "names" => ["On the Dot", "Clockwork Kid", "Deadline Ninja", "Time Lord"]
  },
  {
    "id" => "no_missing", "title" => "Clear Slate", "icon" => "◇",
    "unit" => "tracked school days with no missing work", "goals" => [5, 10, 20, 30],
    "names" => ["Fresh Start", "Neat Streak", "Clean Sweep", "Slate Champion"]
  },
  {
    "id" => "strong_scores", "title" => "Strong Score Streak", "icon" => "★",
    "unit" => "consecutive strong scores", "goals" => [5, 10, 20, 30],
    "names" => ["Spark Starter", "On Fire", "Meteor Shower", "Supernova"]
  },
  {
    "id" => "graded_assignments", "title" => "Work Completed", "icon" => "✓",
    "unit" => "graded assignments", "goals" => [25, 50, 100, 200],
    "names" => ["Quest Accepted", "Quest Collector", "Century Club", "Legend of the Backpack"]
  },
  {
    "id" => "school_year", "title" => "School Year Journey", "icon" => "🧭",
    "unit" => "% of the school year completed", "goals" => [25, 50, 75, 100],
    "names" => ["Off to Adventure", "Halfway Hero", "Final Stretch", "School Year Conqueror"]
  }
].freeze

def empty_achievement_history
  { "daily_missing_counts" => {}, "earned_badges" => {} }
end

def empty_achievement_settings
  {
    "strong_score_threshold" => DEFAULT_STRONG_SCORE_THRESHOLD,
    "school_year_start" => DEFAULT_SCHOOL_YEAR_START,
    "school_year_end" => DEFAULT_SCHOOL_YEAR_END,
    "school_day_overrides" => {}
  }
end

def load_achievement_settings
  return empty_achievement_settings unless File.exist?(ACHIEVEMENT_SETTINGS_FILE)

  settings = JSON.parse(File.read(ACHIEVEMENT_SETTINGS_FILE))
  threshold = achievement_score_threshold(
    settings["strong_score_threshold"]
  )
  school_year_start, school_year_end = achievement_school_year_dates(
    settings.fetch("school_year_start", DEFAULT_SCHOOL_YEAR_START),
    settings.fetch("school_year_end", DEFAULT_SCHOOL_YEAR_END)
  )
  {
    "strong_score_threshold" => threshold,
    "school_year_start" => school_year_start.iso8601,
    "school_year_end" => school_year_end.iso8601,
    "school_day_overrides" => achievement_school_day_overrides(
      settings.fetch("school_day_overrides", {}),
      school_year_start,
      school_year_end
    )
  }
rescue JSON::ParserError, ArgumentError, TypeError
  puts "Unable to load achievement settings."
  empty_achievement_settings
end

def achievement_score_threshold(value)
  threshold = Integer(value)
  unless (60..100).cover?(threshold)
    raise ArgumentError, "Choose a strong-score target from 60% to 100%."
  end

  threshold
rescue TypeError
  raise ArgumentError, "Choose a strong-score target from 60% to 100%."
end

def achievement_school_year_dates(start_value, end_value)
  start_date = Date.iso8601(start_value.to_s)
  end_date = Date.iso8601(end_value.to_s)
  raise ArgumentError, "The last day of school must be after the first day." if end_date < start_date
  raise ArgumentError, "The school year must be 550 days or fewer." if (end_date - start_date).to_i > 550

  [start_date, end_date]
rescue Date::Error
  raise ArgumentError, "Enter valid first and last school dates."
end

def save_achievement_settings(
  value,
  school_year_start: DEFAULT_SCHOOL_YEAR_START,
  school_year_end: DEFAULT_SCHOOL_YEAR_END,
  school_day_overrides: {}
)
  start_date, end_date = achievement_school_year_dates(
    school_year_start,
    school_year_end
  )
  settings = {
    "strong_score_threshold" => achievement_score_threshold(value),
    "school_year_start" => start_date.iso8601,
    "school_year_end" => end_date.iso8601,
    "school_day_overrides" => achievement_school_day_overrides(
      school_day_overrides, start_date, end_date
    )
  }
  FileUtils.mkdir_p(File.dirname(ACHIEVEMENT_SETTINGS_FILE))
  temporary_file = "#{ACHIEVEMENT_SETTINGS_FILE}.tmp"
  File.write(temporary_file, JSON.pretty_generate(settings))
  File.rename(temporary_file, ACHIEVEMENT_SETTINGS_FILE)
  settings
end

def load_achievement_history
  return empty_achievement_history unless File.exist?(ACHIEVEMENT_HISTORY_FILE)

  history = JSON.parse(File.read(ACHIEVEMENT_HISTORY_FILE))
  counts = history["daily_missing_counts"]
  return empty_achievement_history unless counts.is_a?(Hash)

  {
    "daily_missing_counts" => counts.transform_values(&:to_i),
    "earned_badges" => validated_earned_badges(history.fetch("earned_badges", {}))
  }
rescue JSON::ParserError, TypeError, ArgumentError
  puts "Unable to load achievement history."
  empty_achievement_history
end

def validated_earned_badges(badges)
  valid = badges.is_a?(Hash) && badges.all? do |id, earned_on|
    id.is_a?(String) && earned_on.is_a?(String) &&
      earned_on.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(earned_on)
  end
  unless valid
    raise ArgumentError, "Invalid earned achievement badges."
  end
  badges
end

def record_achievement_badges(streaks, milestones, date: Date.today)
  school_year = milestones.fetch("school_year")
  total = school_year.fetch("total")
  values = streaks.merge(
    "graded_assignments" => milestones.fetch("graded_assignments"),
    "school_year" => total.positive? ? school_year.fetch("completed") * 100.0 / total : 0
  )
  $achievement_history_mutex.synchronize do
    history = load_achievement_history
    earned = history.fetch("earned_badges")
    changed = false
    groups = ACHIEVEMENT_BADGE_GROUPS.map do |group|
      badges = group["goals"].each_with_index.map do |goal, index|
        id = "#{group["id"]}-#{goal}"
        if values.fetch(group["id"]) >= goal && !earned.key?(id)
          earned[id] = date.iso8601
          changed = true
        end
        {
          "id" => id, "name" => group["names"][index], "goal" => goal,
          "earned_on" => earned[id],
          "progress" => [values.fetch(group["id"]), goal].min
        }
      end
      group.merge("badges" => badges)
    end
    save_achievement_history(history) if changed
    groups
  end
end

def save_achievement_history(history)
  FileUtils.mkdir_p(File.dirname(ACHIEVEMENT_HISTORY_FILE))
  temporary_file = "#{ACHIEVEMENT_HISTORY_FILE}.tmp"
  File.write(temporary_file, JSON.pretty_generate(history))
  File.rename(temporary_file, ACHIEVEMENT_HISTORY_FILE)
end

def record_achievement_day(data, date: Date.today)
  $achievement_history_mutex.synchronize do
    history = load_achievement_history
    counts = history["daily_missing_counts"]
    counts[date.iso8601] = Array(data["missing"]).length
    cutoff = date - ACHIEVEMENT_HISTORY_DAYS
    counts.delete_if { |day, _count| Date.iso8601(day) < cutoff }
    save_achievement_history(history)
    history
  end
rescue Date::Error
  raise ArgumentError, "Achievement history contains an invalid date."
end

def school_day?(date)
  (1..5).cover?(date.wday)
end

def no_missing_school_day_streak(history, date: Date.today)
  counts = history.fetch("daily_missing_counts", {})
  cursor = date
  cursor -= 1 until school_day?(cursor)
  streak = 0

  loop do
    break unless counts[cursor.iso8601] == 0

    streak += 1
    cursor -= 1
    cursor -= 1 until school_day?(cursor)
  end

  streak
end

def achievement_graded_submissions(data)
  Array(data["grades"]).filter_map do |submission|
    assignment = submission["assignment"] || {}
    points_possible = assignment["points_possible"]
    recorded_at = parse_canvas_time(
      submission["graded_at"] || assignment["due_at"]
    )

    next if submission["excused"] == true
    next if assignment["omit_from_final_grade"] == true
    next unless recorded_at
    next if submission["score"].nil? || points_possible.to_f <= 0

    [recorded_at, submission]
  end.sort_by(&:first).reverse
end

def on_time_assignment_streak(data)
  submissions = Array(data["grades"]).filter_map do |submission|
    assignment = submission["assignment"] || {}
    due_at = parse_canvas_time(assignment["due_at"])
    next unless due_at
    next if submission["excused"] == true
    next unless submission["submitted_at"] ||
      %w[submitted graded].include?(submission["workflow_state"])

    [due_at, submission]
  end.sort_by(&:first).reverse

  submissions.take_while do |_due_at, submission|
    submission["late"] != true && submission["missing"] != true
  end.length
end

def strong_score_streak(
  data,
  threshold: DEFAULT_STRONG_SCORE_THRESHOLD
)
  achievement_graded_submissions(data).take_while do |_recorded_at, submission|
    assignment = submission["assignment"]
    percentage(
      submission["score"],
      assignment["points_possible"]
    ).to_f >= threshold
  end.length
end

def achievement_school_day_overrides(overrides, start_date, end_date)
  unless overrides.is_a?(Hash) && overrides.length <= 551
    raise ArgumentError, "School-day overrides must be a list of dates and day types."
  end

  overrides.each do |value, kind|
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) &&
        %w[school no_school].include?(kind)
      raise ArgumentError, "Use YYYY-MM-DD dates with school or no_school day types."
    end

    day = Date.iso8601(value)
    unless (start_date..end_date).cover?(day)
      raise ArgumentError, "Override #{value} is outside the school year."
    end
  end
  overrides.sort.to_h
rescue Date::Error
  raise ArgumentError, "Enter valid dates for school-day overrides."
end

def achievement_school_day_override_fields(no_school_dates, school_dates)
  overrides = {}
  { "no_school" => no_school_dates, "school" => school_dates }.each do |kind, text|
    text.to_s.split(/[\s,]+/).reject(&:empty?).each do |day|
      if overrides.key?(day) && overrides[day] != kind
        raise ArgumentError, "#{day} cannot be both a school day and a no-school day."
      end
      overrides[day] = kind
    end
  end
  overrides
end

def no_school_calendar_event?(event)
  title = event["title"].to_s
  title.match?(
    /\b(no[\s-]+school|schools?\s+(?:is\s+|are\s+)?closed|district\s+closed|
      non[\s-]?student(?:\s+(?:attendance|day))?|
      (?:staff|teacher)\s+(?:development|work[\s-]?day|in[\s-]?service)|
      (?:winter|spring|fall|autumn|summer|thanksgiving|holiday|mid[\s-]?winter)\s+(?:break|recess))\b/ix
  ) || title.match?(
    /\A\s*(?:(?:labor|memorial|veterans?|presidents?|independence)\s+day|
      martin\s+luther\s+king(?:\s+jr\.?)?\s+day|thanksgiving(?:\s+day)?|
      christmas(?:\s+day)?|new\s+year'?s?\s+day|holiday)
      (?:\s*[-:(]?\s*(?:holiday|observed)\)?)?\s*\z/ix
  )
end

def school_year_progress(
  start_date, end_date, date: Date.today, events: [], overrides: {}
)
  closure_reasons = {}
  events.each do |event|
    next unless no_school_calendar_event?(event)

    first = [start_date, event["start_date"]].max
    last = [end_date, event["end_date"]].min
    (first..last).each do |day|
      (closure_reasons[day] ||= []) << event["title"]
    end
  end

  excluded_days = []
  school_days = (start_date..end_date).select do |day|
    override = overrides[day.iso8601]
    is_school_day =
      if override
        override == "school"
      else
        school_day?(day) && !closure_reasons.key?(day)
      end
    if school_day?(day) && !is_school_day
      excluded_days << {
        "date" => day,
        "reasons" => override == "no_school" ?
          ["Manual no-school override"] : closure_reasons.fetch(day).uniq
      }
    end
    is_school_day
  end
  completed = school_days.count { |day| day < date }

  {
    "completed" => completed,
    "remaining" => school_days.length - completed,
    "total" => school_days.length,
    "excluded_days" => excluded_days
  }
end

def school_year_calendar_progress(settings, date: Date.today)
  start_date, end_date = achievement_school_year_dates(
    settings["school_year_start"], settings["school_year_end"]
  )
  snapshot = school_calendar_snapshot
  events = snapshot[:events]
  coverage_spans_year = events.any? &&
    events.map { |event| event["start_date"] }.min <= start_date &&
    events.map { |event| event["end_date"] }.max >= end_date
  status =
    case snapshot[:status]
    when :not_configured
      "Weekday estimate: no calendar connected. Manual overrides still apply."
    when :unavailable
      "Weekday estimate: calendar unavailable. Manual overrides still apply."
    when :stale
      "Calendar-adjusted estimate: refresh failed; using older calendar data."
    else
      if coverage_spans_year
        "Calendar-adjusted estimate: review detected closures; the feed may omit some no-school days."
      else
        "Calendar-adjusted estimate: the feed does not span the full school year."
      end
    end
  school_year_progress(
    start_date, end_date, date: date,
    events: events, overrides: settings.fetch("school_day_overrides", {})
  ).merge(
    "status" => status,
    "calendar_status" => snapshot[:status].to_s
  )
end
