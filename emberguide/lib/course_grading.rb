class CourseGradingError < StandardError; end

def course_grading_settings(overrides, course_id)
  overrides.fetch("grading", {}).fetch(
    course_id.to_s,
    { "mode" => "points", "categories" => {}, "assignments" => {} }
  )
end

def valid_course_grading?(grading)
  return false unless grading.is_a?(Hash)

  grading.all? do |course_id, settings|
    next false unless course_id.is_a?(String) && settings.is_a?(Hash)
    next false unless %w[points weighted].include?(settings["mode"])

    categories = settings["categories"]
    assignments = settings["assignments"]
    next false unless categories.is_a?(Hash) && assignments.is_a?(Hash)

    valid_categories = categories.all? do |id, category|
      id.is_a?(String) && id.match?(/\A[a-zA-Z0-9-]+\z/) &&
        category.is_a?(Hash) &&
        category["name"].is_a?(String) &&
        category["name"].strip.length.between?(1, 80) &&
        category["weight"].is_a?(Numeric) &&
        category["weight"].finite? &&
        category["weight"].between?(0, 100)
    end
    next false unless valid_categories

    names = categories.values.map { |category| category["name"].strip.downcase }
    total = categories.values.sum { |category| category["weight"] }
    names.uniq.length == names.length && total <= 100.000001 &&
      (settings["mode"] == "points" || total > 0) &&
      assignments.all? do |key, category_id|
        key.is_a?(String) && key.match?(/\A(?:canvas|custom)-.+\z/) &&
          categories.key?(category_id)
      end
  end
end

def grading_assignment_key(submission)
  id = assignment_id(submission).to_s
  submission["_custom_grade"] ? id : "canvas-#{id}"
end

def course_grade_summary(submissions, settings)
  earned = submissions.sum { |submission| submission["score"].to_f }
  possible = submissions.sum { |submission| submission.dig("assignment", "points_possible").to_f }
  result = { "earned" => earned, "possible" => possible }
  return result.merge("percentage" => percentage(earned, possible)) unless settings["mode"] == "weighted"

  categories = settings["categories"]
  grouped = submissions.group_by do |submission|
    settings["assignments"][grading_assignment_key(submission)]
  end
  missing = grouped.sum { |id, grades| categories.key?(id) ? 0 : grades.length }
  if missing > 0
    result["category_notice"] = "Provisional grade: #{missing} uncategorized graded #{missing == 1 ? 'assignment' : 'assignments'} excluded. Assign categories to update."
  end

  active = grouped.filter_map do |id, grades|
    next unless categories.key?(id)

    weight = categories.fetch(id)["weight"]
    points = grades.sum { |submission| submission.dig("assignment", "points_possible").to_f }
    next unless weight > 0 && points > 0

    score = grades.sum { |submission| submission["score"].to_f }
    [score / points, weight]
  end
  if active.empty?
    return result.merge(
      "percentage" => nil,
      "error" => "No graded work in a positive-weight category yet."
    )
  end

  weighted = active.sum { |ratio, weight| ratio * weight } / active.sum(&:last)
  result.merge("percentage" => (weighted * 100).round(1))
end

def course_grading_fields(query, existing, course_id, assignment_fields)
  mode = query["grading_mode"]
  raise ArgumentError, "Choose total points or weighted categories." unless %w[points weighted].include?(mode)

  categories = {}
  query.each_key do |key|
    id = key[/\Agrading_category_([a-zA-Z0-9-]+)_name\z/, 1]
    next unless id

    name = query[key].to_s.strip
    weight = query["grading_category_#{id}_weight"].to_s.strip
    next if name.empty? && weight.empty?

    begin
      categories[id] = { "name" => name, "weight" => Float(weight) }
    rescue ArgumentError, TypeError
      raise ArgumentError, "Each category needs a name and a numeric weight from 0 to 100."
    end
  end

  assignments = course_grading_settings(existing, course_id)["assignments"].select do |_key, category|
    categories.key?(category)
  end
  assignment_fields.each do |assignment_key, field|
    next unless query.key?(field)

    category = query[field].to_s
    if category.empty?
      assignments.delete(assignment_key)
    else
      raise ArgumentError, "Select a valid assignment category." unless categories.key?(category)

      assignments[assignment_key] = category
    end
  end
  settings = { "mode" => mode, "categories" => categories, "assignments" => assignments }
  unless valid_course_grading?(course_id => settings)
    raise ArgumentError, "Use unique category names (1-80 characters) and weights from 0 to 100 totaling at most 100. Weighted grading needs a positive weight."
  end

  settings
end
