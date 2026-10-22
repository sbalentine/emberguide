require "webrick"
require "erb"
require "json"
require "securerandom"

APP_ROOT = File.expand_path(__dir__)
DEMO_MODE = ARGV.delete("--demo")
NO_BACKGROUND_MODE = ARGV.delete("--no-background")

if DEMO_MODE
  require_relative "lib/demo_data"

  DemoData.prepare_runtime!(APP_ROOT).each do |name, value|
    ENV[name] = value
  end

  ENV["CANVAS_URL"] = "https://canvas.example.test"
  ENV["CANVAS_TOKEN"] = "demo-token"
  ENV["TOKEN_EXPIRES"] = (Date.today + 365).iso8601
  ENV["GMAIL_SENDER"] = ""
  ENV["GMAIL_APP_PASSWORD"] = ""
end

require_relative "lib/canvas"
require_relative "lib/helpers"
require_relative "lib/achievement_history"
require_relative "lib/course_name_mappings"
require_relative "lib/grade_overrides"
require_relative "lib/hidden_courses"
require_relative "lib/manual_coursework"
require_relative "lib/event_journal"
require_relative "lib/home_assistant_events"
require_relative "lib/dashboard_data"
require_relative "lib/course_modules"
require_relative "lib/email_backups"
require_relative "lib/school_calendar"

# ============================================================
# Startup
# ============================================================

if $PROGRAM_NAME == __FILE__
  mode =
    if DEMO_MODE
      " in demo mode"
    elsif NO_BACKGROUND_MODE
      " without background workers"
    else
      ""
    end

  puts "Starting EmberGuide#{mode}..."

  initialize_dashboard_data
  initialize_event_journal
  current_dashboard_data = dashboard_data
  record_achievement_day(current_dashboard_data) if current_dashboard_data
  unless DEMO_MODE || NO_BACKGROUND_MODE
    start_refresh_thread
    start_scheduled_email_thread
  end
end

# ============================================================
# Web Server
# ============================================================

server = WEBrick::HTTPServer.new(
  Port: ENV.fetch("PORT", "4567").to_i,
  BindAddress: "0.0.0.0",
  AccessLog: [],
  Logger: WEBrick::Log.new(
    $stdout,
    WEBrick::Log::INFO
  )
)

DASHBOARD_SERVER = server

# ============================================================
# Dashboard
# ============================================================

server.mount_proc "/" do |_request, response|
  begin
    data = dashboard_data_with_manual

    unless data
      response.status = 200
      response["Content-Type"] = "text/html; charset=utf-8"
      response["Cache-Control"] = "no-cache"

      response.body = <<~HTML
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">

          <meta
            name="viewport"
            content="width=device-width, initial-scale=1"
          >

          <link
            rel="stylesheet"
            href="/dashboard.css"
          >

          <title>EmberGuide</title>
        </head>

        <body>
          <main class="container">
            <h1>EmberGuide</h1>
            <p>Waiting for Canvas data...</p>
          </main>
        </body>
        </html>
      HTML

      next
    end

    template = ERB.new(
      File.read(
        File.join(APP_ROOT, "views", "dashboard.erb")
      )
    )

    response.status = 200
    response["Content-Type"] = "text/html; charset=utf-8"
    response["Cache-Control"] = "no-cache"

    response.body = template.result(binding)

  rescue => e
    puts(
      "Dashboard error: " \
      "#{e.class}: #{e.message}"
    )

    puts e.backtrace

    response.status = 500
    response["Content-Type"] = "text/plain; charset=utf-8"

    response.body =
      "Unable to load school dashboard." \
      "\n\n#{e.message}"
  end
end

server.mount_proc "/modules" do |request, response|
  unless request.request_method == "GET" && request.path == "/modules"
    response.status = request.path == "/modules" ? 405 : 404
    response["Allow"] = "GET" if response.status == 405
    response.body = "Modules supports GET /modules only."
    next
  end

  data = dashboard_data_with_manual
  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  template = ERB.new(File.read(File.join(APP_ROOT, "views", "modules.erb")))
  response.body = template.result(binding)
