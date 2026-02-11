require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Images::ProxyFetch do
  def build_response(code:, headers:, body:)
    Struct.new(:code, :headers, :body) do
      def [](key)
        headers[key] || headers[key.downcase]
      end
    end.new(code, headers, body)
  end

  def build_requester(responses)
    Class.new do
      def initialize(responses)
        @responses = responses
      end

      def get(uri:, timeout_seconds:)
        response = @responses.fetch(uri.to_s)
        response.respond_to?(:call) ? response.call(timeout_seconds) : response
      end
    end.new(responses)
  end

  def build_service(url:, responses:, allowed_host_patterns: [ "*.allowed.local", "allowed.local" ], max_bytes: 65_536)
    described_class.new(
      url: url,
      allowed_host_patterns: allowed_host_patterns,
      timeout_seconds: 10,
      max_bytes: max_bytes,
      requester: build_requester(responses)
    )
  end

  it "returns image payload for allowlisted hosts" do
    result = build_service(
      url: "https://img.allowed.local/poster.png",
      responses: {
        "https://img.allowed.local/poster.png" => build_response(
          code: "200", headers: { "content-type" => "image/png" }, body: "PNGDATA"
        )
      }
    ).call

    expect(result.content_type).to eq("image/png")
    expect(result.body).to eq("PNGDATA")
    expect(result.source_url).to eq("https://img.allowed.local/poster.png")
  end

  it "raises image_proxy_disallowed_host for blocked hosts" do
    service = build_service(
      url: "https://blocked.local/poster.png",
      allowed_host_patterns: [ "allowed.local" ],
      responses: {}
    )

    expect { service.call }.to raise_error(Images::ProxyFetch::ProxyError) do |error|
      expect(error.code).to eq("image_proxy_disallowed_host")
      expect(error.status).to eq(:unprocessable_content)
    end
  end

  it "blocks redirects to non-allowlisted hosts" do
    service = build_service(
      url: "https://allowed.local/poster.png",
      responses: {
        "https://allowed.local/poster.png" => build_response(
          code: "302", headers: { "location" => "https://blocked.local/poster.png" }, body: ""
        )
      }
    )

    expect { service.call }.to raise_error(Images::ProxyFetch::ProxyError) do |error|
      expect(error.code).to eq("image_proxy_redirect_blocked")
    end
  end

  it "follows allowlisted redirects" do
    result = build_service(
      url: "https://allowed.local/poster.png",
      responses: {
        "https://allowed.local/poster.png" => build_response(
          code: "302", headers: { "location" => "https://cdn.allowed.local/poster.png" }, body: ""
        ),
        "https://cdn.allowed.local/poster.png" => build_response(
          code: "200", headers: { "content-type" => "image/jpeg" }, body: "JPEGDATA"
        )
      }
    ).call

    expect(result.content_type).to eq("image/jpeg")
    expect(result.body).to eq("JPEGDATA")
    expect(result.source_url).to eq("https://cdn.allowed.local/poster.png")
  end

  it "rejects responses that exceed max byte limit" do
    service = build_service(
      url: "https://img.allowed.local/poster.png",
      max_bytes: 65_536,
      responses: {
        "https://img.allowed.local/poster.png" => build_response(
          code: "200", headers: { "content-type" => "image/png" }, body: "X" * 70_000
        )
      }
    )

    expect { service.call }.to raise_error(Images::ProxyFetch::ProxyError) do |error|
      expect(error.code).to eq("validation_failed")
    end
  end
end
# rubocop:enable RSpec/ExampleLength
