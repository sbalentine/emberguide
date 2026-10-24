ENV["CANVAS_TOKEN"] = "test-token"
ENV["CANVAS_URL"] = "https://temecula.instructure.com"
ENV["PORT"] = "0"
ENV["GMAIL_SENDER"] = ""
ENV["GMAIL_APP_PASSWORD"] = ""

require "minitest/autorun"
require "tmpdir"
require "fileutils"

TEST_TMP_DIR = Dir.mktmpdir("canvas-dashboard-test")
ENV["CACHE_FILE"] = File.join(TEST_TMP_DIR, "canvas_cache.json")
ENV["EVENT_JOURNAL_FILE"] = File.join(TEST_TMP_DIR, "event_journal.json")
ENV["COURSE_NAME_MAPPINGS_FILE"] = File.join(TEST_TMP_DIR, "course_names.json")
ENV["GRADE_OVERRIDES_FILE"] = File.join(TEST_TMP_DIR, "grade_overrides.json")
ENV["MANUAL_COURSEWORK_FILE"] = File.join(TEST_TMP_DIR, "manual_coursework.json")
ENV["HIDDEN_COURSES_FILE"] = File.join(TEST_TMP_DIR, "hidden_courses.json")
ENV["BACKUP_SETTINGS_FILE"] = File.join(TEST_TMP_DIR, "backup_settings.json")
ENV["SCHOOL_CALENDAR_SETTINGS_FILE"] = File.join(TEST_TMP_DIR, "school_calendar_settings.json")
ENV["SPARK_SETTINGS_FILE"] = File.join(TEST_TMP_DIR, "spark_settings.json")
ENV["SPARK_HISTORY_FILE"] = File.join(TEST_TMP_DIR, "spark_history.json")
ENV["ACHIEVEMENT_HISTORY_FILE"] = File.join(TEST_TMP_DIR, "achievement_history.json")
ENV["ACHIEVEMENT_SETTINGS_FILE"] = File.join(TEST_TMP_DIR, "achievement_settings.json")

require_relative "../emberguide/app"

Minitest.after_run do
  FileUtils.remove_entry(TEST_TMP_DIR) if File.exist?(TEST_TMP_DIR)
end

class Minitest::Test
  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def with_replaced_method(receiver, name, replacement)
    singleton_class = receiver.singleton_class
    had_method = singleton_class.method_defined?(name)
    original = singleton_class.instance_method(name) if had_method

    singleton_class.define_method(name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end

    yield
  ensure
    if had_method
      singleton_class.define_method(name, original)
    else
      singleton_class.remove_method(name)
    end
  end
end