rescue StandardError => e
  puts "Modules error: #{e.class}: #{e.message}"
  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load modules."
end

server.mount_proc "/modules/item-content" do |request, response|
  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  course_id = request.query["course_id"].to_s
  item = DEMO_MODE ? nil : load_module_item_content(course_id, request.query["item_id"].to_s)
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-store"
  if item
    response.status = 200
    response.body = module_item_content_html(course_id, item)
  else
    response.status = 404
    response.body = "This item can't be loaded here."
  end
rescue StandardError => e
  puts "Module item content error: #{e.class}: #{e.message}"
  response.status = 502
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Canvas didn't return this item."
end

server.mount_proc "/refresh" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  if DEMO_MODE
    initialize_dashboard_data
  else
    refresh_dashboard
  end

  response.status = 303
  response["Location"] = "/"
  response.body = ""
end

# ============================================================
# Settings
# ============================================================

server.mount_proc "/settings" do |request, response|
  if request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  template = ERB.new(File.read(File.join(APP_ROOT, "views", "settings.erb")))

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load settings."
end

# ============================================================
# School Calendar
# ============================================================

def requested_calendar_month(value, today: Date.today)
  return Date.new(today.year, today.month, 1) if value.to_s.empty?

  match = value.to_s.match(/\A(\d{4})-(\d{2})\z/)
  raise ArgumentError, "Invalid calendar month." unless match

  Date.new(match[1].to_i, match[2].to_i, 1)
rescue Date::Error
  raise ArgumentError, "Invalid calendar month."
end

server.mount_proc "/calendar" do |request, response|
  if request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  today = Date.today
  all_calendar_events = school_calendar_events
  calendar_month = requested_calendar_month(request.query["month"], today: today)
  calendar_month_end = (calendar_month >> 1) - 1
  browsing_calendar_month = !request.query["month"].to_s.empty?
  calendar_events = all_calendar_events.select do |event|
    if browsing_calendar_month
      event["start_date"] <= calendar_month_end && event["end_date"] >= calendar_month
    else
      event["end_date"] >= today
    end
  end
  calendar_grid_start = calendar_month - calendar_month.wday
  calendar_grid_end = calendar_month_end + (6 - calendar_month_end.wday)
  calendar_events_by_date = Hash.new { |events, date| events[date] = [] }

  all_calendar_events.each do |event|
    event_start = [event["start_date"], calendar_grid_start].max
    event_end = [event["end_date"], calendar_grid_end].min
    next if event_start > event_end

    event_start.upto(event_end) do |date|
      calendar_events_by_date[date] << event
    end
  end

  calendar_days = calendar_grid_start.upto(calendar_grid_end).to_a
  previous_calendar_month = calendar_month << 1
  next_calendar_month = calendar_month >> 1
  template = ERB.new(File.read(File.join(APP_ROOT, "views", "calendar.erb")))

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue ArgumentError => e
  response.status = 422
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = e.message
rescue => e
  puts "School calendar error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load the school calendar."
end

# ============================================================
# Achievements
# ============================================================

