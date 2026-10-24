require "base64"
require "cgi"
require "digest"
require "fileutils"
require "json"
require "net/smtp"
require "securerandom"
require "time"
require "zip"

BACKUP_SETTINGS_FILE =
  ENV.fetch("BACKUP_SETTINGS_FILE") do
    if File.directory?("/data")
      "/data/backup_settings.json"
    else
      File.expand_path(
        "../tmp/backup_settings.json",
        __dir__
      )
    end
  end

BACKUP_SEND_HOUR = 3
DIGEST_SEND_HOUR = 6
BACKUP_SCHEMA_VERSION = 4
BACKUP_MAX_ARCHIVE_BYTES = 25 * 1024 * 1024
BACKUP_MAX_ENTRY_BYTES = 10 * 1024 * 1024
BACKUP_MAX_TOTAL_BYTES = 25 * 1024 * 1024
$email_send_mutex = Mutex.new
$backup_restore_mutex = Mutex.new
$scheduled_email_attempts = {}

class EmailConfigurationError < StandardError; end
class BackupRestoreError < StandardError; end

def empty_scheduled_email_settings
  {
    "backup_recipients" => [],
    "backup_daily_enabled" => false,
    "last_backup_sent_on" => nil,
    "digest_recipients" => [],
    "digest_daily_enabled" => false,
    "last_digest_sent_on" => nil
  }
end

def normalize_email_recipients(value)
  values =
    if value.is_a?(Array)
      value
    else
      value.to_s.split(/[\s,;]+/)
    end

  values.map { |email| email.to_s.strip.downcase }.reject(&:empty?).uniq
end

def load_scheduled_email_settings
  return empty_scheduled_email_settings unless File.exist?(BACKUP_SETTINGS_FILE)

  stored = JSON.parse(File.read(BACKUP_SETTINGS_FILE))
  return empty_scheduled_email_settings unless stored.is_a?(Hash)

  legacy_recipient = stored["recipient_email"].to_s
  {
    "backup_recipients" => normalize_email_recipients(
      stored["backup_recipients"] || legacy_recipient
    ),
    "backup_daily_enabled" =>
      stored.key?("backup_daily_enabled") ?
        stored["backup_daily_enabled"] == true :
        stored["daily_enabled"] == true,
    "last_backup_sent_on" =>
      stored["last_backup_sent_on"] || stored["last_daily_sent_on"],
    "digest_recipients" =>
      normalize_email_recipients(stored["digest_recipients"]),
    "digest_daily_enabled" => stored["digest_daily_enabled"] == true,
    "last_digest_sent_on" => stored["last_digest_sent_on"]
  }
rescue JSON::ParserError => e
  puts "Unable to load scheduled email settings: #{e.message}"
  empty_scheduled_email_settings
end

def save_scheduled_email_settings(settings)
  FileUtils.mkdir_p(File.dirname(BACKUP_SETTINGS_FILE))

  temporary_file = "#{BACKUP_SETTINGS_FILE}.tmp.#{$$}"
  File.write(temporary_file, JSON.pretty_generate(settings))
  File.rename(temporary_file, BACKUP_SETTINGS_FILE)
end

def valid_scheduled_email?(value)
  value.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
end

def validate_recipient_list(recipients, label:, required:)
  if required && recipients.empty?
    raise ArgumentError, "Enter at least one #{label} email address"
  end

  invalid = recipients.reject { |email| valid_scheduled_email?(email) }
  return if invalid.empty?

  raise ArgumentError, "Invalid email address: #{invalid.first}"
end

def scheduled_email_settings_fields(request)
  backup_recipients = normalize_email_recipients(
    request.query["backup_recipients"]
  )
  digest_recipients = normalize_email_recipients(
    request.query["digest_recipients"]
  )
  backup_daily_enabled = request.query["backup_daily_enabled"] == "true"
  digest_daily_enabled = request.query["digest_daily_enabled"] == "true"

  validate_recipient_list(
    backup_recipients,
    label: "backup recipient",
    required: backup_daily_enabled
  )
  validate_recipient_list(
    digest_recipients,
    label: "digest recipient",
    required: digest_daily_enabled
  )

  existing = load_scheduled_email_settings
  existing.merge(
    "backup_recipients" => backup_recipients,
    "backup_daily_enabled" => backup_daily_enabled,
    "digest_recipients" => digest_recipients,
    "digest_daily_enabled" => digest_daily_enabled
  )
end

def backup_json(value)
  "#{JSON.pretty_generate(value)}\n"
end

