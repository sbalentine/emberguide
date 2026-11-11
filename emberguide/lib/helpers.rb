require "time"
require "cgi"
require "json"

# ============================================================
# HTML / Number Formatting
# ============================================================

def h(value)
  CGI.escapeHTML(value.to_s)
end

def percentage(score, possible)
  return nil if score.nil? || possible.nil?
  return nil if possible.to_f <= 0

  ((score.to_f / possible.to_f) * 100).round(1)
end

def format_number(number)
  return "-" if number.nil?

  number.to_f % 1 == 0 ? number.to_i : number.round(1)
end

def letter_grade(percentage)
  return nil if percentage.nil?

  case percentage
  when 90.. then "A"
  when 80...90 then "B"
  when 70...80 then "C"
  when 60...70 then "D"
  else "F"
  end
end

def grade_trend_points(submissions)
  chronological = Array(submissions).filter_map do |submission|
    assignment = submission["assignment"] || {}
    recorded_at = parse_canvas_time(
      submission["graded_at"] || assignment["due_at"]
    )
    points_possible = assignment["points_possible"]

    next unless recorded_at && !submission["score"].nil?
    next if points_possible.nil? || points_possible.to_f < 0

    [recorded_at, submission]
  end.sort_by(&:first)

  earned = 0.0
  possible = 0.0

  chronological.filter_map do |recorded_at, submission|
    assignment = submission["assignment"]
    score = submission["score"].to_f
    points_possible = assignment["points_possible"].to_f
    earned += score
    possible += points_possible
    calculated = percentage(earned, possible)
    next unless calculated

    {
      "x" => recorded_at.to_i * 1000,
      "y" => calculated,
      "assignment" => assignment["name"],
      "score" => score,
      "points_possible" => points_possible,
      "earned" => earned,
      "possible" => possible
    }
  end
end

def json_for_html_script(value)
  JSON.generate(value)
    .gsub("&", "\\u0026")
    .gsub("<", "\\u003c")
    .gsub(">", "\\u003e")
end

def render_partial(name, view_binding)
  path = File.join(APP_ROOT, "views", "_#{name}.erb")
  ERB.new(
    File.read(path),
    eoutvar: "_partial_output"
  ).result(view_binding)
end

def navigation_profile_name
  profile_first_name(dashboard_data_with_manual || {})
end

def course_symbol(name)
  case name.to_s.downcase
  when /science|biology|chemistry|physics/
    "🧪"
  when /math|algebra|geometry|calculus/
    "➗"
  when /language arts|english|reading|literature|\bela\b/
    "📚"
  when /social studies|history|geography|civics|\bss\b/
    "🌎"
  when /drama|theater|theatre/
    "🎭"
  when /art/
    "🎨"
  when /music|band|choir/
    "🎵"
  when /physical education|\bpe\b/
    "🏃"
  else
    "🎓"
  end
end

def combined_grade_submissions(data, grade_overrides)
  visible_course_ids = Array(data["courses"]).to_h do |course|
    [course["id"].to_s, true]
  end

  canvas_grades = (data["grades"] || []).select do |submission|
    assignment = submission["assignment"]

    assignment &&
      !canvas_assignment_hidden?(submission, grade_overrides) &&
      !submission["score"].nil? &&
      !assignment["points_possible"].nil? &&
      assignment["omit_from_final_grade"] != true
  end

  combined = canvas_grades.map do |submission|
    assignment_id = (
      submission["assignment_id"] ||
      submission.dig("assignment", "id")
    ).to_s
    override = grade_overrides.fetch("canvas", {})[assignment_id]

    next submission unless override

    adjusted = JSON.parse(JSON.generate(submission))
    adjusted["_official_override"] = true
    adjusted["_canvas_score"] = submission["score"]
    adjusted["_canvas_points_possible"] =
      submission.dig("assignment", "points_possible")
    adjusted["score"] = override["score"] unless override["score"].nil?

    unless override["points_possible"].nil?
      adjusted["assignment"]["points_possible"] =
        override["points_possible"]
    end

    adjusted
  end

  grade_overrides.fetch("custom", {}).each do |grade_id, grade|
    next unless visible_course_ids.key?(grade["course_id"].to_s)

    combined << {
      "_official_override" => true,
      "_custom_grade" => true,
      "assignment_id" => "custom-#{grade_id}",
      "score" => grade["score"],
      "graded_at" => "#{grade["graded_at"]}T12:00:00",
      "assignment" => {
        "id" => "custom-#{grade_id}",
        "course_id" => grade["course_id"],
        "name" => grade["name"],
        "points_possible" => grade["points_possible"],
        "omit_from_final_grade" => false
      }
    }
  end

  combined
