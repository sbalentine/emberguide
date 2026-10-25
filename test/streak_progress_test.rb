require_relative "test_helper"

class StreakProgressTest < Minitest::Test
  def render_progress(current:, earned: [], group: ACHIEVEMENT_BADGE_GROUPS.first)
    streak_group = group.merge("badges" => group["goals"].each_with_index.map do |goal, index|
      { "name" => group["names"][index], "goal" => goal,
        "progress" => [current, goal].min, "earned_on" => earned.include?(goal) ? "2026-10-24" : nil }
    end)
    render_partial("streak_progress", binding)
  end

  def test_first_badge_progress_uses_current_streak
    html = render_progress(current: 3)
    assert_includes html, "Next badge: <strong>On the Dot</strong>"
    assert_includes html, 'value="3" max="5"'
    assert_includes html, "3 / 5 on-time assignments"
    assert_includes html, 'aria-label="On-Time Run: On the Dot progress"'
  end

  def test_reset_streak_targets_next_uncollected_badge_not_previous_earned_badge
    html = render_progress(current: 0, earned: [5, 10])
    assert_includes html, "Next badge: <strong>Deadline Ninja</strong>"
    assert_includes html, 'value="0" max="25"'
    assert_includes html, "0 / 25 on-time assignments"
  end

  def test_all_collected_shows_completion_instead_of_an_invented_target
    html = render_progress(current: 2, earned: [5, 10, 25, 50])
    assert_includes html, "All badges collected!"
    refute_includes html, "<progress"
    refute_includes html, "Next badge"
  end

  def test_school_year_next_badge_uses_percentage_units
    html = render_progress(current: 32.5, earned: [25], group: ACHIEVEMENT_BADGE_GROUPS.last)
    assert_includes html, "Next badge: <strong>Halfway Hero</strong>"
    assert_includes html, 'value="32.5" max="50"'
    assert_includes html, "32% / 50% of the school year completed"
  end
end
