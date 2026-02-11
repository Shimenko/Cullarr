require "spec_helper"
require "open3"
require "tmpdir"

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe "bin/dev-tailnet" do
  let(:script_path) { File.expand_path("../../bin/dev-tailnet", __dir__) }

  it "configures tailscale serve and forwards the tailnet host to Rails host allowlist" do
    Dir.mktmpdir("dev-tailnet-script-spec") do |tmp_dir|
      tailscale_path = File.join(tmp_dir, "tailscale")
      dev_command_path = File.join(tmp_dir, "fake-dev-command")
      tailscale_log_path = File.join(tmp_dir, "tailscale.log")
      env_log_path = File.join(tmp_dir, "env.log")

      File.write(
        tailscale_path,
        <<~SH
          #!/usr/bin/env sh
          set -eu

          case "$1" in
            status)
              if [ "$2" != "--json" ]; then
                echo "unexpected args for status: $*" >&2
                exit 1
              fi
              printf '%s\n' '{"Self":{"DNSName":"cullarr-dev.tailnet123.ts.net."}}'
              ;;
            serve)
              printf '%s\\n' "$*" >> "#{tailscale_log_path}"
              ;;
            *)
              echo "unexpected command: $*" >&2
              exit 1
              ;;
          esac
        SH
      )
      File.write(
        dev_command_path,
        <<~SH
          #!/usr/bin/env sh
          set -eu
          {
            echo "$RAILS_DEVELOPMENT_HOSTS"
            echo "$PORT"
          } > "#{env_log_path}"
        SH
      )
      File.chmod(0o755, tailscale_path)
      File.chmod(0o755, dev_command_path)

      stdout, stderr, status = Open3.capture3(
        {
          "TAILSCALE_BIN" => tailscale_path,
          "CULLARR_DEV_COMMAND" => dev_command_path,
          "PORT" => "4567"
        },
        script_path
      )

      expect(status.success?).to be(true), "stdout: #{stdout}\nstderr: #{stderr}"
      expect(File.read(tailscale_log_path)).to include("serve --yes --bg --https=443 http://127.0.0.1:4567")
      expect(File.read(env_log_path)).to eq("cullarr-dev.tailnet123.ts.net\n4567\n")
      expect(stdout).to include("Tailnet proxy configured: https://cullarr-dev.tailnet123.ts.net")
    end
  end

  it "fails fast when tailscale is unavailable" do
    _stdout, stderr, status = Open3.capture3(
      {
        "TAILSCALE_BIN" => "tailscale-missing-xyz",
        "CULLARR_DEV_COMMAND" => "true"
      },
      script_path
    )

    expect(status.success?).to be(false)
    expect(stderr).to include("tailscale CLI not found")
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
