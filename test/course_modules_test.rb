require_relative "test_helper"

class CourseModulesTest < Minitest::Test
  def setup
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def test_fetches_missing_inline_items_and_preserves_teacher_order
    paths = []
    fetch = lambda do |path|
      paths << path
      if path.include?("/modules/10/items")
        [
          { "id" => 2, "position" => 2, "type" => "Page" },
          { "id" => 1, "position" => 1, "type" => "SubHeader" },
          { "id" => 3, "position" => 3, "published" => false }
        ]
      else
        [
          { "id" => 11, "position" => 2, "items" => [] },
          { "id" => 12, "published" => false },
          { "id" => 10, "position" => 1, "items_count" => 3, "items" => [] }
        ]
      end
    end

    result = with_replaced_method(self, :canvas_get_all, fetch) do
      fetch_module_catalog([{ "id" => 1 }])
    end
    assert_equal [10, 11], result["modules"]["1"].map { |mod| mod["id"] }
    assert_equal [1, 2], result["modules"]["1"].first["items"].map { |item| item["id"] }
    assert_equal 2, paths.length
    assert_empty result["modules_errors"]
    refute_nil result.dig("modules_updated_at", "1")
  end

  def test_failures_keep_last_copy_and_timestamp_and_are_reported
    previous = {
      "modules" => { "1" => [{ "id" => 10, "items" => [] }] },
      "modules_updated_at" => { "1" => "2026-10-20T12:00:00Z" }
    }
    result = nil
    output, = capture_io do
      with_replaced_method(self, :canvas_get_all, ->(_) { raise "401 Unauthorized" }) do
        result = fetch_module_catalog([{ "id" => 1 }, { "id" => 2 }], previous: previous)
      end
    end
    assert_includes output, "401 Unauthorized"
    assert_equal previous["modules"]["1"], result["modules"]["1"]
    assert_equal previous["modules_updated_at"]["1"], result["modules_updated_at"]["1"]
    assert_equal %w[1 2], result["modules_errors"].keys
    refute result["modules"].key?("2")
  end

  def test_hidden_courses_are_not_requested
    save_hidden_course_ids(["1"])
    with_replaced_method(self, :canvas_get_all, ->(_) { flunk "Hidden course requested" }) do
      result = fetch_module_catalog([{ "id" => 1 }])
      assert_empty result["modules"]
    end
  ensure
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def test_completion_counts_requirements_not_all_items
    assert_nil module_progress("items" => [{ "type" => "Page" }])
    mod = { "items" => [
      { "completion_requirement" => { "completed" => true } },
      { "completion_requirement" => { "completed" => false } },
      { "type" => "SubHeader" }
    ] }
    assert_equal "1 of 2 requirements complete", module_progress(mod)
    assert_nil module_item_url(1, "type" => "SubHeader")
    assert_equal "#{BASE_URL}/courses/1/modules/items/2",
      module_item_url(1, "type" => "Page", "id" => 2, "html_url" => "javascript:alert(1)")
  end

  def test_module_assignments_get_submission_status
    paths = []
    fetch = lambda do |path|
      paths << path
      if path.include?("/students/submissions")
        [
          { "assignment_id" => 500, "workflow_state" => "submitted", "submitted_at" => "2026-10-20T12:00:00Z", "body" => "secret" },
          { "assignment_id" => 501, "workflow_state" => "unsubmitted", "missing" => true }
        ]
      else
        [{ "id" => 10, "position" => 1, "items_count" => 3, "items" => [
          { "id" => 1, "position" => 1, "type" => "Assignment", "content_id" => 500 },
          { "id" => 2, "position" => 2, "type" => "Assignment", "content_id" => 501 },
          { "id" => 3, "position" => 3, "type" => "Page", "content_id" => 500 }
        ] }]
      end
    end

    result = with_replaced_method(self, :canvas_get_all, fetch) do
      with_replaced_method(self, :canvas_get, ->(_path) { { "description" => "" } }) do
        fetch_module_catalog([{ "id" => 1 }])
      end
    end
    items = result["modules"]["1"].first["items"]
    submission_path = paths.find { |path| path.include?("/students/submissions") }
    assert_includes submission_path, "student_ids%5B%5D=self"
    assert_includes submission_path, "assignment_ids%5B%5D=500&assignment_ids%5B%5D=501"
    assert_equal ["Turned in", "done"], module_item_status(items[0])
    refute items[0]["submission"].key?("body")
    assert_equal ["Missing", "missing"], module_item_status(items[1])
    assert_nil items[2]["submission"]
  end

  def test_module_quizzes_get_submission_status_through_their_assignment
    paths = []
    fetch = lambda do |path|
      paths << path
      if path.include?("/students/submissions")
        [{ "assignment_id" => 700, "workflow_state" => "graded", "submitted_at" => "2026-10-20T12:00:00Z" }]
      else
        [{ "id" => 10, "items_count" => 2, "items" => [
          { "id" => 1, "position" => 1, "type" => "Quiz", "content_id" => 70 },
          { "id" => 2, "position" => 2, "type" => "Quiz", "content_id" => 71 }
        ] }]
      end
    end
    quiz_paths = []
    fetch_quiz = lambda do |path|
      quiz_paths << path
      path.end_with?("/quizzes/70") ? { "id" => 70, "assignment_id" => 700 } : { "id" => 71, "assignment_id" => nil }
    end

    result = with_replaced_method(self, :canvas_get_all, fetch) do
      with_replaced_method(self, :canvas_get, fetch_quiz) { fetch_module_catalog([{ "id" => 1 }]) }
    end
    graded, practice = result["modules"]["1"].first["items"]
    assert_equal ["/api/v1/courses/1/quizzes/70", "/api/v1/courses/1/quizzes/71"], quiz_paths
    assert_includes paths.find { |path| path.include?("/students/submissions") }, "assignment_ids%5B%5D=700"
    assert_equal ["Graded", "done"], module_item_status(graded)
    assert_nil practice["submission"]
    assert_equal "2 items · 1 of 1 assignments done", module_group_summary([graded, practice])
  end

  def test_known_quiz_links_are_reused_from_previous_refresh
    fetch = lambda do |path|
      next [{ "assignment_id" => 700, "workflow_state" => "graded" }] if path.include?("/students/submissions")

      [{ "id" => 10, "items_count" => 3, "items" => [
        { "id" => 1, "position" => 1, "type" => "Quiz", "content_id" => 70 },
        { "id" => 2, "position" => 2, "type" => "Quiz", "content_id" => 71 },
        { "id" => 3, "position" => 3, "type" => "Quiz", "content_id" => 72 }
      ] }]
    end
    previous = { "modules" => { "1" => [{ "items" => [
      { "type" => "Quiz", "content_id" => 70, "assignment_id" => 700 },
      { "type" => "Quiz", "content_id" => 71, "assignment_id" => nil },
      { "type" => "Quiz", "content_id" => 72 }
    ] }] } }
    quiz_paths = []
    fetch_quiz = ->(path) { quiz_paths << path; { "id" => 72, "assignment_id" => 720 } }

    result = with_replaced_method(self, :canvas_get_all, fetch) do
      with_replaced_method(self, :canvas_get, fetch_quiz) do
        fetch_module_catalog([{ "id" => 1 }], previous: previous)
      end
    end
    graded, practice, new_quiz = result["modules"]["1"].first["items"]
    # Only quiz 72 needs its assignment looked up; 70 and 71 are then read for
    # their saved instructions, and 72's record is reused for that.
    assert_equal %w[72 70 71].map { |id| "/api/v1/courses/1/quizzes/#{id}" }, quiz_paths
    assert_equal ["Graded", "done"], module_item_status(graded)
    assert practice.key?("assignment_id")
    assert_nil practice["assignment_id"]
    assert_equal 720, new_quiz["assignment_id"]
  end

  def test_quiz_lookup_failure_keeps_assignment_status
    fetch = lambda do |path|
      next [{ "assignment_id" => 500, "workflow_state" => "graded" }] if path.include?("/students/submissions")

      [{ "id" => 10, "items_count" => 2, "items" => [
        { "id" => 1, "type" => "Assignment", "content_id" => 500 },
        { "id" => 2, "type" => "Quiz", "content_id" => 70 }
      ] }]
    end
    result = nil
    output, = capture_io do
      result = with_replaced_method(self, :canvas_get_all, fetch) do
        with_replaced_method(self, :canvas_get, ->(_path) { raise "404 Not Found" }) do
          fetch_module_catalog([{ "id" => 1 }])
        end
      end
    end
    assignment, quiz = result["modules"]["1"].first["items"]
    assert_includes output, "Unable to fetch module quiz 70"
    refute quiz.key?("assignment_id")
    assert_equal ["Graded", "done"], module_item_status(assignment)
    assert_nil quiz["submission"]
  end

  def test_submission_failure_keeps_modules
    fetch = lambda do |path|
      raise "403 Forbidden" if path.include?("/students/submissions")

      [{ "id" => 10, "items_count" => 1, "items" => [
        { "id" => 1, "type" => "Assignment", "content_id" => 500 }
      ] }]
    end
    result = nil
    output, = capture_io do
      result = with_replaced_method(self, :canvas_get_all, fetch) do
        with_replaced_method(self, :canvas_get, ->(_path) { { "description" => "" } }) do
          fetch_module_catalog([{ "id" => 1 }])
        end
      end
    end
    assert_includes output, "403 Forbidden"
    assert_empty result["modules_errors"]
    assert_nil module_item_status(result["modules"]["1"].first["items"].first)
  end

  def test_module_item_status_labels
    status = ->(submission) { module_item_status("submission" => submission) }
    assert_nil module_item_status({})
    assert_nil status.call("workflow_state" => "unsubmitted")
    assert_equal ["Excused", "done"], status.call("excused" => true, "missing" => true)
    assert_equal ["Graded", "done"], status.call("workflow_state" => "graded")
    assert_equal ["Turned in late", "late"],
      status.call("workflow_state" => "submitted", "submitted_at" => "x", "late" => true)
    assert module_item_done?("submission" => { "workflow_state" => "submitted", "submitted_at" => "x", "late" => true })
    assert_nil module_item_lock_status({
      "content_details" => { "locked_for_user" => true, "lock_at" => "2020-01-01T00:00:00Z" },
      "submission" => { "submitted_at" => "x", "late" => true }
    })
    assert_equal ["Graded", "done"],
      status.call("workflow_state" => "graded", "missing" => true, "submitted_at" => "x")
  end

  def test_module_item_lock_status_explains_locks
    now = Time.iso8601("2026-10-22T12:00:00Z")
    locked = ->(details, submission = nil) do
      item = { "content_details" => { "locked_for_user" => true }.merge(details) }
      item["submission"] = submission if submission
      module_item_lock_status(item, now: now)
    end

    assert_nil module_item_lock_status({ "content_details" => { "lock_at" => "2026-10-01T00:00:00Z" } }, now: now)
    assert_nil locked.call({ "lock_at" => "2026-10-01T00:00:00Z" }, { "workflow_state" => "graded" })
    label, kind = locked.call("lock_at" => "2026-10-01T19:00:00Z")
    assert_equal "closed", kind
    assert_match(/\AClosed Oct \d+\z/, label)
    label, kind = locked.call("unlock_at" => "2026-10-30T19:00:00Z")
    assert_equal "upcoming", kind
    assert_match(/\AOpens /, label)
    assert_equal ["Locked: Finish <Unit 1> first.", "locked"],
      locked.call("lock_explanation" => "<p>Finish &lt;Unit 1&gt; first.</p>")
    assert_equal ["Locked in Canvas", "locked"], locked.call({})
  end

  def test_module_item_groups_split_on_text_headers
    items = [
      { "id" => 1, "type" => "Page" },
      { "id" => 2, "type" => "SubHeader", "title" => "Monday" },
      { "id" => 3, "type" => "Page" },
      { "id" => 4, "type" => "Assignment", "submission" => { "workflow_state" => "graded" } },
      { "id" => 5, "type" => "Assignment", "submission" => { "workflow_state" => "unsubmitted" } },
      { "id" => 6, "type" => "SubHeader", "title" => "Empty" }
    ]
    groups = module_item_groups(items)
    assert_equal [nil, 2, nil], groups.map { |group| group["heading"]&.fetch("id") }
    assert_equal 6, groups.last.dig("note", "id"), "a header with nothing under it is a note"
    assert_equal [[1], [3, 4, 5]], groups.first(2).map { |group| group["items"].map { |item| item["id"] } }
    assert_equal [2], module_item_groups(items.drop(1)).filter_map { |group| group.dig("heading", "id") }
    assert_equal "3 items · 1 of 2 assignments done", module_group_summary(groups[1]["items"])
    assert_equal "1 item", module_group_summary(groups[0]["items"])
  end

  def test_module_item_groups_treat_week_announcements_as_notes
    item = ->(id, title, indent = 0, type = "Page") { { "id" => id, "title" => title, "indent" => indent, "type" => type } }
    week = [
      item.call(1, "‼️ Modified Days ‼️", 0, "SubHeader"),
      item.call(2, "☀️ Picnic on Friday ☀️", 0, "SubHeader"),
      item.call(3, "Monday"),
      item.call(4, "Homework: Page 12", 3, "Assignment"),
      item.call(5, "Tuesday"),
      item.call(6, "Homework: Page 14", 3, "Assignment")
    ]
    groups = module_item_groups(week)
    assert_equal [1, 2], groups.filter_map { |group| group.dig("note", "id") }
    assert_equal [[3, 4, 5, 6]], groups.select { |group| group.key?("items") }.map { |group| group["items"].map { |i| i["id"] } }
    assert groups.none? { |group| group["heading"] }

    days = [
      item.call(1, "Monday", 0, "SubHeader"),
      item.call(2, "Slides", 0, "ExternalUrl"),
      item.call(3, "Handout", 1, "ExternalUrl"),
      item.call(4, "Tuesday", 0, "SubHeader"),
      item.call(5, "Lab", 1, "Assignment"),
      item.call(6, "Loose page")
    ]
    groups = module_item_groups(days)
    assert_equal [[1, [2, 3]], [4, [5]]], groups.select { |group| group["heading"] }.map { |group| [group["heading"]["id"], group["items"].map { |i| i["id"] }] }
    assert_equal [6], groups.last["items"].map { |i| i["id"] }, "an indented run under a header ends at the header's level"
  end

  def test_module_item_score_shows_points_for_graded_work
    graded = ->(score, possible = 10.0) do
      { "type" => "Assignment", "content_id" => 5,
        "content_details" => { "points_possible" => possible },
        "submission" => { "workflow_state" => "graded", "score" => score } }
    end
    assert_equal "8/10", module_item_score(graded.call(8.0))
    assert_equal "9.5/10", module_item_score(graded.call(9.5))
    assert_equal "7", module_item_score(graded.call(7.0, nil))
    assert_nil module_item_score(graded.call(nil))
    assert_nil module_item_score({ "submission" => { "workflow_state" => "submitted", "submitted_at" => "x", "score" => 4 } })
    assert_nil module_item_score({ "submission" => { "excused" => true, "score" => 4 } })

    overrides = { "canvas" => { "5" => { "score" => 10, "points_possible" => 12 } } }
    assert_equal "10/12", module_item_score(graded.call(8.0), overrides)
    assert_equal "8/10", module_item_score(graded.call(8.0), { "canvas" => { "5" => { "hidden" => true } } })
  end

  def test_module_item_due_tomorrow_ignores_finished_work
    today = Date.new(2026, 10, 22)
    tomorrow = Time.local(2026, 10, 23, 23, 59)
    assert module_item_due_tomorrow?({}, tomorrow, today: today)
    refute module_item_due_tomorrow?({}, Time.local(2026, 10, 22, 23, 59), today: today)
  end

  def test_module_due_tomorrow_events_skip_listed_and_finished_work
    due = Time.local(2026, 10, 23, 23, 59).utc.iso8601
    item = ->(id, title, type: "Assignment", content_id: id, submission: nil) do
      { "id" => id * 10, "type" => type, "title" => title, "content_id" => content_id,
        "content_details" => { "due_at" => due }, "submission" => submission }
    end
    data = {
      "courses" => [{ "id" => 7 }, { "id" => "manual-1" }],
      "modules" => {
        "7" => [
          { "id" => 1, "items" => [
            item.call(1, "Seasons Lesson"),
            item.call(2, "Listed By Id"),
            item.call(3, "listed by name", type: "Quiz", content_id: 99),
            item.call(4, "Already Graded", submission: { "workflow_state" => "graded" })
          ] },
          { "id" => 2, "items" => [item.call(1, "Seasons Lesson")] }
        ],
        "manual-1" => [{ "id" => 3, "items" => [item.call(5, "Manual")] }]
      }
    }
    known = [
      { "course_id" => 7, "assignment_id" => 2, "name" => "Different Name" },
      { "course_id" => 7, "assignment_id" => 50, "name" => "Listed by Name" }
    ]

    events = module_due_tomorrow_events(data, known_events: known, today: Date.new(2026, 10, 22))

    assert_equal ["Seasons Lesson"], events.map { |event| event["name"] }
    event = events.first
    assert_equal "7", assignment_course_id(event)
    assert_equal 1, assignment_id(event)
    assert_equal due, event["due_at"]
    assert_equal "#{BASE_URL}/courses/7/modules/items/10", assignment_url(event)
  end

  def test_current_week_module_skips_resources_modules
    modules = [
      { "id" => 1, "name" => "Class Resources" },
      { "id" => 2, "name" => "Week 11" },
      { "id" => 3, "name" => "Week 10" }
    ]
    assert_equal 2, current_week_module(modules)["id"]
    assert_equal 2, current_week_module(modules.drop(1))["id"]
    assert_nil current_week_module([{ "name" => "RESOURCES" }])
    assert_nil current_week_module(nil)
  end

  def test_this_week_links_prefers_work_then_falls_back_to_pages
    mod = { "items" => [
      { "type" => "SubHeader" }, { "id" => 1, "type" => "Page" },
      { "id" => 2, "type" => "Assignment" }, { "id" => 3, "type" => "Quiz" },
      { "id" => 4, "type" => "Discussion" }
    ] }
    links, kind = this_week_links(mod)
    assert_equal [[2, 3, 4], :work], [links.map { |item| item["id"] }, kind]
    links, kind = this_week_links("items" => mod["items"].first(2))
    assert_equal [[1], :pages], [links.map { |item| item["id"] }, kind]
    assert_equal [[], :pages], this_week_links("items" => [])
  end

  def test_module_announcements_returns_header_notes
    mod = { "items" => [
      { "id" => 1, "type" => "SubHeader", "title" => "‼️ Test on Friday ‼️" },
      { "id" => 2, "type" => "Page", "title" => "Monday" },
      { "id" => 3, "type" => "Page", "title" => "Tuesday" },
      { "id" => 4, "type" => "SubHeader", "title" => "Lab", "indent" => 0 },
      { "id" => 5, "type" => "Assignment", "title" => "Lab sheet", "indent" => 1 }
    ] }
    assert_equal [1], module_announcements(mod).map { |item| item["id"] }
    assert_empty module_announcements(nil)
  end

  def test_module_html_content_keeps_text_and_safe_links_only
    html = <<~HTML
      <h2>Monday &amp; Tuesday</h2><p>Read pages<br>227&nbsp;&ndash;&nbsp;228.</p>
      <script>alert("x")</script><style>p{}</style>
      <ul><li>Bring <strong>notes</strong></li><li>Upload a <a href="/courses/1/files/9?wrap=1">picture</a></li></ul>
      <p><img src="/x.png" alt="Diagram"> <a href="javascript:alert(1)">bad</a> <a href="#top">top</a>
      <a href='https://docs.google.com/doc'>https://docs.google.com/doc</a></p>
      <iframe src="https://www.youtube.com/embed/abc"></iframe><p onclick="x()">Done</p>
    HTML
    content = module_html_content(html)

    assert_equal <<~TEXT.strip, content["text"]
      ## Monday & Tuesday

      Read pages
      227 – 228.

      • Bring notes
      • Upload a picture

      [Image: Diagram] bad top https://docs.google.com/doc

      [Embedded content]

      Done
    TEXT
    assert_equal [
      { "text" => "Embedded content", "url" => "https://www.youtube.com/embed/abc" },
      { "text" => "picture", "url" => "https://temecula.instructure.com/courses/1/files/9?wrap=1" },
      { "text" => "https://docs.google.com/doc", "url" => "https://docs.google.com/doc" }
    ], content["links"]
    assert_equal({ "text" => "", "links" => [] }, module_html_content(nil))
  end

  def test_module_html_content_labels_one_row_day_plan_tables
    html = <<~HTML
      <table border="1"><tbody>
      <tr><td>In Class Agenda</td><td>Homework</td><td>If you were absent</td></tr>
      <tr><td><p>1. Silent reading</p><p>2. Annotations</p></td><td><p>Read for 20 minutes&nbsp;</p><p>&nbsp;</p></td><td>&nbsp;</td></tr>
      </tbody></table>
      <table><tr><td>Name</td><td>A really long first cell that is clearly not a column heading at all, honestly</td></tr><tr><td>x</td></tr></table>
    HTML
    assert_equal <<~TEXT.strip, module_html_content(html)["text"]
      ## In Class Agenda

      1. Silent reading

      2. Annotations

      ## Homework

      Read for 20 minutes

      Name

      A really long first cell that is clearly not a column heading at all, honestly

      x
    TEXT
  end

  def test_this_week_item_content_is_saved_and_reused_until_stale
    now = Time.parse("2026-10-22T12:00:00Z")
    modules = lambda do
      [
        { "id" => 9, "position" => 1, "name" => "Class Resources", "items" => [
          { "id" => 90, "type" => "Page", "page_url" => "syllabus" }
        ] },
        { "id" => 10, "position" => 2, "name" => "Week 9", "items" => [
          { "id" => 1, "type" => "Page", "page_url" => "monday" },
          { "id" => 2, "type" => "Assignment", "content_id" => 500 },
          { "id" => 3, "type" => "Discussion", "content_id" => 600 },
          { "id" => 4, "type" => "ExternalUrl", "external_url" => "https://example.com" },
          { "id" => 5, "type" => "Page", "page_url" => "later", "content_details" => { "locked_for_user" => true } }
        ] }
      ]
    end
    records = {
      "/api/v1/courses/1/pages/monday" => { "body" => "<p>Read <b>pages</b></p>", "updated_at" => "2026-10-21T08:00:00Z" },
      "/api/v1/courses/1/assignments/500" => { "description" => "<p>Upload it</p>" },
      "/api/v1/courses/1/discussion_topics/600" => { "message" => "<p>Reply twice</p>" }
    }
    paths = []
    get = ->(path) { paths << path; records.fetch(path) }

    week = modules.call
    with_replaced_method(self, :canvas_get, get) { attach_module_item_content("1", week, now: now) }
    page, assignment, discussion, link, locked = week[1]["items"]
    assert_equal records.keys, paths
    assert_equal({ "text" => "Read pages", "links" => [], "updated_at" => "2026-10-21T08:00:00Z",
                   "fetched_at" => now.iso8601 }, page["content"])
    assert_equal "Upload it", assignment.dig("content", "text")
    assert_equal "Reply twice", discussion.dig("content", "text")
    assert_nil link["content"]
    assert_nil locked["content"]
    assert_nil week[0]["items"][0]["content"]

    known = known_module_item_content(week)
    paths.clear
    fresh = modules.call
    with_replaced_method(self, :canvas_get, get) { attach_module_item_content("1", fresh, known: known, now: now + 59 * 60) }
    assert_empty paths
    assert_equal "Read pages", fresh[1]["items"][0].dig("content", "text")

    stale = modules.call
    capture_io do
      with_replaced_method(self, :canvas_get, ->(path) { paths << path; raise "500 Server Error" }) do
        attach_module_item_content("1", stale, known: known, now: now + 61 * 60)
      end
    end
    assert_equal 3, paths.length
    assert_equal "Read pages", stale[1]["items"][0].dig("content", "text"), "failed refresh keeps last copy"
  end

  def test_module_item_content_html_escapes_saved_text
    item = { "id" => 7, "type" => "Page", "content" => {
      "text" => "## Home & work\n\nLine <b>one</b>\nLine two\n\n• Next",
      "links" => [{ "text" => "<Doc>", "url" => "https://example.com/?a=1&b=2" }],
      "fetched_at" => "2026-10-22T12:00:00Z"
    } }
    html = module_item_content_html(1, item)
    assert_includes html, %(<p class="module-content-heading">Home &amp; work</p>)
    assert_includes html, "<p>Line &lt;b&gt;one&lt;/b&gt;<br>Line two</p><p>• Next</p>"
    assert_includes html, %(<a href="https://example.com/?a=1&amp;b=2" target="_blank" rel="noopener noreferrer">&lt;Doc&gt;</a>)
    assert_includes html, "/courses/1/modules/items/7"
    assert_includes html, "Saved "
    assert_includes module_item_content_html(1, item.merge("content" => { "text" => "" })), "No written instructions saved"
  end
end
