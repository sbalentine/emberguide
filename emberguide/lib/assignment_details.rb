ASSIGNMENT_FIELDS = %w[
  id course_id name due_at unlock_at lock_at points_possible submission_types
  html_url is_quiz_assignment quiz_id locked_for_user updated_at
].freeze
ASSIGNMENT_SUBMISSION_FIELDS = (MODULE_SUBMISSION_FIELDS + %w[graded_at]).freeze

# Saves every assignment in each visible class with its instructions as
# readable text, so assignments open inside EmberGuide and Spark can read the
# full instructions. One paginated request per class; instructions are only
# re-read when Canvas reports the assignment changed. A failed class keeps its
# previous copy.
def fetch_assignment_catalog(courses, previous: nil, now: Time.now)
  catalog = {}
  errors = {}
  hidden_ids = load_hidden_course_ids

  courses.each do |course|
    course_id = course.fetch("id").to_s
    next if hidden_ids.include?(course_id)

    known = Array(previous&.dig("assignments", course_id)).to_h { |record| [record["id"].to_s, record] }
    begin
      catalog[course_id] = canvas_get_all(
        "/api/v1/courses/#{CGI.escape(course_id)}/assignments" \
        "?include%5B%5D=submission&order_by=due_at&per_page=100"
      ).map { |assignment| assignment_record(assignment, known[assignment["id"].to_s], now) }
    rescue StandardError => e
      puts "Unable to refresh assignments for course #{course_id}: #{e.class}: #{e.message}"
      errors[course_id] = "Could not refresh assignments."
      catalog[course_id] = previous["assignments"][course_id] if previous&.dig("assignments", course_id)
    end
  end

  { "assignments" => catalog, "assignments_errors" => errors }
end

def assignment_record(assignment, known, now)
  record = assignment.slice(*ASSIGNMENT_FIELDS)
  submission = assignment["submission"]
  record["submission"] = submission.slice(*ASSIGNMENT_SUBMISSION_FIELDS) if submission.is_a?(Hash)
  record["content"] =
    if known&.dig("content") && known["updated_at"] == assignment["updated_at"]
      known["content"]
    else
      module_html_content(assignment["description"])
        .merge("updated_at" => assignment["updated_at"], "fetched_at" => now.iso8601)
    end
  record
end

def find_assignment_record(data, course_id, id)
  return if course_id.to_s.empty? || id.to_s.empty?

  Array(data&.dig("assignments", course_id.to_s)).find { |record| record["id"].to_s == id.to_s }
end

# Instructions for an assignment: the saved catalog copy, else the description
# Canvas sent along with the event (upcoming, missing, and graded lists all
# include one), else nothing.
def assignment_saved_content(data, course_id, id, event = nil)
  content = find_assignment_record(data, course_id, id)&.dig("content")
  return content if content

  description = event && (event.dig("assignment", "description") || event["description"])
  return event["content"] if description.nil? && event.is_a?(Hash) && event["content"].is_a?(Hash)

  module_html_content(description) if description
end

# Module assignments and quizzes without their own saved copy fall back to the
# assignment catalog.
def module_item_saved_content(data, course_id, item)
  item["content"] || find_assignment_record(data, course_id, module_item_assignment_id(item))&.dig("content")
end

# An assignment title that opens its saved instructions in place, or a Canvas
# link when none are saved.
def assignment_title_html(title, url, content)
  if content
    %(<details class="module-item-details assignment-details"><summary>#{h title}) +
      %(<span class="module-sr-only"> (show instructions)</span></summary>#{saved_content_html(content, url)}</details>)
  elsif url
    %(<a href="#{h url}" target="_blank" rel="noopener noreferrer">#{h title}) +
      %(<span class="module-sr-only"> (opens in Canvas in a new tab)</span></a>)
  else
    h(title).to_s
  end
end

# Open work Spark should know about: unlocked, not graded, and not excused.
def assignment_open_for_ai?(record)
  submission = record["submission"] || {}
  record["locked_for_user"] != true &&
    submission["workflow_state"] != "graded" &&
    submission["score"].nil? &&
    submission["excused"] != true
end