def backup_payloads(now: Time.now)
  journal = $event_journal_mutex.synchronize do
    Marshal.load(Marshal.dump($event_journal))
  end
  achievement_history = $achievement_history_mutex.synchronize do
    load_achievement_history
  end
  settings = load_scheduled_email_settings.slice(
    "backup_recipients",
    "backup_daily_enabled",
    "digest_recipients",
    "digest_daily_enabled"
  )

  payloads = {
    "canvas_cache.json" => backup_json(dashboard_data || {}),
    "manual_coursework.json" => backup_json(load_manual_coursework),
    "grade_overrides.json" => backup_json(load_grade_overrides),
    "course_name_mappings.json" => backup_json(load_course_name_mappings),
    "hidden_courses.json" => backup_json(load_hidden_course_ids),
    "event_journal.json" => backup_json(journal),
    "backup_settings.json" => backup_json(settings),
    "achievement_history.json" => backup_json(achievement_history),
    "achievement_settings.json" => backup_json(load_achievement_settings),
    "school_calendar_settings.json" =>
      backup_json(load_school_calendar_settings),
    "spark_history.json" => backup_json(load_spark_history)
  }

  manifest = {
    "schema_version" => BACKUP_SCHEMA_VERSION,
    "created_at" => now.iso8601,
    "files" => payloads.transform_values do |content|
      {
        "bytes" => content.bytesize,
        "sha256" => Digest::SHA256.hexdigest(content)
      }
    end
  }
  payloads["manifest.json"] = backup_json(manifest)
  payloads
end

def build_backup_archive(now: Time.now)
  payloads = backup_payloads(now: now)
  payloads.each do |filename, content|
    if content.bytesize > BACKUP_MAX_ENTRY_BYTES
      raise BackupRestoreError, "The backup file #{filename} is larger than 10 MB and could not be restored safely."
    end
  end
  if payloads.values.sum(&:bytesize) > BACKUP_MAX_TOTAL_BYTES
    raise BackupRestoreError, "The backup data expands beyond 25 MB and could not be restored safely."
  end
  buffer = Zip::OutputStream.write_buffer do |archive|
    payloads.each do |filename, content|
      archive.put_next_entry(filename)
      archive.write(content)
    end
  end

  archive = buffer.string
  raise BackupRestoreError, "The backup ZIP is larger than 25 MB." if archive.bytesize > BACKUP_MAX_ARCHIVE_BYTES

  archive
end

def backup_archive_filename(now)
  "emberguide-backup-#{now.strftime("%Y-%m-%d-%H%M%S")}.zip"
end

def backup_restore_paths
  {
    "canvas_cache.json" => CACHE_FILE,
    "manual_coursework.json" => MANUAL_COURSEWORK_FILE,
    "grade_overrides.json" => GRADE_OVERRIDES_FILE,
    "course_name_mappings.json" => COURSE_NAME_MAPPINGS_FILE,
    "hidden_courses.json" => HIDDEN_COURSES_FILE,
    "event_journal.json" => EVENT_JOURNAL_FILE,
    "backup_settings.json" => BACKUP_SETTINGS_FILE,
    "achievement_history.json" => ACHIEVEMENT_HISTORY_FILE,
    "achievement_settings.json" => ACHIEVEMENT_SETTINGS_FILE,
    "school_calendar_settings.json" => SCHOOL_CALENDAR_SETTINGS_FILE,
    "spark_history.json" => SPARK_HISTORY_FILE
  }
end

def validate_backup_json(filename, value)
  valid =
    case filename
    when "spark_history.json"
      valid_spark_history?(value)
    when "canvas_cache.json", "course_name_mappings.json"
      value.is_a?(Hash)
    when "manual_coursework.json"
      value.is_a?(Hash) &&
        value["courses"].is_a?(Hash) &&
        value["assignments"].is_a?(Hash)
    when "grade_overrides.json"
      value.is_a?(Hash) &&
        value.fetch("canvas", {}).is_a?(Hash) &&
        value.fetch("custom", {}).is_a?(Hash)
    when "hidden_courses.json"
      value.is_a?(Array)
    when "event_journal.json"
      value.is_a?(Hash) &&
        value["next_id"].is_a?(Integer) &&
        value["events"].is_a?(Array)
    when "backup_settings.json"
      value.is_a?(Hash)
    when "achievement_history.json"
      value.is_a?(Hash) &&
        value["daily_missing_counts"].is_a?(Hash) &&
        value["daily_missing_counts"].values.all? { |count| count.is_a?(Integer) } &&
        begin
          validated_earned_badges(value.fetch("earned_badges", {}))
        rescue ArgumentError
          false
        end
    when "achievement_settings.json"
      begin
        value.is_a?(Hash) &&
          value["strong_score_threshold"].is_a?(Integer) &&
          (60..100).cover?(value["strong_score_threshold"]) &&
          achievement_school_day_overrides(
            value.fetch("school_day_overrides", {}),
            *achievement_school_year_dates(
              value.fetch("school_year_start", DEFAULT_SCHOOL_YEAR_START),
              value.fetch("school_year_end", DEFAULT_SCHOOL_YEAR_END)
            )
          )
      rescue ArgumentError
        false
      end
    when "school_calendar_settings.json"
      value.is_a?(Hash) &&
        value.fetch("feed_url", "").is_a?(String) &&
        value.fetch("excluded_keywords", []).is_a?(Array)
    else
      false
    end

  raise BackupRestoreError, "Invalid data in #{filename}." unless valid
end

