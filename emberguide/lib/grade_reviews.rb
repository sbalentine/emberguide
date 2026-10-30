require "fileutils"
require "json"
require "securerandom"

GRADE_REVIEWS_FILE = ENV.fetch("GRADE_REVIEWS_FILE") do
  File.join(File.dirname(CACHE_FILE), "grade_reviews.json")
end
GRADE_REVIEWS_MUTEX = Mutex.new
GRADE_REVIEW_THRESHOLD = 70

class GradeReviewError < StandardError; end

def grade_review_key(course_id, assignment_id)
  JSON.generate([course_id.to_s, assignment_id.to_s])
end

def valid_grade_reviews?(state)
  state.is_a?(Hash) && state.all? do |key, entry|
    entry.is_a?(Hash) &&
      %w[course_id assignment_id name course_name].all? { |field| entry[field].is_a?(String) && !entry[field].empty? } &&
      key == grade_review_key(entry["course_id"], entry["assignment_id"]) &&
      %w[score points_possible].all? { |field| entry[field].is_a?(Numeric) && entry[field].finite? } &&
      entry["points_possible"].positive? &&
      (entry["html_url"].nil? || (entry["html_url"].is_a?(String) && entry["html_url"].match?(%r{\Ahttps?://}i))) &&
      (entry["graded_at"].nil? || (entry["graded_at"].is_a?(String) && parse_canvas_time(entry["graded_at"]))) &&
      (entry["reviewed_at"].nil? || (entry["reviewed_at"].is_a?(String) && parse_canvas_time(entry["reviewed_at"])))
  end
end

def load_grade_reviews
  return {} unless File.exist?(GRADE_REVIEWS_FILE)

  state = JSON.parse(File.read(GRADE_REVIEWS_FILE))
  raise GradeReviewError, "Saved grade reviews are invalid. Restore a backup or repair grade_reviews.json." unless valid_grade_reviews?(state)

  state
rescue JSON::ParserError, SystemCallError, IOError => e
  raise GradeReviewError, "Unable to read saved grade reviews (#{e.class})."
end

def save_grade_reviews(state)
  raise GradeReviewError, "Unable to save invalid grade reviews." unless valid_grade_reviews?(state)

  FileUtils.mkdir_p(File.dirname(GRADE_REVIEWS_FILE))
  temporary = "#{GRADE_REVIEWS_FILE}.tmp.#{SecureRandom.hex(8)}"
  begin
    File.write(temporary, JSON.pretty_generate(state), perm: 0o600)
    File.rename(temporary, GRADE_REVIEWS_FILE)
  ensure
    FileUtils.rm_f(temporary)
  end
rescue SystemCallError, IOError => e
  raise GradeReviewError, "Unable to save grade reviews (#{e.class})."
end

def grade_review_entry(submission, data)
  assignment = submission["assignment"] || {}
  score = submission["score"]
  points = assignment["points_possible"]
  return nil if submission["excused"] == true || assignment["omit_from_final_grade"] == true
  return nil unless score.is_a?(Numeric) && points.is_a?(Numeric)
  return nil if !score.finite? || !points.finite? || points <= 0
  return nil unless assignment_course_id(submission) && assignment_id(submission)

  url = assignment_url(submission)
  {
    "course_id" => assignment_course_id(submission).to_s,
    "assignment_id" => assignment_id(submission).to_s,
    "name" => assignment_name(submission),
    "course_name" => data.fetch("course_names", {})[assignment_course_id(submission).to_s] || "Course #{assignment_course_id(submission)}",
    "score" => score.to_f,
    "points_possible" => points.to_f,
    "graded_at" => parse_canvas_time(submission["graded_at"])&.iso8601,
    "html_url" => url&.match?(%r{\Ahttps?://}i) ? url : nil
  }
end

def grade_requires_review?(entry)
  entry["score"].to_f / entry["points_possible"] * 100 < GRADE_REVIEW_THRESHOLD
end

def grade_review_percentage_label(entry)
  rounded = percentage(entry["score"], entry["points_possible"])
  grade_requires_review?(entry) && rounded >= GRADE_REVIEW_THRESHOLD ? "<70%" : "#{rounded}%"
end

def sync_grade_reviews_locked
  state = load_grade_reviews
  original = Marshal.load(Marshal.dump(state))
  data = dashboard_data_with_manual(include_hidden: true)
  return state unless data

  overrides = load_grade_overrides
  current = combined_grade_submissions(data, overrides).filter_map do |submission|
    entry = grade_review_entry(submission, data)
    [grade_review_key(entry["course_id"], entry["assignment_id"]), entry] if entry
  end.to_h
  Array(data["grades"]).each do |submission|
    key = grade_review_key(assignment_course_id(submission), assignment_id(submission))
    next if current.key?(key) || canvas_assignment_hidden?(submission, overrides)

    state.delete(key)
  end
  state.delete_if do |_key, entry|
    id = entry["assignment_id"]
    id.start_with?("custom-") && !overrides.fetch("custom", {}).key?(id.delete_prefix("custom-"))
  end

  current.each do |key, entry|
    previous = state[key]
    next unless previous || grade_requires_review?(entry)

    same_score = previous && previous["score"] == entry["score"] &&
      previous["points_possible"] == entry["points_possible"]
    state[key] = entry.merge("reviewed_at" => same_score ? previous["reviewed_at"] : nil)
  end
  save_grade_reviews(state) unless state == original
  state
end

def sync_grade_reviews
  GRADE_REVIEWS_MUTEX.synchronize { sync_grade_reviews_locked }
end

def unreviewed_grades(state)
  hidden = load_hidden_course_ids
  overrides = load_grade_overrides
  state.values.select do |entry|
    grade_requires_review?(entry) && entry["reviewed_at"].nil? &&
      !hidden.include?(entry["course_id"]) &&
      overrides.fetch("canvas", {}).dig(entry["assignment_id"], "hidden") != true
  end.sort_by do |entry|
    [-(parse_canvas_time(entry["graded_at"]) || Time.at(0)).to_f, entry["course_name"], entry["name"]]
  end
end

def update_grade_review(course_id, assignment_id, score:, points_possible:, reviewed:, now: Time.now)
  unless %w[true false].include?(reviewed)
    raise ArgumentError, "Choose whether the grade has been reviewed."
  end
  score = Float(score, exception: false)
  points = Float(points_possible, exception: false)
  unless score&.finite? && points&.finite? && points.positive?
    raise ArgumentError, "A valid grade is required. Reload the dashboard and try again."
  end

  GRADE_REVIEWS_MUTEX.synchronize do
    state = sync_grade_reviews_locked
    entry = state[grade_review_key(course_id, assignment_id)]
    unless entry && grade_requires_review?(entry)
      raise ArgumentError, "That grade no longer requires review. Reload the dashboard."
    end
    if load_hidden_course_ids.include?(entry["course_id"]) ||
       load_grade_overrides.fetch("canvas", {}).dig(entry["assignment_id"], "hidden") == true
      raise ArgumentError, "That assignment is hidden. Reload the dashboard."
    end
    unless entry["score"] == score && entry["points_possible"] == points
      raise ArgumentError, "The grade changed since this page loaded. Reload it and review the current score."
    end
    entry["reviewed_at"] = reviewed == "true" ? (entry["reviewed_at"] || now.iso8601) : nil
    save_grade_reviews(state)
  end
end
