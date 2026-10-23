require_relative "test_helper"

class AppTest < Minitest::Test
  Request = Struct.new(:query)

  def setup
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    $school_calendar_cache = nil
  end

  def test_todo_form_fields_normalize_valid_input
    request = Request.new({
      "title" => "  Read chapter  ",
      "details" => "Pages 1-10",
      "todo_date" => "2026-09-28",
      "course_id" => "12"
    })
    data = { "courses" => [{ "id" => 12 }] }

    assert_equal(
      {
        "title" => "Read chapter",
        "details" => "Pages 1-10",
        "todo_date" => "2026-09-28",
        "course_id" => "12"
      },
      todo_form_fields(request, data)
    )
  end

  def test_todo_form_fields_validate_input
    data = { "courses" => [{ "id" => 12 }] }

    assert_raises(ArgumentError) do
      todo_form_fields(Request.new({ "title" => "", "todo_date" => "2026-09-28" }), data)
    end
    assert_raises(ArgumentError) do
      todo_form_fields(Request.new({ "title" => "Read", "todo_date" => "bad" }), data)
    end
    assert_raises(ArgumentError) do
      todo_form_fields(
        Request.new({ "title" => "Read", "todo_date" => "2026-09-28", "course_id" => "99" }),
        data
      )
    end
  end

  def test_class_name_mapping_fields_remove_blanks
    request = Request.new({ "course_1" => " Math ", "course_2" => " " })
    data = { "courses" => [{ "id" => 1 }, { "id" => 2 }] }

    assert_equal({ "1" => "Math" }, class_name_mapping_fields(request, data))
  end

  def test_class_name_mapping_fields_reject_long_names
    request = Request.new({ "course_1" => "a" * 81 })
    data = { "courses" => [{ "id" => 1 }] }

    assert_raises(ArgumentError) { class_name_mapping_fields(request, data) }
  end

  def test_grade_override_fields_normalize_canvas_values_and_remove_blanks
    request = Request.new({
      "canvas_10_score" => " 9.25 ",
      "canvas_10_points" => "",
      "canvas_11_score" => "",
      "canvas_11_points" => "",
      "new_name" => ""
    })
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [
        { "assignment_id" => 10 },
        { "assignment_id" => 11 }
      ]
    }

    overrides = grade_override_fields(
      request,
      data,
      { "canvas" => {}, "custom" => {} }
    )

    assert_equal 9.25, overrides.dig("canvas", "10", "score")
    assert_nil overrides.dig("canvas", "10", "points_possible")
    assert_nil overrides.dig("canvas", "10", "canvas_score")
    assert_nil overrides.dig("canvas", "10", "canvas_points_possible")
    assert overrides.dig("canvas", "10", "updated_at")
    refute overrides["canvas"].key?("11")
  end

  def test_grade_override_fields_validate_values
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [{ "assignment_id" => 10 }]
    }

    assert_raises(ArgumentError) do
      grade_override_fields(
        Request.new({
          "canvas_10_score" => "invalid",
          "canvas_10_points" => "",
          "new_name" => ""
        }),
        data,
        { "canvas" => {}, "custom" => {} }
      )
    end
  end

  def test_dashboard_template_renders_and_escapes_canvas_content
    data = {
      "profile" => { "short_name" => "<Avery> Student" },
      "courses" => [{ "id" => 1, "name" => "Math & Logic" }],
      "course_names" => { "1" => "Math & Logic" },
      "missing" => [
        { "id" => 10, "course_id" => 1, "name" => "Quiz <One>", "due_at" => Time.now.iso8601 }
      ],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {}
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = template.result(binding)

    assert_includes html, "&lt;Avery&gt;"
    assert_includes html, "Quiz &lt;One&gt;"
    assert_includes html, "No graded assignments"
    assert_includes html, "What to Do Next"
    assert_includes html, "next-action-urgency is-missing"
    assert_includes html, 'class="dashboard-nav"'
    assert_includes html, "<strong>EmberGuide</strong>"
    assert_includes html, 'class="dashboard-nav-toggle"'
    assert_includes html, 'aria-controls="dashboard-nav-links"'
    assert_match(
      /class="is-active" href="\/">\s*Dashboard\s*<\/a>/,
      html
    )
    assert_includes html, 'class="dashboard-section-title"'
    refute_match(/<h2[^>]*>\s*[🗓️⚠️✅📅📊]/, html)
    refute_includes html, "0 assignments"
    refute_includes html, "0 due tomorrow"
    refute_includes html, "Quiz <One>"
  end

  def test_dashboard_assignments_open_their_saved_instructions
    due = (Time.now + 3600).iso8601
    data = {
      "profile" => { "short_name" => "Emberlynn" },
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "missing" => [{ "id" => 10, "course_id" => 1, "name" => "Fractions <quiz>", "due_at" => due,
                      "html_url" => "https://canvas.example/courses/1/assignments/10" }],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {},
      "assignments" => { "1" => [{ "id" => 10, "content" => { "text" => "Study <b>unit 3</b> before the quiz" } }] }
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = with_replaced_method(self, :school_calendar_events, ->(**_kwargs) { [] }) do
      template.result(binding)
    end

    assert_includes html, '<details class="next-action-card next-action-details">'
    assert_includes html, '<details class="module-item-details assignment-details">'
    assert_includes html, "Study &lt;b&gt;unit 3&lt;/b&gt; before the quiz"
    assert_includes html, 'href="https://canvas.example/courses/1/assignments/10"'
    refute_includes html, "<b>unit 3</b>"
  end

  def test_next_actions_show_all_caught_up_instead_of_zero_counts
    data = {
      "profile" => { "short_name" => "Emberlynn" },
      "courses" => [],
      "course_names" => {},
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "grades" => [],
      "submissions" => {}
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = with_replaced_method(self, :school_calendar_events, ->(**_kwargs) { [] }) do
      template.result(binding)
    end

    assert_includes html, "You're all caught up."
    refute_includes html, "0 assignments"
    refute_includes html, "0 due tomorrow"
    refute_includes html, "No missing work"
  end

  def test_grade_editor_sorts_canvas_assignments_newest_first
    data = {
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [
        {
          "assignment_id" => 10,
          "score" => 8,
          "graded_at" => "2026-09-01T12:00:00Z",
          "assignment" => {
            "id" => 10,
            "course_id" => 1,
            "name" => "Older Quiz",
            "points_possible" => 10
          }
        },
        {
          "assignment_id" => 11,
          "score" => 9,
          "graded_at" => "2026-10-01T12:00:00Z",
          "assignment" => {
            "id" => 11,
            "course_id" => 1,
            "name" => "Recent Quiz",
            "points_possible" => 10
          }
        }
      ]
    }
    overrides = { "canvas" => {}, "custom" => {} }
    mappings = {}

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "grades.erb")))
    html = template.result(binding)

    assert_operator html.index("Recent Quiz"), :<, html.index("Older Quiz")
  end

  def test_dashboard_renders_grade_snapshot_with_whole_percentage_and_letter
    data = {
      "profile" => { "short_name" => "Emberlynn" },
      "courses" => [{ "id" => 1, "name" => "6th Grade Science" }],
      "course_names" => { "1" => "6th Grade Science" },
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {},
      "grades" => [{
        "assignment_id" => 10,
        "score" => 10,
        "assignment" => {
          "id" => 10,
          "course_id" => 1,
          "name" => "Lab",
          "points_possible" => 10
        }
      }]
    }

    template = ERB.new(File.read(File.join(APP_ROOT, "views", "dashboard.erb")))
    html = template.result(binding)

    assert_includes html, "Overall grade snapshot"
    assert_includes html, "grade-snapshot-course"
    assert_includes html, "6th Grade Science"
    assert_includes html, "grade-snapshot-item grade-a"
    assert_includes html, "<strong>100%</strong>"
    assert_includes html, "grade-snapshot-letter\">A"
    assert_includes html, 'href="#grade-course-1"'
    assert_includes html, 'id="grade-course-1"'
  end
end