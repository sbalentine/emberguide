# Changelog

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