def backup_entries(archive)
  if archive.nil? || archive.empty?
    raise BackupRestoreError, "Choose an EmberGuide backup ZIP file."
  end
  if archive.bytesize > BACKUP_MAX_ARCHIVE_BYTES
    raise BackupRestoreError, "The backup ZIP is larger than 25 MB."
  end

  entries = {}
  total_bytes = 0

  Zip::File.open_buffer(archive) do |zip|
    zip.each do |entry|
      name = entry.name
      if entries.key?(name)
        raise BackupRestoreError, "The backup contains duplicate files."
      end
      unless name == "manifest.json" || backup_restore_paths.key?(name)
        raise BackupRestoreError, "The backup contains an unsupported file: #{name}."
      end
      if entry.directory? || entry.size > BACKUP_MAX_ENTRY_BYTES
        raise BackupRestoreError, "The backup contains an invalid file: #{name}."
      end

      content = entry.get_input_stream.read(BACKUP_MAX_ENTRY_BYTES + 1)
      if content.bytesize > BACKUP_MAX_ENTRY_BYTES
        raise BackupRestoreError, "The backup file #{name} is too large."
      end

      total_bytes += content.bytesize
      if total_bytes > BACKUP_MAX_TOTAL_BYTES
        raise BackupRestoreError, "The backup expands beyond 25 MB."
      end

      entries[name] = content
    end
  end

  entries
rescue Zip::Error
  raise BackupRestoreError, "The selected file is not a valid backup ZIP."
end

def validated_backup_payloads(archive)
  entries = backup_entries(archive)
  manifest_content = entries.delete("manifest.json")
  raise BackupRestoreError, "The backup manifest is missing." unless manifest_content

  manifest = JSON.parse(manifest_content)
  schema_version = manifest["schema_version"]
  unless [1, 2, 3, BACKUP_SCHEMA_VERSION].include?(schema_version)
    raise BackupRestoreError, "This backup version is not supported."
  end
  Time.iso8601(manifest.fetch("created_at"))

  expected_files =
    case schema_version
    when 1
      backup_restore_paths.keys -
        %w[
          school_calendar_settings.json
          achievement_history.json
          achievement_settings.json
          spark_history.json
        ]
    when 2
      backup_restore_paths.keys -
        %w[achievement_history.json achievement_settings.json spark_history.json]
    when 3
      backup_restore_paths.keys - %w[spark_history.json]
    else
      backup_restore_paths.keys
    end
  unless entries.keys.sort == expected_files.sort
    raise BackupRestoreError, "The backup file list is incomplete or invalid."
  end

  manifest_files = manifest["files"]
  unless manifest_files.is_a?(Hash) &&
      manifest_files.keys.sort == entries.keys.sort
    raise BackupRestoreError, "The backup manifest does not match its files."
  end

  entries.to_h do |filename, content|
    metadata = manifest_files[filename]
    unless metadata.is_a?(Hash) &&
        metadata["bytes"] == content.bytesize &&
        metadata["sha256"] == Digest::SHA256.hexdigest(content)
      raise BackupRestoreError, "Backup verification failed for #{filename}."
    end

    value = JSON.parse(content)
    validate_backup_json(filename, value)
    [filename, { content: content, value: value }]
  end
rescue JSON::ParserError, KeyError, ArgumentError
  raise BackupRestoreError, "The backup manifest or data is invalid."
end

def write_restored_payloads(payloads)
  originals = {}
  temporary_files = {}

  payloads.each do |filename, payload|
    path = backup_restore_paths.fetch(filename)
    FileUtils.mkdir_p(File.dirname(path))
    originals[path] = File.exist?(path) ? File.binread(path) : nil
    temporary_path = "#{path}.restore.#{$$}"
    File.binwrite(temporary_path, payload.fetch(:content))
    temporary_files[path] = temporary_path
  end

  temporary_files.each do |path, temporary_path|
    File.rename(temporary_path, path)
  end
rescue SystemCallError
  originals.each do |path, content|
    if content
      File.binwrite(path, content)
    else
      FileUtils.rm_f(path)
    end
  end
  raise BackupRestoreError, "Unable to write the restored backup."
ensure
  temporary_files&.each_value { |path| FileUtils.rm_f(path) }
end

def apply_restored_runtime_state(payloads)
  if (cache = payloads.dig("canvas_cache.json", :value))
    $data_mutex.synchronize do
      $dashboard_data = cache.empty? ? nil : cache
      $last_successful_update =
        begin
          Time.parse(cache["updated_at"].to_s)
        rescue ArgumentError
          nil
        end
      $last_refresh_error = nil
    end
  end

  if (journal = payloads.dig("event_journal.json", :value))
    $event_journal_mutex.synchronize { $event_journal = journal }
  end

  $school_calendar_mutex.synchronize { $school_calendar_cache = nil }
  $scheduled_email_attempts = {}
end

