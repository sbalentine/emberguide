require "json"
require "time"
require "cgi"
require "fileutils"

REFRESH_INTERVAL = 600

CACHE_FILE = ENV.fetch("CACHE_FILE") do
  if File.directory?("/data")
    "/data/canvas_cache.json"
  else
    File.expand_path(
      "../tmp/canvas_cache.json",
      __dir__
    )
  end
end

$dashboard_data = nil
$last_successful_update = nil
$last_refresh_error = nil
$data_mutex = Mutex.new
$refresh_mutex = Mutex.new

# ============================================================
# Fetch Canvas Data
# ============================================================

def fetch_dashboard_data
  puts "Refreshing Canvas data..."

  profile = canvas_get(
    "/api/v1/users/self/profile"
  )

  courses = canvas_get(
    "/api/v1/courses?enrollment_state=active&per_page=100"
  )

  grades = canvas_get(
    "/api/v1/users/self/graded_submissions" \
    "?include%5B%5D=assignment" \
    "&only_current_enrollments=true" \
    "&only_published_assignments=true" \
    "&per_page=100"
  )

  missing = canvas_get(
    "/api/v1/users/self/missing_submissions?per_page=100"
  )

  upcoming = canvas_get(
    "/api/v1/users/self/upcoming_events?per_page=100"
  )

  planner_start = (Date.today - 30).iso8601
  planner_end = (Date.today + 90).iso8601

  planner_items = canvas_get(
    "/api/v1/planner/items" \
    "?start_date=#{planner_start}" \
    "&end_date=#{planner_end}" \
    "&filter=incomplete_items" \
    "&per_page=100"
  )

  todo = planner_items.select do |item|
    item["plannable_type"] == "planner_note"
  end

  # ----------------------------------------------------------
  # Course names
  # ----------------------------------------------------------

  course_names = {}

  courses.each do |course|
    course_names[course["id"].to_s] =
      course["name"]
  end

  # ----------------------------------------------------------
  # Find upcoming assignment IDs by course
  # ----------------------------------------------------------

  upcoming_pairs = upcoming.map do |event|
    course_id = assignment_course_id(event)
    aid = assignment_id(event)

    [course_id, aid]
  end.select do |course_id, aid|
    course_id && aid
  end

  upcoming_by_course =
    upcoming_pairs.group_by(&:first)

  # ----------------------------------------------------------
  # Fetch submission status for upcoming assignments
  # ----------------------------------------------------------

  submissions = {}

  upcoming_by_course.each do |course_id, pairs|
    assignment_ids =
      pairs.map(&:last).uniq

    submissions[course_id.to_s] ||= {}

    assignment_ids.each_slice(50) do |ids|
      query = ids.map do |aid|
        "assignment_ids%5B%5D=#{CGI.escape(aid.to_s)}"
      end.join("&")

      path =
        "/api/v1/courses/#{course_id}/students/submissions" \
        "?student_ids%5B%5D=self" \
        "&include%5B%5D=assignment" \
        "&include%5B%5D=submission_comments" \
        "&#{query}" \
        "&per_page=100"

      begin
        course_submissions =
          canvas_get(path)

        course_submissions.each do |submission|
          aid =
            submission["assignment_id"] ||
            submission.dig("assignment", "id")

          next unless aid

          submissions[course_id.to_s][aid.to_s] =
            submission
        end

      rescue => e
        puts(
          "Unable to fetch submissions for course " \
          "#{course_id}: #{e.class}: #{e.message}"
        )
      end
    end
  end

  {
    "profile" => profile,
    "courses" => courses,
    "course_names" => course_names,
    "grades" => grades,
    "missing" => missing,
    "upcoming" => upcoming,
    "todo" => todo,
    "submissions" => submissions,
    "updated_at" => Time.now.iso8601
  }.merge(fetch_module_catalog(courses, previous: dashboard_data))
    .merge(fetch_assignment_catalog(courses, previous: dashboard_data))
end

# ============================================================
# Persistent Cache
# ============================================================

def save_cache(data)
  FileUtils.mkdir_p(
    File.dirname(CACHE_FILE)
  )

  File.write(
    CACHE_FILE,
    JSON.pretty_generate(data)
  )

  puts "Canvas cache saved to #{CACHE_FILE}."
end

def load_cache
  return nil unless File.exist?(CACHE_FILE)

  puts "Loading cached Canvas data from #{CACHE_FILE}..."

  JSON.parse(
    File.read(CACHE_FILE)
  )

rescue => e
  puts(
    "Unable to load Canvas cache: " \
    "#{e.class}: #{e.message}"
  )

  nil
end

# ============================================================
# Refresh
# ============================================================

def refresh_dashboard
  $refresh_mutex.synchronize do
    previous_data = dashboard_data
    data = fetch_dashboard_data
    removed_grade_overrides = reconcile_canvas_grade_overrides(data)
    events = detect_dashboard_events(
      dashboard_data_with_manual(previous_data),
      dashboard_data_with_manual(data)
    )

    save_cache(data)
    append_dashboard_events(events)
    publish_home_assistant_events(events)

    $data_mutex.synchronize do
      $dashboard_data = data

      $last_successful_update =
        Time.parse(data["updated_at"])

      $last_refresh_error = nil
    end
    record_achievement_day(data)

    puts(
      "Canvas refresh successful at " \
      "#{$last_successful_update}; " \
      "#{events.length} new event(s)"
    )

    unless removed_grade_overrides.empty?
      puts(
        "Removed #{removed_grade_overrides.length} grade override(s) " \
        "updated by Canvas."
      )
    end
  end

rescue => e
  puts(
    "Canvas refresh failed: " \
    "#{e.class}: #{e.message}"
  )

  $data_mutex.synchronize do
    $last_refresh_error = e.message
  end
end

# ============================================================
# Initialize From Cache
# ============================================================

def initialize_dashboard_data
  cached = load_cache

  return unless cached

  $data_mutex.synchronize do
    $dashboard_data = cached

    if cached["updated_at"]
      begin
        $last_successful_update =
          Time.parse(cached["updated_at"])
      rescue ArgumentError
        $last_successful_update = nil
      end
    end
  end
end

# ============================================================
# Background Refresh
# ============================================================

def start_refresh_thread
  Thread.new do
    loop do
      refresh_dashboard
      sleep REFRESH_INTERVAL
    end
  end
end

# ============================================================
# Safe Data Access
# ============================================================

def dashboard_data
  $data_mutex.synchronize do
    $dashboard_data
  end
end

def dashboard_status
  $data_mutex.synchronize do
    {
      updated_at: $last_successful_update,
      error: $last_refresh_error
    }
  end
end