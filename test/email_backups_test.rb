require_relative "test_helper"

class EmailBackupsTest < Minitest::Test
  def setup
    FileUtils.rm_f(DAILY_OVERVIEW_FILE)
    FileUtils.rm_f(SPARK_HISTORY_FILE)
    FileUtils.rm_f(BACKUP_SETTINGS_FILE)
    FileUtils.rm_f(MANUAL_COURSEWORK_FILE)
    FileUtils.rm_f(GRADE_OVERRIDES_FILE)
    FileUtils.rm_f(COURSE_NAME_MAPPINGS_FILE)
    FileUtils.rm_f(HIDDEN_COURSES_FILE)
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    FileUtils.rm_f(CACHE_FILE)
    FileUtils.rm_f(EVENT_JOURNAL_FILE)
    FileUtils.rm_f(ACHIEVEMENT_HISTORY_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
    $dashboard_data = base_data
    $event_journal = { "next_id" => 1, "events" => [] }
    $scheduled_email_attempts = {}
    $school_calendar_cache = nil
  end

  def teardown
    ENV["GMAIL_SENDER"] = ""
    ENV["GMAIL_APP_PASSWORD"] = ""
    FileUtils.rm_f(SCHOOL_CALENDAR_SETTINGS_FILE)
    $school_calendar_cache = nil
  end

  def base_data
    {
      "profile" => { "short_name" => "Avery" },
      "courses" => [
        { "id" => 1, "name" => "Math" },
        { "id" => 2, "name" => "Science" }
      ],
      "course_names" => { "1" => "Math", "2" => "Science" },
      "grades" => [],
      "missing" => [],
      "upcoming" => [],
      "todo" => [],
      "submissions" => {}
    }
  end

  def scheduled_settings(overrides = {})
    empty_scheduled_email_settings.merge(overrides)
  end

  def test_scheduled_email_settings_round_trip
    settings = scheduled_settings(
      "backup_recipients" => ["backup@example.com"],
      "backup_daily_enabled" => true,
      "digest_recipients" => ["one@example.com", "two@example.com"],
      "digest_daily_enabled" => true,
      "digest_spark_overview" => true
    )

    save_scheduled_email_settings(settings)

    assert_equal settings, load_scheduled_email_settings
  end

  def test_legacy_backup_settings_are_migrated
    File.write(
      BACKUP_SETTINGS_FILE,
      JSON.generate(
        "recipient_email" => "parent@example.com",
        "daily_enabled" => true,
        "last_daily_sent_on" => "2026-10-11"
      )
    )

    settings = load_scheduled_email_settings

    assert_equal ["parent@example.com"], settings["backup_recipients"]
    assert settings["backup_daily_enabled"]
    assert_equal "2026-10-11", settings["last_backup_sent_on"]
    assert_empty settings["digest_recipients"]
    refute settings["digest_spark_overview"]
  end

  def test_recipient_lists_accept_newlines_commas_and_remove_duplicates
    assert_equal(
      ["one@example.com", "two@example.com"],
      normalize_email_recipients(
        "One@example.com\n two@example.com,one@example.com"
      )
    )
  end

  def test_archive_contains_dashboard_data_without_credentials
    save_manual_coursework(
      "courses" => { "piano" => { "name" => "Piano" } },
      "assignments" => {}
    )
    save_scheduled_email_settings(
      scheduled_settings(
        "backup_recipients" => ["backup@example.com"],
        "digest_recipients" => ["digest@example.com"],
        "digest_spark_overview" => true
      )
    )
    save_school_calendar_settings(
      "https://calendar.example.test/middle-school.ics",
      "Elementary"
    )
    record_achievement_day(
      { "missing" => [] },
      date: Date.new(2026, 10, 11)
    )
    history = load_achievement_history
    history["earned_badges"] = { "on_time-5" => "2026-10-11" }
    save_achievement_history(history)

    archive = build_backup_archive(
      now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    )
    entries = {}
    Zip::File.open_buffer(archive) do |zip|
      zip.each { |entry| entries[entry.name] = entry.get_input_stream.read }
    end

    expected_files = %w[
      achievement_history.json
      achievement_settings.json
      backup_settings.json
      canvas_cache.json
      course_name_mappings.json
      event_journal.json
      grade_overrides.json
      hidden_courses.json
      manifest.json
      manual_coursework.json
      school_calendar_settings.json
      spark_history.json
    ]
    assert_equal expected_files, entries.keys.sort
    assert_equal "Piano", JSON.parse(entries["manual_coursework.json"]).dig(
      "courses",
      "piano",
      "name"
    )
    refute_includes archive, "test-token"
    refute entries.key?("options.json")
    assert JSON.parse(entries["backup_settings.json"])["digest_spark_overview"]
    refute entries.key?("daily_overview.json")
    assert_equal(
      "https://calendar.example.test/middle-school.ics",
      JSON.parse(entries["school_calendar_settings.json"])["feed_url"]
    )
    assert_equal(
      ["Elementary"],
      JSON.parse(
        entries["school_calendar_settings.json"]
      )["excluded_keywords"]
    )
    assert_equal(
      0,
      JSON.parse(entries["achievement_history.json"])
        .dig("daily_missing_counts", "2026-10-11")
    )
    assert_equal(
      80,
      JSON.parse(entries["achievement_settings.json"])["strong_score_threshold"]
    )
    assert_equal(
      "2026-08-12",
      JSON.parse(entries["achievement_settings.json"])["school_year_start"]
    )
    assert_equal(
      "2027-06-04",
      JSON.parse(entries["achievement_settings.json"])["school_year_end"]
    )
    assert_equal 5, JSON.parse(entries["manifest.json"])["schema_version"]
  end

  def test_backup_restore_round_trip_restores_local_state
    $dashboard_data = base_data.merge(
      "updated_at" => "2026-10-11T03:00:00-07:00"
    )
    save_manual_coursework(
      "courses" => { "music" => { "name" => "Music" } },
      "assignments" => {}
    )
    save_grade_overrides(
      "canvas" => {},
      "custom" => {
        "concert" => {
          "course_id" => "manual-music",
          "name" => "Concert",
          "score" => 19,
          "points_possible" => 20,
          "graded_at" => "2026-10-10"
        }
      }
    )
    save_course_name_mappings("1" => "Algebra")
    save_hidden_course_ids(["2"])
    save_school_calendar_settings(
      "https://calendar.example.test/school.ics",
      "Elementary"
    )
    save_scheduled_email_settings(
      scheduled_settings(
        "backup_recipients" => ["backup@example.com"],
        "digest_recipients" => ["digest@example.com"]
      )
    )
    $event_journal = {
      "next_id" => 2,
      "events" => [{ "id" => 1, "type" => "grade_posted" }]
    }
    record_achievement_day(
      { "missing" => [] },
      date: Date.new(2026, 10, 11)
    )
    history = load_achievement_history
    history["earned_badges"] = { "on_time-5" => "2026-10-11" }
    save_achievement_history(history)
    save_achievement_settings(
      85,
      school_day_overrides: { "2026-10-16" => "no_school", "2026-10-17" => "school" }
    )

    archive = build_backup_archive(
      now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    )

    save_manual_coursework(empty_manual_coursework)
    save_grade_overrides("canvas" => {}, "custom" => {})
    save_course_name_mappings({})
    save_hidden_course_ids([])
    save_school_calendar_settings("")
    save_scheduled_email_settings(empty_scheduled_email_settings)
    $dashboard_data = base_data
    $event_journal = { "next_id" => 1, "events" => [] }
    FileUtils.rm_f(ACHIEVEMENT_HISTORY_FILE)
    FileUtils.rm_f(ACHIEVEMENT_SETTINGS_FILE)

    restored = restore_backup_archive(archive)

    assert_includes restored, "school_calendar_settings.json"
    assert_includes restored, "achievement_history.json"
    assert_includes restored, "achievement_settings.json"
    assert_equal "Music", load_manual_coursework.dig(
      "courses",
      "music",
      "name"
    )
    assert_equal "Algebra", load_course_name_mappings["1"]
    assert_equal ["2"], load_hidden_course_ids
    assert_equal(
      "https://calendar.example.test/school.ics",
      load_school_calendar_settings["feed_url"]
    )
    assert_equal(
      ["Elementary"],
      load_school_calendar_settings["excluded_keywords"]
    )
    assert_equal(
      ["backup@example.com"],
      load_scheduled_email_settings["backup_recipients"]
    )
    assert_equal 2, $event_journal["next_id"]
    assert_equal(
      0,
      load_achievement_history.dig(
        "daily_missing_counts",
        "2026-10-11"
      )
    )
    assert_equal 85,
      load_achievement_settings["strong_score_threshold"]
    assert_equal(
      { "on_time-5" => "2026-10-11" },
      load_achievement_history["earned_badges"]
    )
    assert_equal(
      { "2026-10-16" => "no_school", "2026-10-17" => "school" },
      load_achievement_settings["school_day_overrides"]
    )
    assert_equal "2026-10-11T03:00:00-07:00",
      $dashboard_data["updated_at"]
  end

  def test_backup_validates_school_day_overrides_and_accepts_legacy_settings
    assert_raises(BackupRestoreError) do
      validate_backup_json(
        "achievement_settings.json",
        empty_achievement_settings.merge("school_day_overrides" => { "2026-10-16" => "maybe" })
      )
    end
    assert_raises(BackupRestoreError) do
      validate_backup_json(
        "achievement_settings.json",
        empty_achievement_settings.merge("school_day_overrides" => [])
      )
    end
    validate_backup_json("achievement_settings.json", { "strong_score_threshold" => 80 })
  end

  def test_backup_restore_rejects_checksum_mismatch
    entries = backup_archive_entries(build_backup_archive)
    entries["manual_coursework.json"] = backup_json(
      "courses" => { "changed" => { "name" => "Changed" } },
      "assignments" => {}
    )

    error = assert_raises(BackupRestoreError) do
      restore_backup_archive(backup_archive_from_entries(entries))
    end

    assert_includes error.message, "verification failed"
  end

  def test_backup_restores_spark_chat_and_research_without_school_context
    conversation, turn = spark_begin_turn("Explain geography", web_search: true)
    spark_update_turn(conversation["id"], turn["id"], search: {
      "query" => "geography study", "sources" => [{
        "id" => 1, "title" => "Geography", "url" => "https://example.com/geography", "text" => "Geography studies places."
      }]
    })
    spark_update_turn(conversation["id"], turn["id"], status: "completed", answer: "Study places [1].")
    original = spark_conversation(conversation["id"])
    archive = build_backup_archive
    history = JSON.parse(backup_archive_entries(archive).fetch("spark_history.json"))
    refute history.key?("contexts")
    assert history["conversations"].values.none? { |saved| saved.key?("contexts") }
    assert history["conversations"].values.flat_map { |saved| saved["turns"] }.none? { |saved| saved.key?("context_id") }
    spark_delete_conversation(conversation["id"])
    assert_empty spark_conversation_list
    assert_includes restore_backup_archive(archive), "spark_history.json"
    assert_equal original, spark_conversation(conversation["id"])
  end

  def test_backup_refuses_history_that_would_exceed_restore_limits
    oversized = "x" * (BACKUP_MAX_ENTRY_BYTES + 1)
    with_replaced_method(self, :backup_payloads, ->(**) { { "spark_history.json" => oversized } }) do
      error = assert_raises(BackupRestoreError) { build_backup_archive }
      assert_includes error.message, "spark_history.json"
      assert_includes error.message, "10 MB"
    end
  end

  def test_restored_in_progress_answers_are_interrupted_and_active_restore_is_blocked
    conversation, turn = spark_begin_turn("Explain geography", web_search: false)
    archive = build_backup_archive
    assert_raises(BackupRestoreError) { restore_backup_archive(archive) }
    spark_update_turn(conversation["id"], turn["id"], status: "interrupted")
    restore_backup_archive(archive)
    saved = spark_conversation(conversation["id"])["turns"].first
    assert_equal "interrupted", saved["status"]
    assert_includes saved["error"], "backup was created before"
    assert_raises(BackupRestoreError) do
      validate_backup_json("spark_history.json", "conversations" => { "../bad" => {} })
    end
  end

  def test_schema_three_restore_preserves_existing_spark_history
    conversation, turn = spark_begin_turn("Keep this conversation", web_search: false)
    spark_update_turn(conversation["id"], turn["id"], status: "completed", answer: "Keep this answer")
    entries = backup_archive_entries(build_backup_archive)
    entries.delete("spark_history.json")
    manifest = JSON.parse(entries["manifest.json"])
    manifest["schema_version"] = 3
    manifest["files"].delete("spark_history.json")
    entries["manifest.json"] = backup_json(manifest)
    restored = restore_backup_archive(backup_archive_from_entries(entries))
    refute_includes restored, "spark_history.json"
    assert_equal "Keep this answer", spark_conversation(conversation["id"])["turns"].first["answer"]
  end

  def test_backup_restore_accepts_schema_one_without_calendar_settings
    entries = backup_archive_entries(build_backup_archive)
    entries.delete("school_calendar_settings.json")
    entries.delete("achievement_history.json")
    entries.delete("achievement_settings.json")
    entries.delete("spark_history.json")
    manifest = JSON.parse(entries["manifest.json"])
    manifest["schema_version"] = 1
    manifest["files"].delete("school_calendar_settings.json")
    manifest["files"].delete("achievement_history.json")
    manifest["files"].delete("achievement_settings.json")
    manifest["files"].delete("spark_history.json")
    entries["manifest.json"] = backup_json(manifest)
    save_school_calendar_settings(
      "https://calendar.example.test/current.ics"
    )

    restored = restore_backup_archive(
      backup_archive_from_entries(entries)
    )

    refute_includes restored, "school_calendar_settings.json"
    assert_equal(
      "https://calendar.example.test/current.ics",
      load_school_calendar_settings["feed_url"]
    )
  end

  def test_backup_restore_accepts_schema_two_without_achievement_history
    entries = backup_archive_entries(build_backup_archive)
    entries.delete("achievement_history.json")
    entries.delete("achievement_settings.json")
    entries.delete("spark_history.json")
    manifest = JSON.parse(entries["manifest.json"])
    manifest["schema_version"] = 2
    manifest["files"].delete("achievement_history.json")
    manifest["files"].delete("achievement_settings.json")
    manifest["files"].delete("spark_history.json")
    entries["manifest.json"] = backup_json(manifest)
    record_achievement_day(
      { "missing" => [] },
      date: Date.new(2026, 10, 10)
    )
    save_achievement_settings(85)

    restored = restore_backup_archive(
      backup_archive_from_entries(entries)
    )

    refute_includes restored, "achievement_history.json"
    assert_equal(
      0,
      load_achievement_history.dig(
        "daily_missing_counts",
        "2026-10-10"
      )
    )
    assert_equal 85,
      load_achievement_settings["strong_score_threshold"]
  end

  def test_backup_restore_rejects_secret_files
    entries = backup_archive_entries(build_backup_archive)
    entries["options.json"] = JSON.generate("canvas_token" => "secret")

    error = assert_raises(BackupRestoreError) do
      restore_backup_archive(backup_archive_from_entries(entries))
    end

    assert_includes error.message, "unsupported file"
  end

  def test_backup_email_has_requested_subject_and_only_attachment
    now = Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
    message = backup_email_message(
      sender: "sender@gmail.com",
      recipient: "parent@example.com",
      archive: "zip contents",
      filename: "backup.zip",
      now: now
    )

    assert_includes message, "Subject: EmberGuide Backup for October 11, 2026"
    assert_includes message, "Content-Disposition: attachment; filename=\"backup.zip\""
    refute_includes message, "Content-Type: text/plain"
  end

  def test_backup_archive_filename_uses_timestamp
    now = Time.new(2026, 10, 11, 20, 8, 9, "-07:00")

    assert_equal(
      "emberguide-backup-2026-10-11-200809.zip",
      backup_archive_filename(now)
    )
  end

  def test_backup_sends_separate_messages_to_multiple_recipients
    configure_gmail
    delivery = nil

    with_replaced_method(
      self,
      :deliver_email_messages,
      ->(**arguments) { delivery = arguments }
    ) do
      send_emberguide_backup(
        ["one@example.com", "two@example.com"],
        now: Time.new(2026, 10, 11, 3, 0, 0, "-07:00")
      )
    end

    assert_equal %w[one@example.com two@example.com],
      delivery[:messages].map { |message| message[:recipient] }
    delivery[:messages].each do |message|
      refute_includes message[:message], "two@example.com" if
        message[:recipient] == "one@example.com"
    end
  end

  def test_restore_discards_derived_overview_but_keeps_the_opt_in_preference
    now = Time.local(2026, 10, 26, 5)
    save_scheduled_email_settings(scheduled_settings("digest_spark_overview" => true))
    with_replaced_method(self, :digest_spark_overview, ->(*) { { "bullets" => ["Check the Math notes."] } }) do
      assert generate_daily_overview(now: now)
    end
    archive = build_backup_archive(now: now)
    assert daily_overview_for_digest(now: now)["bullets"]
    restore_backup_archive(archive)
    refute File.exist?(DAILY_OVERVIEW_FILE)
    assert load_scheduled_email_settings["digest_spark_overview"]
    assert daily_overview_for_digest(now: now)["error"]
  end

  def test_digest_contains_snapshot_missing_due_work_and_recent_grades
    now = Time.new(2026, 10, 11, 6, 0, 0, "-07:00")
    $dashboard_data["grades"] = [
      graded_submission(10, 1, "Quiz", 9, 10, "2026-10-08T12:00:00-07:00"),
      graded_submission(20, 2, "Lab", 10, 10, "2026-10-10T12:00:00-07:00"),
      graded_submission(21, 2, "Old Lab", 10, 10, "2026-10-01T12:00:00-07:00")
    ]
    $dashboard_data["missing"] = [
      assignment(30, 1, "Missing Worksheet", "2026-10-09T15:00:00-07:00")
    ]
    $dashboard_data["upcoming"] = [
      assignment(31, 1, "Today Homework", "2026-10-11T15:00:00-07:00"),
      assignment(32, 2, "Tomorrow Project", "2026-10-12T16:00:00-07:00")
    ]
    feed_url = "https://calendar.example.test/events.ics"
    save_school_calendar_settings(feed_url, "Elementary")
    $school_calendar_cache = {
      feed_url: feed_url,
      fetched_at: now,
      events: [
        {
          "title" => "Middle School Modified Day",
          "description" => "",
          "location" => "Middle schools",
          "start_date" => Date.new(2026, 10, 15),
          "end_date" => Date.new(2026, 10, 15)
        },
        {
          "title" => "Elementary Modified Day",
          "description" => "",
          "location" => "",
          "start_date" => Date.new(2026, 10, 16),
          "end_date" => Date.new(2026, 10, 16)
        }
      ]
    }

    digest = digest_data(now: now)
    html = digest_html_body(digest, now)
    text = digest_text_body(digest, now)

    assert_equal %w[Science Math], digest["grade_snapshot"].map { |grade| grade["name"] }
    assert_includes html, "Daily Digest"
    assert_includes html, "Avery &middot; October 11, 2026"
    assert_includes html, ">EmberGuide</td>"
    assert_includes text, "Daily Digest for Avery for October 11, 2026"
    assert_includes html, "Current Grade Snapshot"
    assert_includes html, '<meta name="viewport" content="width=device-width, initial-scale=1">'
    assert_includes html, "@media only screen and (max-width: 600px)"
    assert_includes html, 'class="grade-card-cell"'
    assert_includes html, "background:#080711"
    assert_includes html, "background:#11221f"
    assert_includes html, "background:#4fd6a0"
    assert_includes html, "Missing Worksheet"
    assert_includes html,
      'href="https://temecula.instructure.com/courses/1/assignments/30"'
    assert_includes html, "Friday, October 9"
    assert_includes html, "Today Homework"
    assert_includes html, "Tomorrow Project"
    assert_includes html, "Upcoming Schedule Changes"
    assert_includes html, "Middle School Modified Day"
    assert_includes html, "Middle schools"
    refute_includes html, "Elementary Modified Day"
    assert_operator html.index("Lab"), :<, html.index("Quiz")
    assert_includes html,
      'href="https://temecula.instructure.com/courses/2/assignments/20"'
    refute_includes html, "Old Lab"
    assert_includes text, "MISSING WORK"
    assert_includes text,
      "https://temecula.instructure.com/courses/1/assignments/30"
    assert_includes text, "UPCOMING SCHEDULE CHANGES"
    assert_includes text, "Middle School Modified Day - Thursday, October 15"
    assert_includes text,
      "https://temecula.instructure.com/courses/2/assignments/20"
    refute_includes text, "Elementary Modified Day"
    assert_includes text, "GRADES POSTED IN THE LAST 7 DAYS"
  end

  def test_digest_excludes_hidden_assignments_and_their_points
    now = Time.local(2026, 10, 14, 9)
    hidden_assignment = {
      "id" => 10, "course_id" => 1, "name" => "Premature Grade",
      "points_possible" => 100,
      "due_at" => Time.local(2026, 10, 14, 12).iso8601
    }
    $dashboard_data["grades"] = [
      { "assignment_id" => 10, "score" => 0,
        "graded_at" => now.iso8601, "assignment" => hidden_assignment },
      { "assignment_id" => 11, "score" => 9,
        "graded_at" => now.iso8601,
        "assignment" => { "id" => 11, "course_id" => 1,
                          "name" => "Real Grade", "points_possible" => 10 } }
    ]
    $dashboard_data["missing"] = [hidden_assignment]
    $dashboard_data["upcoming"] = [{ "assignment" => hidden_assignment }]
    original = deep_copy($dashboard_data)
    save_grade_overrides("canvas" => { "10" => { "hidden" => true } })

    digest = digest_data(now: now)

    assert_equal [90], digest["grade_snapshot"].map { |grade| grade["percentage"] }
    assert_equal [11], digest["recent_grades"].map { |grade| grade["assignment_id"] }
    assert_empty digest["missing"]
    assert_empty digest["due_today"]
    assert_empty digest["due_tomorrow"]
    refute_includes digest_html_body(digest, now), "Premature Grade"
    refute_includes digest_text_body(digest, now), "Premature Grade"
    assert_equal original, dashboard_data
  end

  def test_digest_grade_colors_match_dashboard_grade_palette
    assert_equal(
      { foreground: "#4fd6a0", background: "#11221f", border: "#285746" },
      digest_grade_colors("A")
    )
    assert_equal(
      { foreground: "#58a6ff", background: "#101d2d", border: "#284f78" },
      digest_grade_colors("B")
    )
    assert_equal(
      { foreground: "#ff7085", background: "#251319", border: "#6d2f3a" },
      digest_grade_colors("F")
    )
  end

  def test_recent_grade_colors_highlight_low_and_perfect_scores
    assert_equal(
      {
        foreground: "#ff7085",
        background: "#251319",
        border: "#6d2f3a"
      },
      digest_recent_grade_colors(6, 10)
    )
    assert_equal(
      {
        foreground: "#ffc96b",
        background: "#211c14",
        border: "#64502b"
      },
      digest_recent_grade_colors(10, 10)
    )
    assert_equal(
      {
        foreground: "#f4f2ff",
        background: "#121020",
        border: "#29263d"
      },
      digest_recent_grade_colors(9, 10)
    )
  end

  def test_digest_sends_separate_html_messages_to_all_recipients
    configure_gmail
    delivery = nil

    with_replaced_method(
      self,
      :deliver_email_messages,
      ->(**arguments) { delivery = arguments }
    ) do
      count = send_emberguide_digest(
        ["one@example.com", "two@example.com"],
        now: Time.new(2026, 10, 11, 6, 0, 0, "-07:00")
      )
      assert_equal 2, count
    end

    assert_equal %w[one@example.com two@example.com],
      delivery[:messages].map { |message| message[:recipient] }
    assert_includes delivery[:messages].first[:message], "multipart/alternative"
    assert_includes delivery[:messages].first[:message], "multipart/related"
    assert_includes delivery[:messages].first[:message],
      "Content-ID: <emberguide-logo>"
    assert_includes delivery[:messages].first[:message],
      "Subject: Avery's EmberGuide Daily Digest"
  end

  def test_digest_delivery_uses_one_cached_overview_for_all_recipients_without_ai
    configure_gmail
    now = Time.local(2026, 10, 26, 6)
    save_scheduled_email_settings(scheduled_settings("digest_spark_overview" => true))
    with_replaced_method(self, :digest_spark_overview, ->(*) { { "bullets" => ["Check your Math notes."] } }) do
      assert generate_daily_overview(now: now - 3600)
    end
    with_replaced_method(self, :ai_ask, ->(*) { flunk "Delivery invoked AI" }) do
      delivery = lambda do |**options|
        assert_equal 2, options[:messages].length
        options[:messages].each do |message|
          assert_includes message[:message], "Check your Math notes."
          assert_includes message[:message], "TODAY AT A GLANCE"
          assert_includes message[:message], "Today at a glance"
        end
      end
      with_replaced_method(self, :deliver_email_messages, delivery) do
        assert_equal 2, send_emberguide_digest(["one@example.com", "two@example.com"], now: now)
      end
      FileUtils.rm_f(DAILY_OVERVIEW_FILE)
      with_replaced_method(self, :deliver_email_messages, ->(**options) {
        assert_includes options[:messages].first[:message], "Today's Spark overview is not ready"
        assert_includes options[:messages].first[:message], "CURRENT GRADES"
      }) do
        assert_equal 1, send_emberguide_digest(["one@example.com"], now: now)
      end
    end
  end

  def test_backup_and_digest_run_once_at_their_scheduled_hours
    settings = scheduled_settings(
      "backup_recipients" => ["backup@example.com"],
      "backup_daily_enabled" => true,
      "digest_recipients" => ["digest@example.com"],
      "digest_daily_enabled" => true
    )
    save_scheduled_email_settings(settings)
    sends = []

    with_replaced_method(
      self,
      :send_emberguide_backup,
      ->(recipients, now:) { sends << [:backup, recipients, now.hour] }
    ) do
      with_replaced_method(
        self,
        :send_emberguide_digest,
        ->(recipients, now:) { sends << [:digest, recipients, now.hour] }
      ) do
        at_three = Time.new(2026, 10, 11, 3, 5, 0, "-07:00")
        at_six = Time.new(2026, 10, 11, 6, 5, 0, "-07:00")

        assert send_scheduled_email_if_due(:backup, at_three)
        refute send_scheduled_email_if_due(:backup, at_three + 60)
        assert send_scheduled_email_if_due(:digest, at_six)
        refute send_scheduled_email_if_due(:digest, at_six + 60)
      end
    end

    assert_equal [
      [:backup, ["backup@example.com"], 3],
      [:digest, ["digest@example.com"], 6]
    ], sends
  end

  def test_failed_schedule_is_not_retried_every_minute
    save_scheduled_email_settings(
      scheduled_settings(
        "digest_recipients" => ["digest@example.com"],
        "digest_daily_enabled" => true
      )
    )
    attempts = 0
    now = Time.new(2026, 10, 11, 6, 5, 0, "-07:00")

    with_replaced_method(
      self,
      :send_emberguide_digest,
      lambda do |_recipients, now:|
        attempts += 1
        raise "SMTP unavailable"
      end
    ) do
      capture_io do
        refute send_scheduled_email_if_due(:digest, now)
        refute send_scheduled_email_if_due(:digest, now + 60)
      end
    end

    assert_equal 1, attempts
    assert_nil load_scheduled_email_settings["last_digest_sent_on"]
  end

  private

  def configure_gmail
    ENV["GMAIL_SENDER"] = "sender@gmail.com"
    ENV["GMAIL_APP_PASSWORD"] = "abcd efgh ijkl mnop"
  end

  def graded_submission(id, course_id, name, score, possible, graded_at)
    {
      "assignment_id" => id,
      "score" => score,
      "graded_at" => graded_at,
      "assignment" => {
        "id" => id,
        "course_id" => course_id,
        "name" => name,
        "html_url" => "/courses/#{course_id}/assignments/#{id}",
        "points_possible" => possible
      }
    }
  end

  def assignment(id, course_id, name, due_at)
    {
      "assignment" => {
        "id" => id,
        "course_id" => course_id,
        "name" => name,
        "html_url" => "/courses/#{course_id}/assignments/#{id}",
        "due_at" => due_at
      }
    }
  end

  def backup_archive_entries(archive)
    Zip::File.open_buffer(archive).to_h do |entry|
      [entry.name, entry.get_input_stream.read]
    end
  end

  def backup_archive_from_entries(entries)
    Zip::OutputStream.write_buffer do |archive|
      entries.each do |filename, content|
        archive.put_next_entry(filename)
        archive.write(content)
      end
    end.string
  end
end