def restore_backup_archive(archive)
  payloads = validated_backup_payloads(archive)

  $backup_restore_mutex.synchronize do
    $refresh_mutex.synchronize do
      SPARK_HISTORY_MUTEX.synchronize do
        begin
          if load_spark_history["conversations"].values.any? { |conversation| conversation["turns"].any? { |turn| turn["status"] == "pending" } }
            raise BackupRestoreError, "Wait for Spark to finish answering before restoring a backup."
          end
        rescue SparkHistoryError => e
          puts "Replacing unreadable Spark history during restore: #{e.message}"
        end
        if (history = payloads["spark_history.json"])
          history[:value]["conversations"].each_value do |conversation|
            conversation["turns"].each do |turn|
              next unless turn["status"] == "pending"

              turn["status"] = "interrupted"
              turn["error"] = "This backup was created before the answer finished. Ask your question again."
            end
          end
          history[:content] = backup_json(history[:value])
        end
        write_restored_payloads(payloads)
        apply_restored_runtime_state(payloads)
      end
    end
  end

  payloads.keys.sort
end

def gmail_email_configuration
  sender = options["gmail_sender"].to_s.strip
  password = options["gmail_app_password"].to_s.gsub(/\s+/, "")

  unless valid_scheduled_email?(sender) && !password.empty?
    raise EmailConfigurationError,
      "Configure the Gmail sender and app password in the Home Assistant add-on settings."
  end

  { sender: sender, password: password }
end

def backup_email_message(sender:, recipient:, archive:, filename:, now:)
  boundary = "emberguide-backup-#{SecureRandom.hex(16)}"
  encoded_archive = Base64.strict_encode64(archive).scan(/.{1,76}/).join("\r\n")

  [
    "From: EmberGuide <#{sender}>",
    "To: #{recipient}",
    "Subject: EmberGuide Backup for #{now.strftime("%B %-d, %Y")}",
    "Date: #{now.rfc2822}",
    "MIME-Version: 1.0",
    "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
    "",
    "--#{boundary}",
    "Content-Type: application/zip; name=\"#{filename}\"",
    "Content-Disposition: attachment; filename=\"#{filename}\"",
    "Content-Transfer-Encoding: base64",
    "",
    encoded_archive,
    "--#{boundary}--",
    ""
  ].join("\r\n")
end

def deliver_email_messages(sender:, password:, messages:)
  smtp = Net::SMTP.new("smtp.gmail.com", 587)
  smtp.enable_starttls_auto
  smtp.open_timeout = 10
  smtp.read_timeout = 30

  smtp.start("localhost", sender, password, :plain) do |connection|
    messages.each do |delivery|
      connection.send_message(
        delivery.fetch(:message),
        sender,
        delivery.fetch(:recipient)
      )
    end
  end
end

def send_emberguide_backup(recipients, now: Time.now)
  recipients = normalize_email_recipients(recipients)
  validate_recipient_list(recipients, label: "backup recipient", required: true)

  $email_send_mutex.synchronize do
    gmail = gmail_email_configuration
    archive = build_backup_archive(now: now)
    filename = backup_archive_filename(now)
    messages = recipients.map do |recipient|
      {
        recipient: recipient,
        message: backup_email_message(
          sender: gmail[:sender],
          recipient: recipient,
          archive: archive,
          filename: filename,
          now: now
        )
      }
    end

    deliver_email_messages(
      sender: gmail[:sender],
      password: gmail[:password],
      messages: messages
    )

    filename
  end
end

def digest_course_name(data, mappings, course_id)
  mappings.fetch(course_id.to_s, course_name(data, course_id))
end

def digest_grade_snapshot(data, mappings, overrides)
  combined_grade_submissions(data, overrides)
    .group_by { |submission| submission.dig("assignment", "course_id").to_s }
    .filter_map do |course_id, submissions|
      earned = submissions.sum { |submission| submission["score"].to_f }
      possible = submissions.sum do |submission|
        submission.dig("assignment", "points_possible").to_f
      end
      calculated = percentage(earned, possible)
      next unless calculated

      {
        "course_id" => course_id,
        "name" => digest_course_name(data, mappings, course_id),
        "percentage" => calculated.round,
        "letter" => letter_grade(calculated)
      }
    end
    .sort_by { |grade| [-grade["percentage"], grade["name"]] }
end

def digest_assignments_for(data, date)
  assignments = Array(data["upcoming"])
  unique = {}

  assignments.each do |assignment|
    due = assignment_due_time(assignment)
    next unless due&.getlocal&.to_date == date

    course_id = assignment_course_id(assignment)
    assignment_id_value = assignment_id(assignment)
    submission = submission_for(data, course_id, assignment_id_value)
    next if submission_complete?(submission)

    key = "#{course_id}:#{assignment_id_value || assignment_name(assignment)}"
    unique[key] ||= assignment
  end

  unique.values.sort_by do |assignment|
    [assignment_due_time(assignment), assignment_name(assignment)]
  end
end

def digest_recent_grades(data, overrides, now)
  cutoff = now - (7 * 24 * 60 * 60)

  combined_grade_submissions(data, overrides).filter_map do |submission|
    graded_at = parse_canvas_time(submission["graded_at"])
    next unless graded_at && graded_at >= cutoff && graded_at <= now

    submission.merge("_digest_graded_at" => graded_at)
  end.sort_by { |submission| submission["_digest_graded_at"] }.reverse
