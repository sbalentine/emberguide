# Changelog

## 1.16.1

- Give course grading settings more breathing room with clearer label spacing, roomier controls, and more readable instructions.
- Keep weighted course grades and trends visible using categorized work when assignments need a category.
- Mark provisional grades with a compact amber indicator linking to the category editor, instead of replacing the grade with a warning.
- Identify provisional grades consistently in daily digests and Spark context; uncategorized work stays excluded until assigned.

## 1.16.0

- Add opt-in per-class category-weighted grading with category selectors for Canvas and manually entered assignments.
- Use weighted course averages consistently in dashboard summaries, cumulative trends, daily digests, and Spark grade context.
- Preserve category choices through Canvas score refreshes and backups; keep total-points grading as the default.
- Exclude zero-weight and empty categories from course averages, count extra credit within its category, and withhold averages with an explicit warning when graded work needs a category.

## 1.15.0

- Show colored plus/minus letter grades consistently across course summaries, assignment scores, grade reviews, modules, the grade editor, and chart tooltips.
- Use 97/94/90 breakpoints for A+/A/A-, repeated for B, C, and D; retain F below 60%.
- Highlight perfect 100% scores with glowing gold badges and a reduced-motion-aware shimmer.

## 1.14.2

- Include zero-point extra-credit scores in grade chart totals, matching the grade snapshot.
- Preserve bonus points posted before the first point-bearing assignment.
- Display current grades with consistent whole-percentage rounding.
- Avoid undefined percentages in extra-credit chart tooltips.

## 1.14.1

- Fix a startup deadlock when loading an existing Canvas cache and synchronizing grade reviews.
- Preserve existing grade review acknowledgments.

## 1.14.0

- Show persistent unreviewed grades below 70% on the dashboard and in both daily email formats.
- Mark assignments reviewed from the dashboard, with an option to undo.
- Keep outstanding grades beyond the recent-grades window, even when they leave later Canvas responses.
- Request another review when a score or points possible changes and the grade remains below 70%.
- Remove review requirements when grades improve to 70% or higher.
- Respect local grade corrections, custom grades, and hidden, excused, omitted, and zero-point work.
- Include grade review history in backups with backward-compatible restores.