server.mount_proc "/achievements" do |request, response|
  if request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  current_dashboard_data = dashboard_data_with_manual
  achievement_data = current_dashboard_data || {}
  grade_overrides = load_grade_overrides
  achievement_data =
    hide_assignments_from_dashboard(achievement_data, grade_overrides)
  achievement_data["grades"] =
    combined_grade_submissions(achievement_data, grade_overrides)
  achievement_history =
    if current_dashboard_data
      record_achievement_day(achievement_data)
    else
      load_achievement_history
    end
  achievement_settings = load_achievement_settings
  strong_score_threshold =
    achievement_settings["strong_score_threshold"]
  school_year_start, school_year_end = achievement_school_year_dates(
    achievement_settings["school_year_start"],
    achievement_settings["school_year_end"]
  )
  achievement_streaks = {
    "on_time" => on_time_assignment_streak(achievement_data),
    "no_missing" => no_missing_school_day_streak(achievement_history),
    "strong_scores" => strong_score_streak(
      achievement_data,
      threshold: strong_score_threshold
    )
  }
  achievement_milestones = {
    "graded_assignments" => achievement_graded_submissions(achievement_data).length,
    "school_year" => school_year_calendar_progress(achievement_settings)
  }
  achievement_badge_groups = record_achievement_badges(
    achievement_streaks, achievement_milestones
  )
  template = ERB.new(File.read(File.join(APP_ROOT, "views", "achievements.erb")))

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Achievements error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load achievements."
end

server.mount_proc "/settings/achievements" do |request, response|
  achievement_settings_error = nil

  if request.request_method == "POST"
    begin
      existing_settings = load_achievement_settings
      save_achievement_settings(
        request.query["strong_score_threshold"],
        school_year_start: existing_settings["school_year_start"],
        school_year_end: existing_settings["school_year_end"],
        school_day_overrides: existing_settings["school_day_overrides"]
      )
      response.status = 303
      response["Location"] = "/settings/achievements?saved=1"
      response.body = ""
      next
    rescue ArgumentError => e
      achievement_settings_error = e.message
      response.status = 422
    end
  elsif request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  achievement_settings = load_achievement_settings
  if achievement_settings_error
    achievement_settings["strong_score_threshold"] = request.query["strong_score_threshold"]
  end
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "achievement_settings.erb"))
  )

  response.status = 200 if request.request_method == "GET"
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Achievement settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load achievement settings."
end

server.mount_proc "/settings/calendar" do |request, response|
  calendar_error = nil

  if request.request_method == "POST"
    begin
      if request.query["action"] == "school_year"
        existing_settings = load_achievement_settings
        save_achievement_settings(
          existing_settings["strong_score_threshold"],
          school_year_start: request.query["school_year_start"],
          school_year_end: request.query["school_year_end"],
          school_day_overrides: achievement_school_day_override_fields(
            request.query["no_school_dates"], request.query["extra_school_dates"]
          )
        )
      else
        save_school_calendar_settings(
          request.query["calendar_feed_url"],
          request.query["calendar_excluded_keywords"]
        )
      end
      response.status = 303
      response["Location"] = "/settings/calendar?saved=1"
      response.body = ""
      next
    rescue ArgumentError => e
      calendar_error = e.message
      response.status = 422
    end
  elsif request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  calendar_settings = load_school_calendar_settings
  achievement_settings = load_achievement_settings
  school_year_start, school_year_end = achievement_school_year_dates(
    achievement_settings["school_year_start"], achievement_settings["school_year_end"]
  )
  school_year = school_year_calendar_progress(achievement_settings)
  school_year_error = calendar_error && request.query["action"] == "school_year"
  no_school_dates = school_year_error ? request.query["no_school_dates"] :
    achievement_settings["school_day_overrides"].select { |_day, kind| kind == "no_school" }.keys.join("\n")
  extra_school_dates = school_year_error ? request.query["extra_school_dates"] :
    achievement_settings["school_day_overrides"].select { |_day, kind| kind == "school" }.keys.join("\n")
  if school_year_error
    %w[school_year_start school_year_end].each do |key|
      achievement_settings[key] = request.query[key]
    end
  end
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "calendar_settings.erb"))
  )

  response.status = 200 if request.request_method == "GET"
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Calendar settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load calendar settings."
end