end

def digest_missing_assignments(data)
  Array(data["missing"]).reject do |assignment|
    submission_complete?(
      submission_for(
        data,
        assignment_course_id(assignment),
        assignment_id(assignment)
      )
    )
  end.sort_by do |assignment|
    [assignment_due_time(assignment) || Time.at(0), assignment_name(assignment)]
  end
end

def digest_data(now: Time.now)
  data = dashboard_data_with_manual || {}
  mappings = load_course_name_mappings
  overrides = load_grade_overrides
  data = hide_assignments_from_dashboard(data, overrides)
  today = now.getlocal.to_date

  {
    "profile_name" => profile_first_name(data),
    "grade_snapshot" => digest_grade_snapshot(data, mappings, overrides),
    "missing" => digest_missing_assignments(data),
    "due_today" => digest_assignments_for(data, today),
    "due_tomorrow" => digest_assignments_for(data, today + 1),
    "important_calendar_dates" => upcoming_school_calendar_events(
      school_calendar_events(now: now),
      today: today
    ),
    "recent_grades" => digest_recent_grades(data, overrides, now),
    "data" => data,
    "mappings" => mappings
  }
end

def digest_assignment_text(assignment, digest)
  due = assignment_due_time(assignment)
  course_id = assignment_course_id(assignment)
  course = digest_course_name(
    digest["data"],
    digest["mappings"],
    course_id
  )
  due_label =
    if due
      "#{date_label(due)} at #{due_time_label(due)}"
    else
      "No due date"
    end
  summary = "#{assignment_name(assignment)} - #{course} - #{due_label}"
  url = assignment_url(assignment)
  url ? "#{summary}\n  #{url}" : summary
end

def digest_text_body(digest, now)
  lines = [
    "Daily Digest for #{digest["profile_name"]} for #{now.strftime("%B %-d, %Y")}",
    "",
    "CURRENT GRADES"
  ]

  if digest["grade_snapshot"].empty?
    lines << "No graded assignments yet."
  else
    digest["grade_snapshot"].each do |grade|
      lines << "#{grade["name"]}: #{grade["percentage"]}% (#{grade["letter"]})"
    end
  end

  lines.concat(["", "MISSING WORK"])
  if digest["missing"].empty?
    lines << "No missing work."
  else
    digest["missing"].each do |assignment|
      lines << digest_assignment_text(assignment, digest)
    end
  end

  [["DUE TODAY", "due_today"], ["DUE TOMORROW", "due_tomorrow"]].each do |title, key|
    lines.concat(["", title])
    assignments = digest[key]
    if assignments.empty?
      lines << "Nothing due."
    else
      assignments.each { |assignment| lines << digest_assignment_text(assignment, digest) }
    end
  end

  lines.concat(["", "UPCOMING SCHEDULE CHANGES"])
  if digest["important_calendar_dates"].empty?
    lines << "No important dates in the next 30 days."
  else
    digest["important_calendar_dates"].each do |event|
      date_label =
        if event["end_date"] > event["start_date"]
          "#{event["start_date"].strftime("%A, %B %-d")} through " \
            "#{event["end_date"].strftime("%A, %B %-d")}"
        else
          event["start_date"].strftime("%A, %B %-d")
        end
      lines << "#{event["title"]} - #{date_label}"
    end
  end

  lines.concat(["", "GRADES POSTED IN THE LAST 7 DAYS"])
  if digest["recent_grades"].empty?
    lines << "No grades posted."
  else
    digest["recent_grades"].each do |submission|
      assignment = submission["assignment"]
      course = digest_course_name(
        digest["data"],
        digest["mappings"],
        assignment["course_id"]
      )
      grade_line = "#{assignment["name"]} - #{course}: " \
        "#{format_number(submission["score"])}/" \
        "#{format_number(assignment["points_possible"])} " \
        "(#{submission["_digest_graded_at"].getlocal.strftime("%b %-d")})"
      url = assignment_url(submission)
      lines << (url ? "#{grade_line}\n  #{url}" : grade_line)
    end
  end

  lines.join("\n")
end

def digest_grade_colors(letter)
  {
    "A" => { foreground: "#4fd6a0", background: "#11221f", border: "#285746" },
    "B" => { foreground: "#58a6ff", background: "#101d2d", border: "#284f78" },
    "C" => { foreground: "#ffc96b", background: "#211c14", border: "#64502b" },
    "D" => { foreground: "#ff8a5b", background: "#241711", border: "#6d3825" },
    "F" => { foreground: "#ff7085", background: "#251319", border: "#6d2f3a" }
  }.fetch(
    letter,
    { foreground: "#9b98b2", background: "#121020", border: "#29263d" }
  )
end

