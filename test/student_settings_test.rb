require_relative "test_helper"

class StudentSettingsTest < Minitest::Test
  def setup
    FileUtils.rm_f(STUDENT_SETTINGS_FILE)
  end

  def teardown
    FileUtils.rm_f(STUDENT_SETTINGS_FILE)
  end

  def test_birthday_stores_only_month_and_day_and_repeats_annually
    assert_nil load_student_settings["birthday_month"]
    settings = save_student_settings("11", "15")
    assert_equal({ "birthday_month" => 11, "birthday_day" => 15 }, load_student_settings)
    assert_equal 0o600, File.stat(STUDENT_SETTINGS_FILE).mode & 0o777
    assert student_birthday?(settings, Date.new(2026, 11, 15))
    assert student_birthday?(settings, Date.new(2027, 11, 15))
    refute student_birthday?(settings, Date.new(2026, 11, 16))
    save_student_settings("", "")
    refute student_birthday?(load_student_settings, Date.new(2026, 11, 15))
  end

  def test_invalid_dates_preserve_settings_and_february_29_is_supported
    settings = save_student_settings("2", "29")
    [["2", "30"], ["4", "31"], ["0", "10"], ["13", "1"], ["1", "0"], ["1", "-1"], ["-1", "1"], ["1", ""], ["", "5"], ["1.5", "2"]].each do |month, day|
      assert_raises(ArgumentError) { save_student_settings(month, day) }
      assert_equal settings, load_student_settings
    end
    assert student_birthday?(settings, Date.new(2028, 2, 29))
    refute student_birthday?(settings, Date.new(2027, 2, 28))
    refute valid_student_settings?(settings.merge("birth_year" => 2013))
    refute valid_student_settings?("birthday_month" => "2", "birthday_day" => "29")
    File.write(STUDENT_SETTINGS_FILE, "{broken")
    assert_raises(StudentSettingsError) { load_student_settings }
  end
end