def todo_form_fields(request, data)
  title = request.query["title"].to_s.strip
  details = request.query["details"].to_s.strip
  todo_date = request.query["todo_date"].to_s
  course_id = request.query["course_id"].to_s

  raise ArgumentError, "Title is required" if title.empty?
  raise ArgumentError, "Title is too long" if title.length > 255

  unless todo_date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, "A valid date is required"
  end

  Date.iso8601(todo_date)

  unless course_id.empty? || (data["courses"] || []).any? do |course|
    course["id"].to_s == course_id
  end
    raise ArgumentError, "Invalid course"
  end

  fields = {
    "title" => title,
    "details" => details,
    "todo_date" => todo_date
  }

  fields["course_id"] = course_id unless course_id.empty?
  fields
rescue Date::Error
  raise ArgumentError, "A valid date is required"
end

server.mount_proc "/todo/create" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  begin
    data = dashboard_data || {}
    fields = todo_form_fields(request, data)

    canvas_form_request(
      :post,
      "/api/v1/planner_notes",
      fields
    )

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue ArgumentError => e
    response.status = 422
    response.body = e.message
  rescue => e
    puts(
      "Unable to create Canvas to-do: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response.body = "Unable to create that Canvas to-do."
  end
end

server.mount_proc "/todo/update" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  todo_id = request.query["id"].to_s
  data = dashboard_data || {}

  item = (data["todo"] || []).find do |todo_item|
    todo_item["plannable_type"] == "planner_note" &&
      todo_item["plannable_id"].to_s == todo_id
  end

  unless todo_id.match?(/\A\d+\z/) && item
    response.status = 404
    response.body = "To-do item not found"
    next
  end

  begin
    fields = todo_form_fields(request, data)

    canvas_form_request(
      :put,
      "/api/v1/planner_notes/#{todo_id}",
      fields
    )

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue ArgumentError => e
    response.status = 422
    response.body = e.message
  rescue => e
    puts(
      "Unable to update Canvas to-do: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response.body = "Unable to update that Canvas to-do."
  end
end

server.mount_proc "/todo/complete" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Allow"] = "POST"
    response.body = "Method not allowed"
    next
  end

  todo_id = request.query["id"].to_s

  unless todo_id.match?(/\A\d+\z/)
    response.status = 400
    response.body = "Invalid to-do item"
    next
  end

  item = (dashboard_data&.dig("todo") || []).find do |todo_item|
    todo_item["plannable_type"] == "planner_note" &&
      todo_item["plannable_id"].to_s == todo_id
  end

  unless item
    response.status = 404
    response.body = "To-do item not found"
    next
  end

  begin
    override_id = item.dig("planner_override", "id")

    if override_id
      canvas_form_request(
        :put,
        "/api/v1/planner/overrides/#{override_id}",
        "marked_complete" => "true"
      )
    else
      canvas_form_request(
        :post,
        "/api/v1/planner/overrides",
        "plannable_type" => item["plannable_type"],
        "plannable_id" => item["plannable_id"],
        "marked_complete" => "true"
      )
    end

    refresh_dashboard

    response.status = 303
    response["Location"] = "/"
    response.body = ""
  rescue => e
    puts(
      "Unable to complete Canvas to-do item: " \
      "#{e.class}: #{e.message}"
    )

    response.status = 502
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Unable to complete that Canvas to-do item."
  end
end

# ============================================================
# Class Name Settings
# ============================================================

def class_name_mapping_fields(request, data)
  (data["courses"] || []).each_with_object({}) do |course, mappings|
    course_id = course["id"].to_s
    short_name = request.query["course_#{course_id}"].to_s.strip

    if short_name.length > 80
      raise ArgumentError, "Class names must be 80 characters or fewer"
    end

    mappings[course_id] = short_name unless short_name.empty?
  end
end

def hidden_course_fields(request, data)
  (data["courses"] || []).filter_map do |course|
    next if course["_manual"]

    course_id = course["id"].to_s
    course_id if request.query["hidden_course_#{course_id}"] == "true"
  end
end

server.mount_proc "/settings/classes" do |request, response|
  data = dashboard_data_with_manual(include_hidden: true) || {}
  coursework = load_manual_coursework

  if request.request_method == "POST"
    begin
      if %w[create_course update_course delete_course].include?(request.query["action"])
        update_manual_coursework(request)
        location = "/settings/classes"
      else
        mappings = class_name_mapping_fields(request, data)
        save_course_name_mappings(mappings)
        save_hidden_course_ids(hidden_course_fields(request, data))
        location = "/"
      end

      response.status = 303
      response["Location"] = location
      response.body = ""
    rescue ArgumentError => e
      response.status = 422
      response["Content-Type"] = "text/plain; charset=utf-8"
      response.body = e.message
    end

    next
  end

  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  mappings = load_course_name_mappings
  hidden_course_ids = load_hidden_course_ids
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "class_names.erb"))
  )

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Class name settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load class name settings."
end