def digest_recent_grade_colors(score, possible)
  calculated = percentage(score, possible)

  if calculated && calculated >= 100
    {
      foreground: "#ffc96b",
      background: "#211c14",
      border: "#64502b"
    }
  elsif calculated && calculated < 70
    {
      foreground: "#ff7085",
      background: "#251319",
      border: "#6d2f3a"
    }
  else
    {
      foreground: "#f4f2ff",
      background: "#121020",
      border: "#29263d"
    }
  end
end

def digest_assignment_html(assignment, digest)
  due = assignment_due_time(assignment)
  course = digest_course_name(
    digest["data"],
    digest["mappings"],
    assignment_course_id(assignment)
  )
  due_label =
    if due
      "#{date_label(due)}<br><span style=\"color:#9b98b2;font-size:12px;\">" \
        "#{due_time_label(due)}</span>"
    else
      "No due date"
    end
  name = CGI.escapeHTML(assignment_name(assignment))
  url = assignment_url(assignment)
  name_html =
    if url
      "<a href=\"#{CGI.escapeHTML(url)}\" style=\"color:#f4f2ff;text-decoration:underline;text-decoration-color:#5f5b83;\">#{name}</a>"
    else
      name
    end

  <<~HTML
    <tr>
      <td style="padding:12px 14px;border-bottom:1px solid #29263d;color:#f4f2ff;">
        <strong style="color:#f4f2ff;">#{name_html}</strong><br>
        <span style="color:#9b98b2;font-size:13px;">#{CGI.escapeHTML(course)}</span>
      </td>
      <td style="padding:12px 14px;border-bottom:1px solid #29263d;color:#f4f2ff;text-align:right;white-space:nowrap;">
        #{due_label}
      </td>
    </tr>
  HTML
end

