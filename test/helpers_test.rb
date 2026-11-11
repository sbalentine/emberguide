require_relative "test_helper"

class HelpersTest < Minitest::Test
  def test_number_formatting
    assert_equal 25.0, percentage(1, 4)
    assert_nil percentage(nil, 4)
    assert_nil percentage(1, 0)
    assert_equal "-", format_number(nil)
    assert_equal 5, format_number(5.0)
    assert_equal 5.3, format_number(5.34)
    assert_equal "A", letter_grade(90)
    assert_equal "B", letter_grade(89.9)
    assert_equal "F", letter_grade(0)
    assert_nil letter_grade(nil)
    assert_equal "🧪", course_symbol("6th Grade Science")
    assert_equal "➗", course_symbol("Math 6A")
    assert_equal "🎭", course_symbol("Explore Drama")
    assert_equal "🌎", course_symbol("S1 G6 SS")
  end

  def test_grade_trend_points_build_cumulative_percentages_in_date_order
    points = grade_trend_points([
      {
        "score" => 18,
        "graded_at" => "2026-10-10T12:00:00Z",
        "assignment" => {
          "name" => "Project",
          "points_possible" => 20
        }
      },
      {
        "score" => 8,
        "graded_at" => "2026-10-01T12:00:00Z",
        "assignment" => {
          "name" => "Quiz",
          "points_possible" => 10
        }
      }
    ])

    assert_equal ["Quiz", "Project"], points.map { |point| point["assignment"] }
    assert_equal [80.0, 86.7], points.map { |point| point["y"] }
    assert_equal 26.0, points.last["earned"]
    assert_equal 30.0, points.last["possible"]
  end

  def test_json_for_html_script_escapes_script_terminators
    json = json_for_html_script("label" => "</script><script>alert(1)</script>")

    refute_includes json, "<"
    refute_includes json, ">"
    assert_equal(
      { "label" => "</script><script>alert(1)</script>" },
      JSON.parse(json)
    )
  end

  def test_grade_trends_include_extra_credit_before_and_after_point_bearing_work
    submissions = [
      { "score" => 2, "graded_at" => "2026-10-01T12:00:00Z",
        "assignment" => { "name" => "Early bonus", "points_possible" => 0 } },
      { "score" => 8, "graded_at" => "2026-10-02T12:00:00Z",
        "assignment" => { "name" => "Quiz", "points_possible" => 10 } },
      { "score" => 1, "graded_at" => "2026-10-03T12:00:00Z",
        "assignment" => { "name" => "Late bonus", "points_possible" => 0 } }
    ]

    points = grade_trend_points(submissions)

    assert_equal ["Quiz", "Late bonus"], points.map { |point| point["assignment"] }
    assert_equal [100.0, 110.0], points.map { |point| point["y"] }
    assert_equal 11.0, points.last["earned"]
    assert_equal 10.0, points.last["possible"]
    assert_empty grade_trend_points([submissions.first])
  end

  def test_combined_grades_exclude_hidden_earned_and_possible_points
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [
        { "assignment_id" => 10, "score" => 0,
          "assignment" => { "id" => 10, "course_id" => 1, "points_possible" => 100 } },
        { "assignment_id" => 11, "score" => 8,
          "assignment" => { "id" => 11, "course_id" => 1, "points_possible" => 10 } }
      ]
    }
    overrides = {
      "canvas" => {
        "10" => { "hidden" => true, "score" => 50, "points_possible" => 50 },
        "11" => { "score" => 9 }
      },
      "custom" => {
        "manual" => {
          "course_id" => "1", "name" => "Manual Quiz",
          "score" => 10, "points_possible" => 10, "graded_at" => "2026-10-14"
        }
      }
    }
    original = deep_copy(data)

    grades = combined_grade_submissions(data, overrides)

    assert_equal [11, "custom-manual"], grades.map { |grade| grade["assignment_id"] }
    earned = grades.sum { |grade| grade["score"] }
    possible = grades.sum { |grade| grade.dig("assignment", "points_possible") }
    assert_equal 19, earned
    assert_equal 20, possible
    assert_equal 95, percentage(earned, possible)
    assert_equal original, data
  end

  def test_course_and_assignment_values_support_canvas_shapes
    data = { "course_names" => { "12" => "Science" } }
    nested = {
      "plannable" => {
        "title" => "Lab",
        "course_id" => 12,
        "todo_date" => "2026-09-28T17:00:00Z"
      },
      "assignment" => { "id" => 44, "html_url" => "/courses/12/assignments/44" }
    }

    assert_equal "Science", course_name(data, 12)
    assert_equal "Unknown Course", course_name(data, nil)
    assert_equal "Lab", assignment_name(nested)
    assert_equal 12, assignment_course_id(nested)
    assert_equal 44, assignment_id(nested)
    assert_equal "https://temecula.instructure.com/courses/12/assignments/44", assignment_url(nested)
    assert_equal Time.parse("2026-09-28T17:00:00Z"), assignment_due_time(nested)
  end

  def test_date_and_profile_labels
    now = Time.now

    assert_equal "Today", date_label(now)
    assert_equal "Tomorrow", date_label(now + 86_400)
    assert_equal "No due date", date_label(nil)
    assert_equal "Good morning", greeting_for(Time.local(2026, 1, 1, 9))
    assert_equal "Good afternoon", greeting_for(Time.local(2026, 1, 1, 14))
    assert_equal "Good evening", greeting_for(Time.local(2026, 1, 1, 20))
    assert_equal "Avery", profile_first_name("profile" => { "short_name" => "Avery Student" })
    assert_equal "there", profile_first_name({})
  end

  def test_submission_statuses
    assert_equal "not-submitted", submission_status(nil)[:css]
    assert_equal "missing-status", submission_status("missing" => true)[:css]
    assert_equal "late-status", submission_status("late" => true, "workflow_state" => "submitted")[:css]
    assert_equal "submitted", submission_status("workflow_state" => "submitted")[:css]

    graded = {
      "score" => 9,
      "assignment" => { "points_possible" => 10 }
    }
    assert_equal "Graded · 9/10", submission_status(graded)[:label]
    assert submission_complete?(graded)
    refute submission_complete?(nil)
  end

  def test_latest_nonempty_submission_comment
    submission = {
      "submission_comments" => [
        { "id" => 1, "comment" => "Earlier", "created_at" => "2026-09-20T10:00:00Z" },
        { "id" => 2, "comment" => "", "created_at" => "2026-09-22T10:00:00Z" },
        { "id" => 3, "comment" => "Latest", "created_at" => "2026-09-21T10:00:00Z" }
      ]
    }

    assert_equal 3, latest_submission_comment(submission)["id"]
    assert_nil latest_submission_comment(nil)
  end
end