# ============================================================
# Scheduled Emails
# ============================================================

server.mount_proc "/backups" do |request, response|
  unless %w[GET HEAD].include?(request.request_method)
    response.status = 405
    response["Allow"] = "GET, HEAD"
    response.body = "Method not allowed"
    next
  end

  response.status = 303
  response["Location"] = "/settings/emails"
  response.body = ""
end

server.mount_proc "/settings/emails/digest-preview" do |request, response|
  unless %w[GET HEAD].include?(request.request_method)
    response.status = 405
    response["Allow"] = "GET, HEAD"
    response.body = "Method not allowed"
    next
  end

  now = Time.now
  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-store"
  response.body = digest_html_body(digest_data(now: now), now)
rescue => e
  puts "Daily digest preview error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to generate the daily digest preview."
end

server.mount_proc "/settings/backup/download" do |request, response|
  unless %w[GET HEAD].include?(request.request_method)
    response.status = 405
    response["Allow"] = "GET, HEAD"
    response.body = "Method not allowed"
    next
  end

  now = Time.now
  archive = build_backup_archive(now: now)
  response.status = 200
  response["Content-Type"] = "application/zip"
  response["Content-Disposition"] =
    "attachment; filename=\"#{backup_archive_filename(now)}\""
  response["Content-Length"] = archive.bytesize.to_s
  response["Cache-Control"] = "no-store"
  response.body = archive
rescue => e
  puts "Backup download error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to generate the dashboard backup."
end

server.mount_proc "/settings/emails/backup-download" do |_request, response|
  response.status = 303
  response["Location"] = "/settings/backup/download"
  response.body = ""
end

server.mount_proc "/settings/backup" do |request, response|
  restore_error = nil

  if request.request_method == "POST"
    begin
      unless request.query["action"] == "restore_backup"
        raise BackupRestoreError, "Invalid backup action."
      end

      unless request.query["confirm_restore"] == "true"
        raise BackupRestoreError,
          "Confirm that you want to replace the current EmberGuide data."
      end

      upload = request.query["backup_file"]
      restore_backup_archive(upload.to_s)
      response.status = 303
      response["Location"] = "/settings/backup?restored=1"
      response.body = ""
      next
    rescue BackupRestoreError => e
      restore_error = e.message
      response.status = 422
    end
  elsif request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "backup.erb"))
  )

  response.status = 200 if request.request_method == "GET"
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Data backup settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load data backup settings."
end

server.mount_proc "/settings/emails" do |request, response|
  email_error = nil

  if request.request_method == "POST"
    begin
      settings = scheduled_email_settings_fields(request)
      save_scheduled_email_settings(settings)

      case request.query["action"]
      when "save"
        response.status = 303
        response["Location"] = "/settings/emails?saved=1"
        response.body = ""
        next
      when "send_backup"
        send_emberguide_backup(settings["backup_recipients"])
        response.status = 303
        response["Location"] = "/settings/emails?sent=backup"
        response.body = ""
        next
      when "send_digest"
        send_emberguide_digest(settings["digest_recipients"])
        response.status = 303
        response["Location"] = "/settings/emails?sent=digest"
        response.body = ""
        next
      else
        raise ArgumentError, "Invalid scheduled email action"
      end
    rescue ArgumentError, EmailConfigurationError => e
      email_error = e.message
      response.status = 422
    rescue => e
      puts "Unable to send scheduled email: #{e.class}: #{e.message}"
      email_error = "Unable to send the email. Check the Gmail settings and try again."
      response.status = 502
    end
  elsif request.request_method != "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  settings ||= load_scheduled_email_settings
  gmail_configured =
    begin
      gmail_email_configuration
      true
    rescue EmailConfigurationError
      false
    end
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "scheduled_emails.erb"))
  )

  response.status = 200 if request.request_method == "GET"
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Scheduled email settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load scheduled email settings."
end

