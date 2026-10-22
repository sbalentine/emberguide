def fetch_module_catalog(courses, previous: nil)
  catalog = {}
  errors = {}
  updated_at = {}
  hidden_ids = load_hidden_course_ids

  courses.each do |course|
    course_id = course.fetch("id").to_s
    next if hidden_ids.include?(course_id)

    begin
      modules = canvas_get_all(
        "/api/v1/courses/#{CGI.escape(course_id)}/modules" \
        "?include%5B%5D=items&include%5B%5D=content_details&per_page=100"
      )
      modules.reject! { |mod| mod["published"] == false }
      modules.each do |mod|
        if !mod["items"].is_a?(Array) || mod["items"].length < mod["items_count"].to_i
          mod["items"] = canvas_get_all(
            "/api/v1/courses/#{CGI.escape(course_id)}/modules/#{CGI.escape(mod.fetch("id").to_s)}/items" \
            "?include%5B%5D=content_details&per_page=100"
          )
        end
        mod["items"] = mod["items"].reject { |item| item["published"] == false }
          .sort_by { |item| item["position"].to_i }
      end
      modules.sort_by! { |mod| mod["position"].to_i }
      fetched = {}
      attach_module_submissions(
        course_id,
        modules,
        known_quizzes: known_module_quiz_assignments(previous&.dig("modules", course_id)),
        fetched: fetched
      )
      attach_module_item_content(
        course_id,
        modules,
        known: known_module_item_content(previous&.dig("modules", course_id)),
        fetched: fetched
      )
      catalog[course_id] = modules
      updated_at[course_id] = Time.now.iso8601
    rescue StandardError => e
      puts "Unable to refresh modules for course #{course_id}: #{e.class}: #{e.message}"
      errors[course_id] = "Could not refresh modules. Check Canvas access and try refreshing again."
      if previous&.dig("modules", course_id)
        catalog[course_id] = previous["modules"][course_id]
        updated_at[course_id] = previous.dig("modules_updated_at", course_id)
      end
    end
  end

  {
    "modules" => catalog,
    "modules_errors" => errors,
    "modules_updated_at" => updated_at
  }
end

MODULE_SUBMISSION_FIELDS = %w[workflow_state submitted_at excused missing late score].freeze

# Classic quiz module items point at the quiz, not its assignment, so each
# quiz is looked up for its assignment id. Quizzes are fetched one at a time
# because teachers can disable the course quiz list while single quizzes stay
# readable. Links from the previous refresh are reused, so only new quizzes
# cost a request. Practice quizzes and surveys have no assignment (stored as
# nil) and get no status.
def attach_module_quiz_assignments(course_id, modules, known: {}, fetched: {})
  quizzes = modules.flat_map { |mod| mod["items"] }
    .select { |item| item["type"] == "Quiz" && item["content_id"] }

  assignment_ids = quizzes.map { |item| item["content_id"].to_s }.uniq.to_h do |quiz_id|
    next [quiz_id, known[quiz_id]] if known.key?(quiz_id)

    path = "/api/v1/courses/#{CGI.escape(course_id)}/quizzes/#{CGI.escape(quiz_id)}"
    quiz = fetched[path] = canvas_get(path)
    [quiz_id, quiz["assignment_id"]]
  rescue StandardError => e
    puts "Unable to fetch module quiz #{quiz_id} for course #{course_id}: #{e.class}: #{e.message}"
    [quiz_id, :unknown]
  end

  quizzes.each do |item|
    assignment_id = assignment_ids[item["content_id"].to_s]
    item["assignment_id"] = assignment_id unless assignment_id == :unknown
  end
end

def known_module_quiz_assignments(modules)
  Array(modules).flat_map { |mod| Array(mod["items"]) }.each_with_object({}) do |item, known|
    next unless item["type"] == "Quiz" && item["content_id"] && item.key?("assignment_id")

    known[item["content_id"].to_s] = item["assignment_id"]
  end
end

def module_item_assignment_id(item)
  case item["type"]
  when "Assignment" then item["content_id"]
  when "Quiz" then item["assignment_id"]
  end
end