def digest_html_body(digest, now, logo_src: "/emberguide-icon.png")
  grade_cards =
    if digest["grade_snapshot"].empty?
      '<p style="margin:0;color:#9b98b2;">No graded assignments yet.</p>'
    else
      cards = digest["grade_snapshot"].map do |grade|
        colors = digest_grade_colors(grade["letter"])
        progress = [[grade["percentage"], 0].max, 100].min
        <<~HTML
          <td class="grade-card-cell" style="width:33.333%;padding:5px;vertical-align:top;">
            <div style="padding:13px;border:1px solid #{colors[:border]};border-radius:10px;background:#{colors[:background]};">
              <div style="min-height:32px;font-size:12px;font-weight:700;line-height:1.35;color:#d7d4e5;">#{CGI.escapeHTML(grade["name"])}</div>
              <table role="presentation" style="width:100%;margin-top:8px;border-collapse:collapse;">
                <tr>
                  <td style="font-size:22px;font-weight:800;line-height:1;color:#f4f2ff;">#{grade["percentage"]}%</td>
                  <td style="text-align:right;">
                    <span style="display:inline-block;min-width:20px;padding:4px;border-radius:6px;background:#{colors[:border]};color:#{colors[:foreground]};font-size:12px;font-weight:800;text-align:center;">#{grade["letter"]}</span>
                  </td>
                </tr>
              </table>
              <div style="height:6px;margin-top:11px;border-radius:999px;background:#242139;">
                <div style="width:#{progress}%;height:6px;border-radius:999px;background:#{colors[:foreground]};"></div>
              </div>
            </div>
          </td>
        HTML
      end

      cards.each_slice(3).map do |row|
        empty_cells = "<td></td>" * (3 - row.length)
        "<tr>#{row.join}#{empty_cells}</tr>"
      end.join
    end

  assignment_section = lambda do |title, assignments|
    section_colors = {
      "Missing Work" => { foreground: "#ff7085", background: "#181017", border: "#572b35" },
      "Due Today" => { foreground: "#ffc96b", background: "#17140f", border: "#55462a" },
      "Due Tomorrow" => { foreground: "#58a6ff", background: "#0f1621", border: "#284463" }
    }.fetch(
      title,
      { foreground: "#f4f2ff", background: "#121020", border: "#29263d" }
    )
    rows =
      if assignments.empty?
        '<tr><td style="padding:14px;color:#9b98b2;">All clear.</td></tr>'
      else
        assignments.map { |assignment| digest_assignment_html(assignment, digest) }.join
      end

    <<~HTML
      <div class="digest-card" style="margin-top:18px;padding:18px;border:1px solid #29263d;border-radius:14px;background:#121020;">
        <h2 style="margin:0 0 10px;font-size:18px;color:#f4f2ff;">#{title}</h2>
        <table role="presentation" style="width:100%;border:1px solid #{section_colors[:border]};border-left:4px solid #{section_colors[:foreground]};border-collapse:collapse;border-radius:10px;background:#{section_colors[:background]};color:#f4f2ff;">
          #{rows}
        </table>
      </div>
    HTML
  end

  recent_rows =
    if digest["recent_grades"].empty?
      '<tr><td style="padding:14px;color:#9b98b2;">No grades posted.</td></tr>'
    else
      digest["recent_grades"].map do |submission|
        assignment = submission["assignment"]
        colors = digest_recent_grade_colors(
          submission["score"],
          assignment["points_possible"]
        )
        assignment_name = CGI.escapeHTML(assignment["name"].to_s)
        url = assignment_url(submission)
        assignment_name_html =
          if url
            "<a href=\"#{CGI.escapeHTML(url)}\" style=\"color:#{colors[:foreground]};text-decoration:underline;text-decoration-color:#{colors[:border]};\">#{assignment_name}</a>"
          else
            assignment_name
          end
        course = digest_course_name(
          digest["data"],
          digest["mappings"],
          assignment["course_id"]
        )
        <<~HTML
          <tr style="background:#{colors[:background]};color:#{colors[:foreground]};">
            <td style="padding:12px 14px;border-bottom:1px solid #{colors[:border]};">
              <strong style="color:#{colors[:foreground]};">#{assignment_name_html}</strong><br>
              <span style="color:#9b98b2;font-size:13px;">#{CGI.escapeHTML(course)}</span>
            </td>
            <td style="padding:12px 14px;border-bottom:1px solid #{colors[:border]};text-align:right;white-space:nowrap;">
              <strong style="color:#{colors[:foreground]};">#{format_number(submission["score"])}/#{format_number(assignment["points_possible"])}</strong><br>
              <span style="color:#9b98b2;font-size:12px;">#{submission["_digest_graded_at"].getlocal.strftime("%b %-d")}</span>
            </td>
          </tr>
        HTML
      end.join
    end

  calendar_rows =
    if digest["important_calendar_dates"].empty?
      '<tr><td style="padding:14px;color:#9b98b2;">No schedule changes in the next 30 days.</td></tr>'
    else
      digest["important_calendar_dates"].map do |event|
        date_label =
          if event["end_date"] > event["start_date"]
            "#{event["start_date"].strftime("%a, %b %-d")} through " \
              "#{event["end_date"].strftime("%a, %b %-d")}"
          else
            event["start_date"].strftime("%A, %b %-d")
          end
        location =
          if event["location"].empty?
            ""
          else
            "<br><span style=\"color:#9b98b2;font-size:12px;\">" \
              "#{CGI.escapeHTML(event["location"])}</span>"
          end

        <<~HTML
          <tr>
            <td style="padding:12px 14px;border-bottom:1px solid #29263d;color:#f4f2ff;">
              <strong style="color:#f4f2ff;">#{CGI.escapeHTML(event["title"])}</strong>#{location}
            </td>
            <td style="padding:12px 14px;border-bottom:1px solid #29263d;color:#d7d4e5;text-align:right;white-space:nowrap;">
              #{date_label}
            </td>
          </tr>
        HTML
      end.join
    end

  <<~HTML
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          @media only screen and (max-width: 600px) {
            .digest-wrapper {
              padding: 12px !important;
            }

            .digest-header {
              margin-bottom: 16px !important;
              padding: 18px !important;
            }

            .digest-title {
              font-size: 26px !important;
              line-height: 1.25 !important;
            }

            .grade-snapshot {
              padding: 14px !important;
            }

            .digest-card {
              padding: 14px !important;
            }

            .grade-card-cell {
              display: block !important;
              width: auto !important;
              padding: 6px 0 !important;
            }
          }
        </style>
      </head>
      <body style="margin:0;padding:0;background:#080711;font-family:Arial,sans-serif;color:#f4f2ff;">
        <div class="digest-wrapper" style="max-width:720px;margin:0 auto;padding:28px 24px 36px;">
          <div class="digest-header" style="margin-bottom:20px;padding:25px;border:1px solid #373256;border-top:4px solid #8583ff;border-radius:14px;background:#171427;color:#f4f2ff;">
            <table role="presentation" style="margin-bottom:14px;border-collapse:collapse;">
              <tr>
                <td style="width:24px;vertical-align:middle;">
                  <img src="#{CGI.escapeHTML(logo_src)}" width="24" height="24" alt="" style="display:block;width:24px;height:24px;border:0;border-radius:6px;">
                </td>
                <td style="padding-left:8px;vertical-align:middle;font-size:14px;font-weight:800;letter-spacing:1px;color:#f4f2ff;">EmberGuide</td>
              </tr>
            </table>
            <h1 class="digest-title" style="margin:0;font-size:30px;line-height:1.2;color:#f4f2ff;">Daily Digest</h1>
            <p style="margin:8px 0 0;font-size:15px;color:#d7d4e5;">#{CGI.escapeHTML(digest["profile_name"])} &middot; #{now.strftime("%B %-d, %Y")}</p>
            <p style="margin:15px 0 0;font-size:14px;line-height:1.5;color:#9b98b2;">A quick look at grades, assignments, and the days ahead.</p>
          </div>

          <div class="grade-snapshot" style="padding:19px;border-radius:14px;background:#121020;border:1px solid #29263d;">
            <h2 style="margin:0 0 12px;font-size:18px;color:#f4f2ff;">Current Grade Snapshot</h2>
            <table role="presentation" style="width:100%;border-collapse:collapse;">#{grade_cards}</table>
          </div>

          #{assignment_section.call("Missing Work", digest["missing"])}
          #{assignment_section.call("Due Today", digest["due_today"])}
          #{assignment_section.call("Due Tomorrow", digest["due_tomorrow"])}

          <div class="digest-card" style="margin-top:18px;padding:18px;border:1px solid #29263d;border-radius:14px;background:#121020;">
            <h2 style="margin:0 0 10px;font-size:18px;color:#f4f2ff;">Upcoming Schedule Changes</h2>
            <table role="presentation" style="width:100%;border:1px solid #393455;border-collapse:collapse;border-radius:10px;background:#151225;color:#f4f2ff;">
              #{calendar_rows}
            </table>
          </div>

          <div class="digest-card" style="margin-top:18px;padding:18px;border:1px solid #29263d;border-radius:14px;background:#121020;">
            <h2 style="margin:0 0 10px;font-size:18px;color:#f4f2ff;">Grades Posted in the Last 7 Days</h2>
            <table role="presentation" style="width:100%;border:1px solid #29263d;border-collapse:collapse;border-radius:10px;background:#0e0c19;color:#f4f2ff;">
              #{recent_rows}
            </table>
          </div>

          <div style="padding:24px 0 0;text-align:center;font-size:12px;color:#68647d;">Sent by EmberGuide</div>
        </div>
      </body>
    </html>
  HTML