%w[/grades /class-names /scheduled-emails /coursework].each do |path|
  server.mount_proc path do |_request, response|
    response.status = 404
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Not found"
  end
end

# ============================================================
# Official Grade Settings
# ============================================================

def grade_number(value, field_name)
  number = Float(value)

  unless number.finite? && number.between?(0, 99_999)
    raise ArgumentError, "#{field_name} must be between 0 and 99,999"
  end

  number.round(2)
rescue ArgumentError, TypeError
  raise ArgumentError, "#{field_name} must be a valid number"
end

def grade_override_fields(request, data, existing, course_id: nil)
  target_submissions = editable_canvas_submissions(data).select do |submission|
    course_id.nil? ||
      submission.dig("assignment", "course_id").to_s == course_id
  end
  target_assignment_ids = target_submissions.filter_map do |submission|
    assignment_id =
      submission["assignment_id"] ||
      submission.dig("assignment", "id")

    assignment_id&.to_s
  end

  canvas =
    if course_id
      existing.fetch("canvas", {}).reject do |assignment_id, _override|
        target_assignment_ids.include?(assignment_id)
      end
    else
      {}
    end

  target_submissions.each do |submission|
    assignment_id =
      submission["assignment_id"] ||
      submission.dig("assignment", "id")

    next unless assignment_id

    score_value =
      request.query["canvas_#{assignment_id}_score"].to_s.strip
    points_value =
      request.query["canvas_#{assignment_id}_points"].to_s.strip
    hidden = request.query["canvas_#{assignment_id}_hidden"] == "true"

    next if score_value.empty? && points_value.empty? && !hidden

    canvas[assignment_id.to_s] = {
      "score" => score_value.empty? ? nil : grade_number(score_value, "Earned points"),
      "points_possible" => points_value.empty? ? nil : grade_number(points_value, "Possible points"),
      "canvas_score" => submission["score"],
      "canvas_points_possible" =>
        submission.dig("assignment", "points_possible"),
      "canvas_graded_at" => submission["graded_at"],
      "updated_at" => Time.now.iso8601
    }
    canvas[assignment_id.to_s]["hidden"] = true if hidden
  end

  valid_course_ids =
    if course_id
      [course_id]
    else
      (data["courses"] || []).map { |course| course["id"].to_s }
    end
  custom =
    if course_id
      existing.fetch("custom", {}).reject do |_grade_id, grade|
        grade["course_id"].to_s == course_id
      end
    else
      {}
    end

  existing.fetch("custom", {}).each do |grade_id, grade|
    next if course_id && grade["course_id"].to_s != course_id

    name = request.query["custom_#{grade_id}_name"].to_s.strip
    next if name.empty?

    custom[grade_id] = custom_grade_fields(
      request,
      "custom_#{grade_id}",
      valid_course_ids,
      name
    )
  end

  new_grade_indices = request.query.keys.filter_map do |key|
    key[/\Anew_(\d+)_name\z/, 1]
  end.uniq.sort_by(&:to_i)

  new_grade_indices.each do |index|
    prefix = "new_#{index}"
    name = request.query["#{prefix}_name"].to_s.strip
    next if name.empty?

    custom[SecureRandom.uuid] = custom_grade_fields(
      request,
      prefix,
      valid_course_ids,
      name
    )
  end

  { "canvas" => canvas, "custom" => custom }
