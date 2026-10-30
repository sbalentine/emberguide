require_relative "test_helper"

class GradeReviewsTest < Minitest::Test
  def setup
    [GRADE_OVERRIDES_FILE, HIDDEN_COURSES_FILE, MANUAL_COURSEWORK_FILE].each { |path| FileUtils.rm_f(path) }
    @now = Time.local(2026, 10, 29, 12)
    $dashboard_data = {
      "courses" => [{ "id" => 1, "name" => "Math" }],
      "course_names" => { "1" => "Math" },
      "grades" => [], "submissions" => {}
    }
  end

  def grade(id = 10, score: 60, points: 100, course: 1)
    {
      "assignment_id" => id, "score" => score, "graded_at" => (@now - 60 * 86400).iso8601,
      "assignment" => { "id" => id, "course_id" => course, "name" => "Quiz #{id}",
        "points_possible" => points, "html_url" => "/courses/#{course}/assignments/#{id}" }
    }
  end

  def pending
    unreviewed_grades(sync_grade_reviews)
  end

  def review(id = 10, score: 60, points: 100, reviewed: "true")
    update_grade_review(1, id, score: score, points_possible: points, reviewed: reviewed, now: @now)
  end

  def test_includes_all_low_grades_without_age_cutoff_and_uses_the_exact_threshold
    $dashboard_data["grades"] = [
      grade(10, score: 0), grade(11, score: 69.99), grade(12, score: 70),
      grade(13, score: 7, points: 10), grade(14, score: nil), grade(15, points: 0)
    ]
    assert_equal %w[10 11], pending.map { |entry| entry["assignment_id"] }
    assert_equal "<70%", grade_review_percentage_label(pending.find { |entry| entry["assignment_id"] == "11" })
    assert File.exist?(GRADE_REVIEWS_FILE)
    assert_equal 0o600, File.stat(GRADE_REVIEWS_FILE).mode & 0o777
  end

  def test_review_persists_and_can_be_undone
    $dashboard_data["grades"] = [grade]
    assert_equal 1, pending.length
    review
    assert_empty pending
    assert_equal @now.iso8601, load_grade_reviews.values.first["reviewed_at"]
    review(reviewed: "false")
    assert_equal 1, pending.length
  end

  def test_score_or_points_change_requires_another_review_but_timestamp_alone_does_not
    $dashboard_data["grades"] = [grade]
    review
    $dashboard_data["grades"].first["graded_at"] = @now.iso8601
    assert_empty pending
    $dashboard_data["grades"].first["score"] = 65
    assert_equal 1, pending.length
    review(score: 65)
    $dashboard_data["grades"].first["assignment"]["points_possible"] = 110
    assert_equal 1, pending.length
  end

  def test_unreviewed_grades_remain_when_they_leave_the_canvas_response
    $dashboard_data["grades"] = [grade]
    assert_equal 1, pending.length
    $dashboard_data["grades"] = []
    assert_equal "Quiz 10", pending.first["name"]
    review
    assert_empty pending
  end

  def test_improved_grades_no_longer_require_review_and_a_later_low_score_does
    $dashboard_data["grades"] = [grade]
    assert_equal 1, pending.length
    $dashboard_data["grades"].first["score"] = 70
    assert_empty pending
    $dashboard_data["grades"].first["score"] = 50
    assert_equal 1, pending.length
  end

  def test_hidden_excused_and_omitted_grades_are_excluded
    $dashboard_data["grades"] = [
      grade(10).merge("excused" => true), grade(11), grade(12), grade(13, course: 2)
    ]
    $dashboard_data["grades"][1]["assignment"]["omit_from_final_grade"] = true
    save_grade_overrides("canvas" => { "12" => { "hidden" => true } })
    save_hidden_course_ids(["2"])
    assert_empty pending
  end

  def test_excusing_an_existing_low_grade_clears_its_queue_entry
    $dashboard_data["grades"] = [grade]
    assert_equal 1, pending.length
    $dashboard_data["grades"].first["excused"] = true
    assert_empty pending
  end

  def test_effective_overrides_and_custom_grades_are_tracked
    $dashboard_data["grades"] = [grade(score: 90)]
    save_grade_overrides(
      "canvas" => { "10" => { "score" => 60 } },
      "custom" => { "extra" => { "course_id" => 1, "name" => "Reading quiz", "score" => 4,
        "points_possible" => 10, "graded_at" => "2026-10-28" } }
    )
    assert_equal %w[custom-extra 10], pending.map { |entry| entry["assignment_id"] }
    review
    save_grade_overrides("canvas" => { "10" => { "score" => 65 } })
    assert_equal ["10"], pending.map { |entry| entry["assignment_id"] }
  end

  def test_course_and_assignment_identifiers_are_both_part_of_the_review_key
    $dashboard_data["grades"] = [grade, grade(course: 2)]
    assert_equal 2, pending.length
    review
    assert_equal ["2"], pending.map { |entry| entry["course_id"] }
  end

  def test_a_points_override_on_a_zero_point_canvas_grade_does_not_reset_reviews
    $dashboard_data["grades"] = [grade(points: 0)]
    save_grade_overrides("canvas" => { "10" => { "points_possible" => 100 } })
    assert_equal 1, pending.length
    review
    assert_empty pending
    assert_empty pending
  end

  def test_hiding_a_previously_reviewed_grade_preserves_its_review_when_unhidden
    $dashboard_data["grades"] = [grade]
    review
    save_grade_overrides("canvas" => { "10" => { "hidden" => true } })
    assert_empty pending
    save_grade_overrides({})
    assert_empty pending
  end

  def test_stale_scores_and_invalid_inputs_cannot_mark_a_grade_reviewed
    $dashboard_data["grades"] = [grade]
    error = assert_raises(ArgumentError) { review(score: 50) }
    assert_includes error.message, "grade changed"
    assert_raises(ArgumentError) { review(score: "garbage") }
    assert_raises(ArgumentError) { review(reviewed: "yes") }
    assert_raises(ArgumentError) { review(999) }
    assert_equal 1, pending.length
  end

  def test_corrupt_storage_fails_explicitly_without_overwriting_it
    File.write(GRADE_REVIEWS_FILE, "invalid JSON")
    error = assert_raises(GradeReviewError) { pending }
    assert_includes error.message, "Unable to read saved grade reviews"
    assert_equal "invalid JSON", File.read(GRADE_REVIEWS_FILE)
    assert_raises(GradeReviewError) { save_grade_reviews("invalid" => {}) }
  end

  def test_unsafe_assignment_links_are_not_saved
    $dashboard_data["grades"] = [grade]
    $dashboard_data["grades"].first["assignment"]["html_url"] = "javascript:alert(1)"
    assert_nil pending.first["html_url"]
    refute valid_grade_reviews?("invalid" => {})
  end
end