# Status is best-effort: a failure leaves items without a status rather than
# failing the whole course's modules.
def attach_module_submissions(course_id, modules, known_quizzes: {}, fetched: {})
  attach_module_quiz_assignments(course_id, modules, known: known_quizzes, fetched: fetched)
  items = modules.flat_map { |mod| mod["items"] }
    .select { |item| module_item_assignment_id(item) }
  return if items.empty?

  by_assignment = {}
  items.map { |item| module_item_assignment_id(item).to_s }.uniq.each_slice(50) do |ids|
    query = ids.map { |id| "assignment_ids%5B%5D=#{CGI.escape(id)}" }.join("&")
    canvas_get_all(
      "/api/v1/courses/#{CGI.escape(course_id)}/students/submissions" \
      "?student_ids%5B%5D=self&#{query}&per_page=100"
    ).each do |submission|
      by_assignment[submission["assignment_id"].to_s] =
        submission.slice(*MODULE_SUBMISSION_FIELDS)
    end
  end

  items.each do |item|
    submission = by_assignment[module_item_assignment_id(item).to_s]
    item["submission"] = submission if submission
  end
rescue StandardError => e
  puts "Unable to fetch module submissions for course #{course_id}: #{e.class}: #{e.message}"
end

MODULE_CONTENT_FIELDS = {
  "Page" => "body",
  "Assignment" => "description",
  "Quiz" => "description",
  "Discussion" => "message"
}.freeze
MODULE_CONTENT_MAX_AGE = 60 * 60
MODULE_CONTENT_MAX_TEXT = 20_000

def module_content_path(course_id, item)
  course = CGI.escape(course_id.to_s)
  id = CGI.escape(item["content_id"].to_s)
  case item["type"]
  when "Page"
    "/api/v1/courses/#{course}/pages/#{CGI.escape(item["page_url"].to_s)}" if item["page_url"]
  when "Assignment" then "/api/v1/courses/#{course}/assignments/#{id}" if item["content_id"]
  when "Quiz" then "/api/v1/courses/#{course}/quizzes/#{id}" if item["content_id"]
  when "Discussion" then "/api/v1/courses/#{course}/discussion_topics/#{id}" if item["content_id"]
  end
end

def known_module_item_content(modules)
  Array(modules).flat_map { |mod| Array(mod["items"]) }.each_with_object({}) do |item, known|
    known[item["id"].to_s] = item["content"] if item["content"]
  end
end

# Saves the readable text of this week's pages, assignment instructions,
# quizzes, and discussions so they open inside EmberGuide (and can later be
# handed to an assistant). Saved copies from earlier refreshes are kept for
# every item and only re-checked hourly; failures keep the last copy.
# `fetched` holds records already requested this refresh (quizzes).
def attach_module_item_content(course_id, modules, known: {}, fetched: {}, now: Time.now)
  modules.each do |mod|
    Array(mod["items"]).each do |item|
      saved = known[item["id"].to_s]
      item["content"] = saved if saved
    end
  end

  Array(current_week_module(modules)&.fetch("items", nil)).each do |item|
    path = module_content_path(course_id, item)
    next if path.nil? || item.dig("content_details", "locked_for_user") == true

    fetched_at = parse_canvas_time(item.dig("content", "fetched_at"))
    next if fetched_at && now - fetched_at < MODULE_CONTENT_MAX_AGE

    begin
      record = fetched[path]
      item["content"] =
        if record
          module_html_content(record[MODULE_CONTENT_FIELDS.fetch(item["type"])])
            .merge("updated_at" => record["updated_at"], "fetched_at" => now.iso8601)
        else
          module_item_content_record(course_id, item).merge("fetched_at" => now.iso8601)
        end
    rescue StandardError => e
      puts "Unable to fetch module item #{item["id"]} for course #{course_id}: #{e.class}: #{e.message}"
    end
  end
end