end

def custom_grade_fields(request, prefix, valid_course_ids, name)
  raise ArgumentError, "Assignment names must be 255 characters or fewer" if name.length > 255

  course_id = request.query["#{prefix}_course_id"].to_s
  raise ArgumentError, "Select a valid course" unless valid_course_ids.include?(course_id)

  score_value = request.query["#{prefix}_score"].to_s.strip
  points_value = request.query["#{prefix}_points"].to_s.strip
  grade_date = request.query["#{prefix}_date"].to_s

  raise ArgumentError, "Earned points are required" if score_value.empty?
  raise ArgumentError, "Possible points are required" if points_value.empty?

  unless grade_date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    raise ArgumentError, "A valid grade date is required"
  end

  Date.iso8601(grade_date)

  {
    "course_id" => course_id,
    "name" => name,
    "score" => grade_number(score_value, "Earned points"),
    "points_possible" => grade_number(points_value, "Possible points"),
    "graded_at" => grade_date,
    "updated_at" => Time.now.iso8601
  }
rescue Date::Error
  raise ArgumentError, "A valid grade date is required"
end

server.mount_proc "/settings/grades" do |request, response|
  data = dashboard_data_with_manual || {}
  coursework = load_manual_coursework
  manual_assignment_action =
    %w[create_assignment update_assignment delete_assignment].include?(
      request.query["action"]
    )
  selected_course_id =
    if manual_assignment_action
      request.query["selected_course_id"].to_s
    else
      request.query["course_id"].to_s
    end
  selected_course_id = nil if selected_course_id.empty?
  selected_course =
    if selected_course_id
      (data["courses"] || []).find do |course|
        course["id"].to_s == selected_course_id
      end
    end

  if selected_course_id && !selected_course
    response.status = 404
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Class not found"
    next
  end

  if request.request_method == "POST"
    begin
      if manual_assignment_action
        update_manual_coursework(request)
        location = "/settings/grades"
      else
        existing = load_grade_overrides
        overrides = grade_override_fields(
          request,
          data,
          existing,
          course_id: selected_course_id
        )
        save_grade_overrides(overrides)
        location = "/"
      end

      response.status = 303
      response["Location"] = location
      response.body = ""
    rescue ArgumentError => e
      response.status = 422
      response["Content-Type"] = "text/plain; charset=utf-8"
      response.body = e.message
    end

    next
  end

  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET, POST"
    response.body = "Method not allowed"
    next
  end

  overrides = load_grade_overrides
  mappings = load_course_name_mappings
  template = ERB.new(
    File.read(File.join(APP_ROOT, "views", "grades.erb"))
  )

  response.status = 200
  response["Content-Type"] = "text/html; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = template.result(binding)
rescue => e
  puts "Grade settings error: #{e.class}: #{e.message}"

  response.status = 500
  response["Content-Type"] = "text/plain; charset=utf-8"
  response.body = "Unable to load grade settings."
end

# ============================================================
# Home Assistant API
# ============================================================

server.mount_proc "/api/status" do |request, response|
  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  data = dashboard_data_with_manual || {}
  now = Time.now
  today = now.getlocal.to_date
  tomorrow = today + 1

  incomplete_upcoming = Array(data["upcoming"]).reject do |assignment|
    submission_complete?(
      submission_for(
        data,
        assignment_course_id(assignment),
        assignment_id(assignment)
      )
    )
  end

  latest_event = dashboard_events.last

  response.status = 200
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = JSON.generate(
    {
      "updated_at" => dashboard_status[:updated_at]&.iso8601,
      "canvas_available" => !data.empty? && dashboard_status[:error].nil?,
      "missing_count" => Array(data["missing"]).length,
      "due_today_count" => incomplete_upcoming.count do |assignment|
        assignment_due_time(assignment)&.getlocal&.to_date == today
      end,
      "due_tomorrow_count" => incomplete_upcoming.count do |assignment|
        assignment_due_time(assignment)&.getlocal&.to_date == tomorrow
      end,
      "latest_event_id" => latest_event&.dig("id") || 0,
      "latest_event" => latest_event
    }
  )
