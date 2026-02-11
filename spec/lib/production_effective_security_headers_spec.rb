require "rails_helper"
require "json"
require "open3"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Production effective security headers" do
  let(:header_line_prefix) { "CULLARR_HEADERS_JSON=" }

  # rubocop:disable RSpec/ExampleLength
  it "boots production and exposes hardened default headers" do
    runner_script = <<~RUBY
      headers = Rails.application.config.action_dispatch.default_headers.slice(
        "X-Frame-Options",
        "X-Content-Type-Options",
        "Referrer-Policy"
      )
      puts "#{header_line_prefix}\#{headers.to_json}"
    RUBY

    stdout, stderr, status = Open3.capture3(
      { "SECRET_KEY_BASE" => "test-secret-key-base-#{SecureRandom.hex(64)}" },
      "bin/rails",
      "runner",
      "-e",
      "production",
      runner_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), <<~MSG
      expected production runner to succeed
      stdout: #{stdout}
      stderr: #{stderr}
    MSG

    headers_line = stdout.lines.find { |line| line.start_with?(header_line_prefix) }
    expect(headers_line).to be_present, <<~MSG
      expected headers line in output
      stdout: #{stdout}
      stderr: #{stderr}
    MSG

    headers = JSON.parse(headers_line.delete_prefix(header_line_prefix))
    expect(headers).to eq(
      "X-Frame-Options" => "DENY",
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy" => "strict-origin-when-cross-origin"
    )
  end
  # rubocop:enable RSpec/ExampleLength
end
# rubocop:enable RSpec/DescribeClass
