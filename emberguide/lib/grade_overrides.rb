require "fileutils"
require "json"

GRADE_OVERRIDES_MUTEX = Mutex.new

GRADE_OVERRIDES_FILE =
  ENV.fetch("GRADE_OVERRIDES_FILE") do
    if File.directory?("/data")
      "/data/grade_overrides.json"
    else
      File.expand_path(
        "../tmp/grade_overrides.json",
        __dir__
      )
    end
  end

def load_grade_overrides
  return {} unless File.exist?(GRADE_OVERRIDES_FILE)

  overrides = JSON.parse(File.read(GRADE_OVERRIDES_FILE))
  return {} unless overrides.is_a?(Hash)

  result = {
    "canvas" => overrides["canvas"].is_a?(Hash) ? overrides["canvas"] : {},
    "custom" => overrides["custom"].is_a?(Hash) ? overrides["custom"] : {}
  }
  if overrides.key?("grading")
    raise CourseGradingError, "Saved class grading settings are invalid. Restore a backup or repair the settings file." unless valid_course_grading?(overrides["grading"])

    result["grading"] = overrides["grading"]
  end
  result
rescue JSON::ParserError => e
  puts "Unable to load official grades: #{e.message}"
  {}
end

def save_grade_overrides(overrides)
  if overrides.key?("grading") && !valid_course_grading?(overrides["grading"])
    raise ArgumentError, "Invalid class grading settings."
  end
  FileUtils.mkdir_p(File.dirname(GRADE_OVERRIDES_FILE))

  saved = {
    "canvas" => overrides.fetch("canvas", {}).sort.to_h,
    "custom" => overrides.fetch("custom", {}).sort.to_h
  }
  saved["grading"] = overrides["grading"] if overrides.key?("grading")
  temporary_file = "#{GRADE_OVERRIDES_FILE}.tmp.#{$$}"
  File.write(
    temporary_file,
    JSON.pretty_generate(saved)
  )
  File.rename(temporary_file, GRADE_OVERRIDES_FILE)
end

def canvas_assignment_hidden?(item, overrides)
  overrides.fetch("canvas", {}).dig(assignment_id(item).to_s, "hidden") == true
end

def editable_canvas_submissions(data)
  submissions = Array(data["grades"]).dup
  data.fetch("submissions", {}).each_value do |course_submissions|
    submissions.concat(course_submissions.values)
  end
  (Array(data["missing"]) + Array(data["upcoming"])).each do |item|
    assignment = item["assignment"] || item
    submissions << { "assignment_id" => assignment["id"], "assignment" => assignment }
  end

  submissions.select do |submission|
    assignment = submission["assignment"] || {}
    assignment_id(submission) && assignment["_manual"] != true
  end.uniq { |submission| assignment_id(submission).to_s }
end

def hide_assignments_from_dashboard(data, overrides)
  data.merge(
    %w[grades missing upcoming].to_h do |collection|
      [collection, Array(data[collection]).reject do |item|
        canvas_assignment_hidden?(item, overrides)
      end]
    end
  )
end

def reconcile_canvas_grade_overrides(data)
  GRADE_OVERRIDES_MUTEX.synchronize do
    reconcile_canvas_grade_overrides_locked(data)
  end
end

def reconcile_canvas_grade_overrides_locked(data)
  overrides = load_grade_overrides
  canvas_overrides = overrides.fetch("canvas", {})
  changed = false
  removed_assignment_ids = []

  submissions_by_assignment = editable_canvas_submissions(data).each_with_object({}) do |submission, index|
    assignment_id =
      submission["assignment_id"] ||
      submission.dig("assignment", "id")

    index[assignment_id.to_s] = submission if assignment_id
  end

  canvas_overrides.delete_if do |assignment_id, override|
    submission = submissions_by_assignment[assignment_id]
    next false unless submission

    current_values = {
      "canvas_score" => submission["score"],
      "canvas_points_possible" =>
        submission.dig("assignment", "points_possible"),
      "canvas_graded_at" => submission["graded_at"]
    }

    baseline_missing = current_values.keys.any? do |key|
      !override.key?(key)
    end

    if baseline_missing
      override.merge!(current_values)
      changed = true
      next false
    end

    canvas_changed = current_values.any? do |key, value|
      override[key] != value
    end

    if canvas_changed
      removed_assignment_ids << assignment_id
      changed = true
    end

    canvas_changed
  end

  save_grade_overrides(overrides) if changed
  removed_assignment_ids
end
