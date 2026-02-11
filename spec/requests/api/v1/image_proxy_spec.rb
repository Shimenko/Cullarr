require "rails_helper"

RSpec.describe "Api::V1::ImageProxy", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  def request_image(url)
    get "/api/v1/image-proxy", params: { url: url }, as: :json
  end

  def stub_proxy_result(result)
    proxy_service = instance_double(Images::ProxyFetch, call: result)
    allow(Images::ProxyFetch).to receive(:new).and_return(proxy_service)
  end

  def stub_proxy_error(code:, message:)
    proxy_service = instance_double(Images::ProxyFetch)
    allow(proxy_service).to receive(:call).and_raise(
      Images::ProxyFetch::ProxyError.new(code: code, message: message, status: :unprocessable_content)
    )
    allow(Images::ProxyFetch).to receive(:new).and_return(proxy_service)
  end

  describe "GET /api/v1/image-proxy" do
    it "requires authentication" do
      request_image("https://img.local/poster.jpg")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "streams image data when proxy fetch succeeds" do
      sign_in_operator!
      Integration.create!(kind: "tautulli", name: "Tautulli Main", base_url: "https://tautulli.local", api_key: "api-key")
      stub_proxy_result(Images::ProxyFetch::Result.new(body: "PNGDATA", content_type: "image/png", source_url: "https://tautulli.local/poster.png"))

      request_image("https://tautulli.local/poster.png")

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body).to eq("PNGDATA")
      expect(Images::ProxyFetch).to have_received(:new).with(hash_including(url: "https://tautulli.local/poster.png"))
    end

    it "returns image_proxy_disallowed_host when source host is blocked" do
      sign_in_operator!
      stub_proxy_error(code: "image_proxy_disallowed_host", message: "Image source host is not allowlisted.")

      request_image("https://blocked.local/poster.png")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("image_proxy_disallowed_host")
    end

    it "returns image_proxy_redirect_blocked when redirect target is blocked" do
      sign_in_operator!
      stub_proxy_error(code: "image_proxy_redirect_blocked", message: "Image redirect target host is not allowlisted.")

      request_image("https://allowed.local/poster.png")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("image_proxy_redirect_blocked")
    end
  end
end
