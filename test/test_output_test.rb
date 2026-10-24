require "open3"
require "rbconfig"
require_relative "test_helper"

class TestOutputTest < Minitest::Test
  def fixture_run(failing: false, verbose: false)
    script = <<~RUBY
      require "test_helper"
      class OutputFixtureTest < Minitest::Test
        def test_logging
          puts "fixture standard output"
          warn "fixture standard error"
          DASHBOARD_SERVER.logger.error("fixture server log")
          #{failing ? 'flunk "deliberate fixture failure"' : "assert true"}
        end
      end
    RUBY
    Open3.capture3(
      { "TEST_VERBOSE_LOGS" => verbose ? "1" : "0" },
      RbConfig.ruby, "-I", __dir__, "-e", script
    )
  end

  def test_success_is_quiet_while_failures_and_verbose_runs_keep_diagnostics
    output, errors, status = fixture_run
    assert status.success?, output + errors
    refute_match(/fixture standard|fixture server log|WEBrick/, output + errors)
    assert_includes output, "1 runs"
    output, errors, status = fixture_run(failing: true)
    refute status.success?
    %w[output error].each { |kind| assert_includes output + errors, "fixture standard #{kind}" }
    assert_includes output + errors, "fixture server log"
    assert_includes output + errors, "deliberate fixture failure"
    output, errors, status = fixture_run(verbose: true)
    assert status.success?, output + errors
    assert_includes output + errors, "fixture standard output"
    assert_includes output + errors, "fixture standard error"
    assert_includes output + errors, "fixture server log"
  end
end