def module_html_attribute(attributes, name)
  match = attributes.to_s.match(/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
  match && CGI.unescapeHTML(match.captures.compact.first.to_s.strip)
end

def module_content_url(href)
  return if href.nil? || href.empty? || href.start_with?("#")

  uri = URI.join("#{BASE_URL}/", href)
  uri.to_s if %w[http https].include?(uri.scheme)
rescue URI::Error
  nil
end

MODULE_HTML_ENTITIES = {
  "ndash" => "–", "mdash" => "—", "lsquo" => "‘", "rsquo" => "’", "ldquo" => "“",
  "rdquo" => "”", "hellip" => "…", "bull" => "•", "middot" => "·", "deg" => "°",
  "times" => "×", "divide" => "÷", "frac12" => "½", "copy" => "©"
}.freeze

def module_unescape_html(text)
  CGI.unescapeHTML(text.gsub(/&nbsp;/i, " ").gsub(/&([a-z0-9]+);/i) { MODULE_HTML_ENTITIES.fetch(Regexp.last_match(1), Regexp.last_match(0)) })
    .tr("\u00a0", " ")
end

def module_plain_text(html)
  module_unescape_html(html.to_s.gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ").strip
end

# Teachers often lay out a day as a one-row table under column headings
# ("In Class Agenda", "Homework", ...). Those become heading + cell blocks so
# each cell keeps its label; other tables become one block per cell.
def module_table_html(table)
  rows = table.scan(%r{<tr\b[^>]*>(.*?)</tr\s*>}mi).map do |(row)|
    row.scan(%r{<t[dh]\b[^>]*>(.*?)</t[dh]\s*>}mi).map(&:first)
  end.reject(&:empty?)
  headers = Array(rows.first).map { |cell| module_plain_text(cell) }
  labeled = rows.length >= 2 &&
    headers.all? { |header| !header.empty? && header.length <= 60 } &&
    rows.drop(1).all? { |row| row.length == headers.length }
  return rows.flatten.map { |cell| "<div>#{cell}</div>" }.join unless labeled

  rows.drop(1).map do |row|
    row.each_with_index.filter_map do |cell, index|
      next if module_plain_text(cell).empty?

      "<h4>#{CGI.escapeHTML(headers[index])}</h4><div>#{cell}</div>"
    end.join
  end.join("<hr>")
end

# Teacher HTML is reduced to plain text plus a list of links, so nothing from
# Canvas is ever rendered as markup. Images and embeds become placeholders and
# headings are kept as "## " lines.
def module_html_content(html)
  links = []
  text = html.to_s.gsub(/\s+/, " ")
    .gsub(%r{<(script|style|noscript)\b[^>]*>.*?</\1\s*>}mi, " ")
    .gsub(/<!--.*?-->/m, " ")
    .gsub(%r{<table\b[^>]*>(.*?)</table\s*>}mi) { module_table_html(Regexp.last_match(1)) }
    .gsub(%r{<iframe\b([^>]*)>.*?</iframe\s*>}mi) do
      url = module_content_url(module_html_attribute(Regexp.last_match(1), "src"))
      links << { "text" => "Embedded content", "url" => url } if url
      "\n[Embedded content]\n"
    end
    .gsub(/<img\b([^>]*)>/i) do
      alt = module_html_attribute(Regexp.last_match(1), "alt").to_s
      alt.empty? ? " [Image] " : " [Image: #{alt}] "
    end
    .gsub(%r{<a\b([^>]*)>(.*?)</a\s*>}mi) do
      inner = Regexp.last_match(2)
      url = module_content_url(module_html_attribute(Regexp.last_match(1), "href"))
      label = module_plain_text(inner)
      links << { "text" => label.empty? ? url : label, "url" => url } if url
      inner
    end
    .gsub(%r{<h[1-6]\b[^>]*>(.*?)</h[1-6]\s*>}mi) do
      heading = module_plain_text(Regexp.last_match(1))
      heading.empty? ? "\n\n" : "\n\n## #{CGI.escapeHTML(heading)}\n\n"
    end
    .gsub(/<li\b[^>]*>/i, "\n• ")
    .gsub(%r{</li\s*>}i, "")
    .gsub(%r{<br\s*/?>}i, "\n")
    .gsub(%r{</?(p|div|h[1-6]|ul|ol|tr|table|tbody|thead|blockquote|section|article|header|footer|pre|hr)\b[^>]*>}i, "\n\n")
    .gsub(%r{</t[dh]\s*>}i, "\n\n")
    .gsub(/<[^>]*>/, "")
  text = module_unescape_html(text)
    .lines.map { |line| line.gsub(/[ \t]+/, " ").strip }.join("\n")
    .gsub(/\n{3,}/, "\n\n").strip
  text = "#{text[0, MODULE_CONTENT_MAX_TEXT].rstrip}…" if text.length > MODULE_CONTENT_MAX_TEXT

  { "text" => text, "links" => links.uniq { |link| link["url"] } }
end

def module_item_content_record(course_id, item)
  path = module_content_path(course_id, item)
  return unless path

  record = canvas_get(path)
  module_html_content(record[MODULE_CONTENT_FIELDS.fetch(item["type"])])
    .merge("updated_at" => record["updated_at"], "fetched_at" => Time.now.iso8601)
end

def module_item_content_loadable?(course_id, item)
  !module_content_path(course_id, item).nil? && item.dig("content_details", "locked_for_user") != true
end

def find_module_item(data, course_id, item_id)
  Array(data&.dig("modules", course_id.to_s)).flat_map { |mod| Array(mod["items"]) }
    .find { |item| item["id"].to_s == item_id.to_s }
end

# Items outside this week are fetched the first time they are opened on the
# Modules page and then kept with the cache. While a refresh is running the
# copy is only kept in memory, so it can't overwrite the refresh's new cache.
def load_module_item_content(course_id, item_id)
  item = find_module_item(dashboard_data, course_id, item_id)
  return unless item && module_item_content_loadable?(course_id, item)
  return item if item["content"]

  content = module_item_content_record(course_id, item)
  saved = $refresh_mutex.try_lock
  begin
    $data_mutex.synchronize do
      current = find_module_item($dashboard_data, course_id, item_id)
      current["content"] = content if current
      save_cache($dashboard_data) if saved && current
    end
  ensure
    $refresh_mutex.unlock if saved
  end
  item.merge("content" => content)
end

def module_item_content_html(course_id, item)
  content = item["content"] || {}
  blocks = content["text"].to_s.split(/\n{2,}/).reject(&:empty?)
  html = +%(<div class="module-content">)
  if blocks.empty?
    html << %(<p class="module-content-empty">No written instructions saved. Open it in Canvas for files or embedded content.</p>)
  end
  blocks.each do |block|
    if block.start_with?("## ")
      html << %(<p class="module-content-heading">#{h block.delete_prefix("## ").strip}</p>)
    else
      html << "<p>#{block.lines.map { |line| h(line.chomp) }.join("<br>")}</p>"
    end
  end
  links = Array(content["links"])
  if links.any?
    html << %(<div class="module-content-links"><span>Links</span><ul>)
    links.each do |link|
      html << %(<li><a href="#{h link["url"]}" target="_blank" rel="noopener noreferrer">#{h link["text"]}</a></li>)
    end
    html << "</ul></div>"
  end
  fetched_at = parse_canvas_time(content["fetched_at"])
  html << %(<div class="module-content-footer">)
  html << %(<a class="module-link" href="#{h module_item_url(course_id, item)}" target="_blank" rel="noopener noreferrer">Open in Canvas<span class="module-sr-only"> (new tab)</span></a>)
  html << %(<span>Saved #{h date_label(fetched_at)} &middot; #{h due_time_label(fetched_at)}</span>) if fetched_at
  html << "</div></div>"
end

# Returns [label, css modifier] or nil when there is nothing to report yet.
def module_item_status(item)
  submission = item["submission"]
  return unless submission

  if submission["excused"] == true
    ["Excused", "done"]
  elsif submission["missing"] == true && submission["submitted_at"].nil?
    ["Missing", "missing"]
  elsif submission["workflow_state"] == "graded"
    ["Graded", "done"]
  elsif submission["submitted_at"] || %w[submitted pending_review].include?(submission["workflow_state"])
    submission["late"] == true ? ["Turned in late", "late"] : ["Turned in", "done"]
  end
end

def module_item_done?(item)
  %w[done late].include?(module_item_status(item)&.last)
end

# "8/10" for graded work, using a local grade correction when one exists so
# modules agree with the dashboard's grades.
def module_item_score(item, grade_overrides = {})
  return unless module_item_status(item)&.first == "Graded"

  override = grade_overrides.fetch("canvas", {})[module_item_assignment_id(item).to_s] || {}
  score = override["score"].nil? ? item.dig("submission", "score") : override["score"]
  possible = override["points_possible"].nil? ? item.dig("content_details", "points_possible") : override["points_possible"]
  return if score.nil?

  possible.nil? ? format_number(score).to_s : "#{format_number(score)}/#{format_number(possible)}"
end

def module_item_due_tomorrow?(item, due, today: Date.today)
  due.getlocal.to_date == today + 1 && !module_item_done?(item)
end

# Returns [label, css modifier] explaining why Canvas locked an item, or nil
# when the lock is just a finished assignment closing.
def module_item_lock_status(item, now: Time.now)
  details = item["content_details"] || {}
  return unless details["locked_for_user"] == true

  unlock_at = parse_canvas_time(details["unlock_at"])
  lock_at = parse_canvas_time(details["lock_at"])
  if unlock_at && unlock_at > now
    ["Opens #{date_label(unlock_at)} · #{due_time_label(unlock_at)}", "upcoming"]
  elsif lock_at && lock_at <= now
    status = module_item_status(item)
    return if module_item_done?(item)

    ["Closed #{grade_date(details["lock_at"])}", "closed"]
  else
    explanation = CGI.unescapeHTML(details["lock_explanation"].to_s.gsub(/<[^>]*>/, " ")).squeeze(" ").strip
    [explanation.empty? ? "Locked in Canvas" : "Locked: #{explanation}", "locked"]
  end
end

# Splits module items into an untitled lead-in and one group per Canvas
# text header, so each header can collapse the items listed beneath it.
def module_item_groups(items)
  groups = [{ "heading" => nil, "items" => [] }]
  Array(items).each do |item|
    if item["type"] == "SubHeader"
      groups << { "heading" => item, "items" => [] }
    else
      groups.last["items"] << item
    end
  end
  groups.reject { |group| group["heading"].nil? && group["items"].empty? }
end

def module_group_summary(items)
  assignments = items.select { |item| item["submission"] }
  summary = "#{items.length} #{items.length == 1 ? "item" : "items"}"
  return summary if assignments.empty?

  done = assignments.count { |item| module_item_done?(item) }
  "#{summary} · #{done} of #{assignments.length} assignments done"
end

WEEKLY_WORK_TYPES = %w[Assignment Quiz Discussion].freeze

# Teachers list the current week first, sometimes after a pinned "Resources"
# module, so the first non-resources module is treated as this week's.
def current_week_module(modules)
  Array(modules).find { |mod| !mod["name"].to_s.match?(/resources/i) }
end

# Prefers gradable work; classes that post the week as daily pages fall back
# to those pages so the class still has something to open.
def this_week_links(mod)
  items = Array(mod&.fetch("items", nil)).reject { |item| item["type"] == "SubHeader" }
  work = items.select { |item| WEEKLY_WORK_TYPES.include?(item["type"]) }
  work.any? ? [work, :work] : [items, :pages]
end

# Unfinished module work due tomorrow, shaped like Canvas planner events so
# the dashboard's assignment helpers can render it. Items matching an
# assignment already in `known_events` (by id or name) are skipped.
def module_due_tomorrow_events(data, known_events: [], today: Date.today)
  known = Array(known_events).map do |event|
    [assignment_course_id(event).to_s, assignment_id(event).to_s, assignment_name(event).strip.downcase]
  end

  visible_module_courses(data).flat_map do |course|
    course_id = course["id"].to_s
    Array(data.dig("modules", course_id)).flat_map { |mod| Array(mod["items"]) }.filter_map do |item|
      due = parse_canvas_time(item.dig("content_details", "due_at"))
      next unless due && module_item_due_tomorrow?(item, due, today: today)

      {
        "course_id" => course_id,
        "assignment_id" => module_item_assignment_id(item),
        "name" => item["title"],
        "due_at" => item.dig("content_details", "due_at"),
        "html_url" => module_item_url(course_id, item)
      }
    end
  end.each_with_object([]) do |event, events|
    name = event["name"].to_s.strip.downcase
    duplicate = (known + events.map { |e| [e["course_id"], e["assignment_id"].to_s, e["name"].to_s.strip.downcase] }).any? do |course_id, id, known_name|
      course_id == event["course_id"] &&
        ((!id.empty? && id == event["assignment_id"].to_s) || known_name == name)
    end
    events << event unless duplicate
  end
end

def visible_module_courses(data)
  Array(data["courses"]).reject do |course|
    course["id"].to_s.start_with?("manual-")
  end
end

def module_key(course_id, mod)
  "#{course_id}-#{mod.fetch("id")}"
end

def module_canvas_url(course_id, mod)
  "#{BASE_URL}/courses/#{CGI.escape(course_id.to_s)}/modules/#{CGI.escape(mod.fetch("id").to_s)}"
end

def module_item_url(course_id, item)
  return nil if item["type"] == "SubHeader"

  "#{BASE_URL}/courses/#{CGI.escape(course_id.to_s)}/modules/items/#{CGI.escape(item.fetch("id").to_s)}"
end

def module_progress(mod)
  requirements = Array(mod["items"]).filter_map { |item| item["completion_requirement"] }
  return if requirements.empty?

  completed = requirements.count { |requirement| requirement["completed"] == true }
  "#{completed} of #{requirements.length} requirements complete"
end