end

def digest_email_message(sender:, recipient:, digest:, now:)
  boundary = "emberguide-digest-#{SecureRandom.hex(16)}"
  related_boundary = "emberguide-related-#{SecureRandom.hex(16)}"
  logo_content_id = "emberguide-logo"
  text = digest_text_body(digest, now)
  html = digest_html_body(digest, now, logo_src: "cid:#{logo_content_id}")
  logo = Base64.strict_encode64(
    File.binread(File.join(APP_ROOT, "icon.png"))
  ).scan(/.{1,76}/).join("\r\n")
  profile_name = digest["profile_name"].to_s.gsub(/[\r\n]+/, " ").strip

  [
    "From: EmberGuide <#{sender}>",
    "To: #{recipient}",
    "Subject: #{profile_name}'s EmberGuide Daily Digest",
    "Date: #{now.rfc2822}",
    "MIME-Version: 1.0",
    "Content-Type: multipart/alternative; boundary=\"#{boundary}\"",
    "",
    "--#{boundary}",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    text,
    "--#{boundary}",
    "Content-Type: multipart/related; boundary=\"#{related_boundary}\"",
    "",
    "--#{related_boundary}",
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    html,
    "--#{related_boundary}",
    "Content-Type: image/png; name=\"emberguide-icon.png\"",
    "Content-Transfer-Encoding: base64",
    "Content-ID: <#{logo_content_id}>",
    "Content-Disposition: inline; filename=\"emberguide-icon.png\"",
    "",
    logo,
    "--#{related_boundary}--",
    "--#{boundary}--",
    ""
  ].join("\r\n")
end

def send_emberguide_digest(recipients, now: Time.now)
  recipients = normalize_email_recipients(recipients)
  validate_recipient_list(recipients, label: "digest recipient", required: true)

  $email_send_mutex.synchronize do
    gmail = gmail_email_configuration
    digest = digest_data(now: now)
    messages = recipients.map do |recipient|
      {
        recipient: recipient,
        message: digest_email_message(
          sender: gmail[:sender],
          recipient: recipient,
          digest: digest,
          now: now
        )
      }
    end

    deliver_email_messages(
      sender: gmail[:sender],
      password: gmail[:password],
      messages: messages
    )

    recipients.length
  end
end

def scheduled_email_due?(settings, type, now)
  prefix = type.to_s
  hour = type == :backup ? BACKUP_SEND_HOUR : DIGEST_SEND_HOUR

  settings["#{prefix}_daily_enabled"] &&
    now.hour == hour &&
    settings["last_#{prefix}_sent_on"] != now.to_date.iso8601 &&
    $scheduled_email_attempts[[type, now.to_date]] != true
end

def send_scheduled_email_if_due(type, now = Time.now)
  settings = load_scheduled_email_settings
  return false unless scheduled_email_due?(settings, type, now)

  $scheduled_email_attempts[[type, now.to_date]] = true
  recipients = settings["#{type}_recipients"]

  if type == :backup
    send_emberguide_backup(recipients, now: now)
  else
    send_emberguide_digest(recipients, now: now)
  end

  settings["last_#{type}_sent_on"] = now.to_date.iso8601
  save_scheduled_email_settings(settings)
  true
rescue => e
  puts "Unable to send scheduled #{type} email: #{e.class}: #{e.message}"
  false
end

def send_scheduled_emails_if_due(now = Time.now)
  {
    backup: send_scheduled_email_if_due(:backup, now),
    digest: send_scheduled_email_if_due(:digest, now)
  }
end

def start_scheduled_email_thread
  Thread.new do
    loop do
      send_scheduled_emails_if_due
      sleep 60
    end
  end
end
