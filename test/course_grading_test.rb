require_relative "test_helper"

class CourseGradingTest < Minitest::Test
  def setup
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
  end

  def settings
    {
      "mode" => "weighted",
      "categories" => {
        "quizzes" => { "name" => "Quizzes", "weight" => 35 },
        "classwork" => { "name" => "Classwork", "weight" => 40 },
        "homework" => { "name" => "Homework", "weight" => 0 }
      },
      "assignments" => {
        "canvas-1" => "quizzes", "canvas-2" => "classwork",
        "canvas-3" => "homework", "custom-bonus" => "classwork"
      }
    }
  end

  def grade(id, score, possible, day: 1)
    {
      "assignment_id" => id, "score" => score,
      "graded_at" => "2026-10-#{day.to_s.rjust(2, '0')}T12:00:00Z",
      "assignment" => { "id" => id, "course_id" => 1, "name" => "Work #{id}", "points_possible" => possible }
    }
  end

  def test_normalizes_active_category_weights_and_preserves_total_points_default
    grades = [grade(1, 83.5, 83), grade(2, 184.5, 218), grade(3, 5, 5)]
    assert_equal 92.1, course_grade_summary(grades, settings)["percentage"]
    assert_equal 89.2, course_grade_summary(grades, course_grading_settings({}, "1"))["percentage"]
    assert_equal 273.0, course_grade_summary(grades, settings)["earned"]
    assert_equal 306.0, course_grade_summary(grades, settings)["possible"]
    data = { "courses" => [{ "id" => 1 }], "grades" => grades }
    overrides = { "grading" => { "1" => settings } }
    assert_includes ai_grade_lines(data, { "1" => "History" }, overrides).first.first, "92% (A-)"
  end

  def test_empty_and_zero_weight_categories_do_not_dilute_active_categories
    assert_equal 80, course_grade_summary([grade(1, 8, 10)], settings)["percentage"]
    assert_equal 80, course_grade_summary([grade(1, 8, 10), grade(3, 0, 100)], settings)["percentage"]
    summary = course_grade_summary([grade(3, 5, 5)], settings)
    assert_nil summary["percentage"]
    assert_includes summary["error"], "No graded work"
  end

  def test_unassigned_grades_withhold_average_instead_of_silently_disappearing
    summary = course_grade_summary([grade(1, 8, 10), grade(99, 10, 10)], settings)
    assert_nil summary["percentage"]
    assert_includes summary["error"], "Category needed for 1 graded assignment"
    data = { "courses" => [{ "id" => 1 }], "grades" => [grade(99, 10, 10)] }
    assert_includes ai_grade_lines(data, { "1" => "History" }, { "grading" => { "1" => settings } }).first.first, "Category needed"
  end

  def test_extra_credit_is_added_within_its_category_including_early_bonus
    bonus = grade("custom-bonus", 5, 0)
    bonus["_custom_grade"] = true
    assert_equal 85, course_grade_summary([grade(2, 80, 100), bonus], settings)["percentage"]
    assert_nil course_grade_summary([bonus], settings)["percentage"]

    points = grade_trend_points([bonus, grade(2, 80, 100, day: 2)], grading: settings)
    assert_equal [85], points.map { |point| point["y"] }
    assert_equal "B", points.last["letter"]
  end

  def test_trends_recompute_active_category_totals_and_final_matches_summary
    grades = [grade(1, 8, 10), grade(2, 10, 10, day: 2), grade(3, 0, 100, day: 3)]
    points = grade_trend_points(grades, grading: settings)
    assert_equal [80, 90.7, 90.7], points.map { |point| point["y"] }
    assert_equal course_grade_summary(grades, settings)["percentage"], points.last["y"]
    assert_equal 120, points.last["possible"]
  end

  def test_grading_persists_through_score_override_reconciliation_and_backup_validation
    overrides = {
      "canvas" => { "1" => { "score" => 9, "canvas_score" => 8,
        "canvas_points_possible" => 10, "canvas_graded_at" => "2026-10-01T12:00:00Z" } },
      "custom" => {}, "grading" => { "1" => settings }
    }
    save_grade_overrides(overrides)
    assert_equal settings, load_grade_overrides.dig("grading", "1")
    assert_equal ["1"], reconcile_canvas_grade_overrides("grades" => [grade(1, 10, 10)])
    assert_empty load_grade_overrides["canvas"]
    assert_equal settings, load_grade_overrides.dig("grading", "1")
    validate_backup_json("grade_overrides.json", load_grade_overrides)
    invalid = deep_copy(overrides)
    invalid["grading"]["1"]["categories"]["quizzes"]["weight"] = -1
    assert_raises(BackupRestoreError) { validate_backup_json("grade_overrides.json", invalid) }
  end

  def test_invalid_saved_grading_settings_surface_an_error
    File.write(GRADE_OVERRIDES_FILE, JSON.generate("grading" => { "1" => {} }))
    assert_raises(CourseGradingError) { load_grade_overrides }
    invalid = settings
    invalid["categories"]["quizzes"]["weight"] = Float::NAN
    refute valid_course_grading?("1" => invalid)
    invalid = settings
    invalid["categories"]["classwork"]["name"] = "quizzes"
    refute valid_course_grading?("1" => invalid)
  end

  def test_settings_validate_input_and_keep_other_classes_unchanged
    existing = { "grading" => { "2" => settings } }
    query = {
      "grading_mode" => "weighted", "grading_category_quiz_name" => "Quizzes",
      "grading_category_quiz_weight" => "100", "canvas_1_category" => "quiz"
    }
    parsed = course_grading_fields(query, existing, "1", { "canvas-1" => "canvas_1_category" })
    assert_equal({ "canvas-1" => "quiz" }, parsed["assignments"])
    assert_equal settings, existing.dig("grading", "2")
    [
      { "grading_category_quiz_weight" => "-1" },
      { "grading_category_quiz_weight" => "NaN" },
      { "grading_category_quiz_weight" => "0" },
      { "grading_category_quiz_name" => "" },
      { "canvas_1_category" => "unknown" }
    ].each do |change|
      assert_raises(ArgumentError) do
        course_grading_fields(query.merge(change), existing, "1", { "canvas-1" => "canvas_1_category" })
      end
    end
    parsed["mode"] = "points"
    assert_equal 80, course_grade_summary([grade(1, 8, 10)], parsed)["percentage"]
  end

  def test_assignments_use_effective_scores_and_hidden_work_is_excluded_before_weighting
    data = {
      "courses" => [{ "id" => 1 }],
      "grades" => [grade(1, 0, 100), grade(2, 1, 10), grade(99, 0, 100)]
    }
    overrides = {
      "canvas" => { "1" => { "score" => 80 }, "99" => { "hidden" => true } },
      "custom" => { "bonus" => { "course_id" => "1", "score" => 1,
        "points_possible" => 0, "name" => "Bonus", "graded_at" => "2026-10-02" } }
    }
    combined = combined_grade_submissions(data, overrides)
    assert_equal 3, combined.length
    assert_equal 48, course_grade_summary(combined, settings)["percentage"]
  end
end