end

# ============================================================
# Course / Assignment Helpers
# ============================================================

def course_name(data, course_id)
  return "Unknown Course" if course_id.nil?

  data["course_names"][course_id.to_s] ||
    "Course #{course_id}"
end

def parse_canvas_time(value)
  return nil if value.nil?

  Time.parse(value)
rescue ArgumentError
  nil
end

def assignment_due_time(item)
  parse_canvas_time(
    item.dig("plannable", "todo_date") ||
    item.dig("assignment", "due_at") ||
    item["due_at"] ||
    item["start_at"]
  )
end

def assignment_name(item)
  item.dig("plannable", "title") ||
    item.dig("assignment", "name") ||
    item["name"] ||
    item["title"] ||
    "Untitled Assignment"
end

def assignment_course_id(item)
  item.dig("plannable", "course_id") ||
    item.dig("assignment", "course_id") ||
    item["course_id"]
end

def assignment_id(item)
  item.dig("assignment", "id") ||
    item["assignment_id"] ||
    item["id"]
end

def assignment_url(item)
  value = item.dig("assignment", "html_url") ||
    item["html_url"]

  return nil if value.to_s.empty?

  URI.join("#{BASE_URL}/", value).to_s
rescue URI::InvalidURIError
  value
end

def todo_details(item)
  item.dig("plannable", "details") ||
    item.dig("plannable", "description") ||
    ""
end

# ============================================================
# Date Formatting
# ============================================================

def date_label(time)
  return "No due date" unless time

  today = Date.today
  date = time.getlocal.to_date

  case date
  when today
    "Today"
  when today + 1
    "Tomorrow"
  else
    time.getlocal.strftime("%A, %B %-d")
  end
end

def due_time_label(time)
  return "" unless time

  time.getlocal.strftime("%-I:%M %p")
end

def grade_date(value)
  time = parse_canvas_time(value)
  return "No date" unless time

  time.getlocal.strftime("%b %-d")
end

def greeting_for(time = Time.now)
  case time.hour
  when 0...12
    "Good morning"
  when 12...17
    "Good afternoon"
  else
    "Good evening"
  end
end

def profile_first_name(data)
  name = data.dig("profile", "short_name") ||
    data.dig("profile", "name")

  name.to_s.strip.split.first || "there"
end

# ============================================================
# Submission Helpers
# ============================================================

def submission_for(data, course_id, assignment_id)
  return nil unless course_id && assignment_id

  data.dig(
    "submissions",
    course_id.to_s,
    assignment_id.to_s
  )
end

def submission_status(submission)
  unless submission
    return {
      label: "Not submitted",
      css: "not-submitted",
      icon: "○"
    }
  end

  if submission["missing"] == true
    return {
      label: "Missing",
      css: "missing-status",
      icon: "!"
    }
  end

  score = submission["score"]
  assignment = submission["assignment"] || {}
  points = assignment["points_possible"]

  unless score.nil?
    score_text =
      if points && points.to_f > 0
        "#{format_number(score)}/#{format_number(points)}"
      else
        format_number(score)
      end

    return {
      label: "Graded · #{score_text}",
      css: "graded",
      icon: "✓"
    }
  end

  if submission["late"] == true &&
      submission["workflow_state"] == "submitted"

    return {
      label: "Submitted late",
      css: "late-status",
      icon: "✓"
    }
  end

  if submission["workflow_state"] == "submitted" ||
      submission["submitted_at"]

    return {
      label: "Submitted",
      css: "submitted",
      icon: "✓"
    }
  end

  {
    label: "Not submitted",
    css: "not-submitted",
    icon: "○"
  }
end

def submission_complete?(submission)
  status = submission_status(submission)

  !%w[not-submitted missing-status].include?(status[:css])
end

def latest_submission_comment(submission)
  comments = submission && submission["submission_comments"]
  return nil unless comments.is_a?(Array)

  comments.reject do |comment|
    comment["comment"].to_s.strip.empty?
  end.max_by do |comment|
    parse_canvas_time(comment["created_at"]) || Time.at(0)
  end
end