end

server.mount_proc "/api/events" do |request, response|
  unless request.request_method == "GET"
    response.status = 405
    response["Allow"] = "GET"
    response.body = "Method not allowed"
    next
  end

  after_value = request.query["after"].to_s
  limit_value = request.query.fetch("limit", "100").to_s

  unless (after_value.empty? || after_value.match?(/\A\d+\z/)) &&
      limit_value.match?(/\A\d+\z/)
    response.status = 400
    response.body = "Invalid query parameters"
    next
  end

  after_id = after_value.empty? ? nil : after_value.to_i
  limit = [[limit_value.to_i, 1].max, 100].min
  events = dashboard_events(after_id: after_id).last(limit)

  response.status = 200
  response["Content-Type"] = "application/json; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = JSON.generate(
    {
      "events" => events,
      "latest_event_id" => dashboard_events.last&.dig("id") || 0
    }
  )
end

# ============================================================
# CSS
# ============================================================

server.mount_proc "/dashboard.css" do |_request, response|
  response.status = 200
  response["Content-Type"] = "text/css; charset=utf-8"
  response["Cache-Control"] = "public, max-age=300"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "dashboard.css")
    )
end

# ============================================================
# Chart.js
# ============================================================

server.mount_proc "/chart.umd.min.js" do |_request, response|
  response.status = 200
  response["Content-Type"] = "text/javascript; charset=utf-8"
  response["Cache-Control"] = "public, max-age=86400"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "chart.umd.min.js")
    )
end

# ============================================================
# Navigation JavaScript
# ============================================================

server.mount_proc "/modules.js" do |_request, response|
  response.status = 200
  response["Content-Type"] = "text/javascript; charset=utf-8"
  response["Cache-Control"] = "no-cache"
  response.body = File.read(File.join(APP_ROOT, "public", "modules.js"))
end

server.mount_proc "/navigation.js" do |_request, response|
  response.status = 200
  response["Content-Type"] = "text/javascript; charset=utf-8"
  response["Cache-Control"] = "public, max-age=86400"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "navigation.js")
    )
end

# ============================================================
# App Icon
# ============================================================

server.mount_proc "/emberguide-icon.svg" do |_request, response|
  response.status = 200
  response["Content-Type"] = "image/svg+xml"
  response["Cache-Control"] = "public, max-age=86400"

  response.body =
    File.read(
      File.join(APP_ROOT, "public", "emberguide-icon.svg")
    )
end

server.mount_proc "/emberguide-icon.png" do |_request, response|
  response.status = 200
  response["Content-Type"] = "image/png"
  response["Cache-Control"] = "public, max-age=86400"

  response.body =
    File.binread(
      File.join(APP_ROOT, "icon.png")
    )
end

# ============================================================
# PWA Manifest
# ============================================================

server.mount_proc "/manifest.json" do |_request, response|
  response.status = 200
  response["Content-Type"] = "application/manifest+json"
  response["Cache-Control"] = "no-cache"

  response.body = JSON.generate(
    {
      name: "EmberGuide",
      short_name: "EmberGuide",
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#080711",
      theme_color: "#171427",

      icons: [
        {
          src: "/emberguide-icon.svg",
          sizes: "any",
          type: "image/svg+xml",
          purpose: "any"
        }
      ]
    }
  )
end

# ============================================================
# Shutdown
# ============================================================

if $PROGRAM_NAME == __FILE__
  trap("TERM") do
    puts "Stopping EmberGuide..."
    server.shutdown
  end

  trap("INT") do
    puts "Stopping EmberGuide..."
    server.shutdown
  end

  puts(
    "EmberGuide listening on port " \
    "#{server.config[:Port]}"
  )

  server.start
end