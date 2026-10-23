require_relative "test_helper"

class AssignmentDetailsTest < Minitest::Test
  def setup
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def teardown
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
  end

  def canvas_assignment(id, description, updated_at: "2026-10-01T00:00:00Z", **extra)
    {
      "id" => id, "course_id" => 1, "name" => "Assignment #{id}", "due_at" => "2026-10-23T05:59:00Z",
      "description" => description, "updated_at" => updated_at, "points_possible" => 10,
      "rubric" => [{ "big" => "unused" }],
      "submission" => { "workflow_state" => "unsubmitted", "score" => nil, "body" => "her essay" }
    }.merge(extra)
  end

  def test_catalog_saves_readable_instructions_without_extra_canvas_fields
    paths = []
    fetch = lambda do |path|
      paths << path
      [canvas_assignment(5, "<p>Read <b>pages 4-9</b></p><script>alert(1)</script>")]
    end

    result = with_replaced_method(self, :canvas_get_all, fetch) do
      fetch_assignment_catalog([{ "id" => 1 }], now: Time.utc(2026, 10, 22))
    end

    assert_equal ["/api/v1/courses/1/assignments?include%5B%5D=submission&order_by=due_at&per_page=100"], paths
    record = result["assignments"]["1"].first
    assert_equal "Assignment 5", record["name"]
    refute record.key?("rubric")
    refute record.key?("description")
    refute record["submission"].key?("body")
    assert_includes record["content"]["text"], "Read pages 4-9"
    refute_includes record["content"]["text"], "alert"
    assert_equal "2026-10-22T00:00:00Z", record["content"]["fetched_at"]
    assert_empty result["assignments_errors"]
  end

  def test_unchanged_instructions_are_reused_and_failures_keep_the_previous_copy
    previous = { "assignments" => { "1" => [{ "id" => 5, "updated_at" => "2026-10-01T00:00:00Z",
                                              "content" => { "text" => "Saved copy" } }] } }
    result = with_replaced_method(self, :canvas_get_all, ->(_) { [canvas_assignment(5, "<p>New text</p>")] }) do
      fetch_assignment_catalog([{ "id" => 1 }], previous: previous)
    end
    assert_equal "Saved copy", result["assignments"]["1"].first["content"]["text"]

    result = with_replaced_method(self, :canvas_get_all, ->(_) { [canvas_assignment(5, "<p>New text</p>", updated_at: "2026-10-02T00:00:00Z")] }) do
      fetch_assignment_catalog([{ "id" => 1 }], previous: previous)
    end
    assert_equal "New text", result["assignments"]["1"].first["content"]["text"]

    result = with_replaced_method(self, :canvas_get_all, ->(_) { raise "Canvas down" }) do
      fetch_assignment_catalog([{ "id" => 1 }], previous: previous)
    end
    assert_equal previous["assignments"]["1"], result["assignments"]["1"]
    assert_equal "Could not refresh assignments.", result["assignments_errors"]["1"]
  end

  def test_hidden_courses_are_not_requested
    save_hidden_course_ids(["1"])
    with_replaced_method(self, :canvas_get_all, ->(_) { flunk "Hidden course requested" }) do
      assert_empty fetch_assignment_catalog([{ "id" => 1 }])["assignments"]
    end
  end

  def test_saved_content_prefers_catalog_then_event_description
    data = { "assignments" => { "1" => [{ "id" => 5, "content" => { "text" => "From catalog" } }] } }
    assert_equal "From catalog", assignment_saved_content(data, 1, 5)["text"]

    event = { "assignment" => { "id" => 6, "description" => "<p>From event</p>" } }
    assert_equal "From event", assignment_saved_content(data, 1, 6, event)["text"]
    assert_equal "From module", assignment_saved_content(data, 1, 7, { "content" => { "text" => "From module" } })["text"]
    assert_nil assignment_saved_content(data, 1, 8, { "name" => "No description" })

    quiz = { "type" => "Quiz", "assignment_id" => 5 }
    assert_equal "From catalog", module_item_saved_content(data, 1, quiz)["text"]
    assert_equal "Own copy", module_item_saved_content(data, 1, quiz.merge("content" => { "text" => "Own copy" }))["text"]
  end

  def test_open_for_ai_skips_graded_locked_and_excused_work
    assert assignment_open_for_ai?({ "submission" => { "workflow_state" => "submitted" } })
    assert assignment_open_for_ai?({})
    refute assignment_open_for_ai?({ "locked_for_user" => true })
    refute assignment_open_for_ai?({ "submission" => { "workflow_state" => "graded" } })
    refute assignment_open_for_ai?({ "submission" => { "score" => 0 } })
    refute assignment_open_for_ai?({ "submission" => { "excused" => true } })
  end

  def test_assignment_title_opens_instructions_in_place_and_escapes_teacher_text
    html = assignment_title_html("Essay <draft>", "https://canvas.example/a/5", { "text" => "Write <b>500</b> words" })
    assert_includes html, '<details class="module-item-details assignment-details">'
    assert_includes html, "Essay &lt;draft&gt;"
    assert_includes html, "Write &lt;b&gt;500&lt;/b&gt; words"
    assert_includes html, 'href="https://canvas.example/a/5"'

    link = assignment_title_html("Essay", "https://canvas.example/a/5", nil)
    assert_includes link, '<a href="https://canvas.example/a/5" target="_blank"'
    refute_includes link, "<details"
  end
end
