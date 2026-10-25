require "date"
require "fileutils"
require "json"
require "securerandom"

STUDENT_SETTINGS_FILE = ENV.fetch("STUDENT_SETTINGS_FILE") do
  File.directory?("/data") ? "/data/student_settings.json" : File.expand_path("../tmp/student_settings.json", __dir__)
end
STUDENT_SETTINGS_MUTEX = Mutex.new

class StudentSettingsError < StandardError; end

def valid_student_settings?(settings)
  return false unless settings.is_a?(Hash) && settings.keys.sort == %w[birthday_day birthday_month]

  month, day = settings.values_at("birthday_month", "birthday_day")
  return true if month.nil? && day.nil?

  month.is_a?(Integer) && day.is_a?(Integer) &&
    month.between?(1, 12) && day.between?(1, 31) && Date.valid_date?(2000, month, day)
end

def load_student_settings
  return { "birthday_month" => nil, "birthday_day" => nil } unless File.exist?(STUDENT_SETTINGS_FILE)

  settings = JSON.parse(File.read(STUDENT_SETTINGS_FILE))
  raise StudentSettingsError, "Saved student settings are invalid. Restore a backup or repair the settings file." unless valid_student_settings?(settings)

  settings
rescue JSON::ParserError, SystemCallError
  raise StudentSettingsError, "Student settings couldn't be read. Check the app's storage or restore a backup."
end

def save_student_settings(month, day)
  settings = if month.to_s.empty? && day.to_s.empty?
               { "birthday_month" => nil, "birthday_day" => nil }
             else
               { "birthday_month" => Integer(month.to_s, 10), "birthday_day" => Integer(day.to_s, 10) }
             end
  raise ArgumentError, "Choose a valid birthday month and day, or leave both blank." unless valid_student_settings?(settings)

  STUDENT_SETTINGS_MUTEX.synchronize do
    FileUtils.mkdir_p(File.dirname(STUDENT_SETTINGS_FILE))
    temporary = "#{STUDENT_SETTINGS_FILE}.tmp.#{SecureRandom.hex(8)}"
    File.write(temporary, JSON.pretty_generate(settings), perm: 0o600)
    File.rename(temporary, STUDENT_SETTINGS_FILE)
  ensure
    FileUtils.rm_f(temporary) if temporary
  end
  settings
rescue ArgumentError, TypeError
  raise ArgumentError, "Choose a valid birthday month and day, or leave both blank."
rescue SystemCallError
  raise StudentSettingsError, "Student settings couldn't be saved. Check the app's storage."
end

def student_birthday?(settings, date)
  settings["birthday_month"] == date.month && settings["birthday_day"] == date.day
end
