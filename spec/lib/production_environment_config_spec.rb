require "rails_helper"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Production environment config" do
  subject(:production_source) { Rails.root.join("config/environments/production.rb").read }

  it "sets hardened security headers in default headers" do
    expect(production_source).to match(/"X-Frame-Options"\s*=>\s*"DENY"/)
    expect(production_source).to match(/"X-Content-Type-Options"\s*=>\s*"nosniff"/)
    expect(production_source).to match(/"Referrer-Policy"\s*=>\s*"strict-origin-when-cross-origin"/)
  end
end
# rubocop:enable RSpec/DescribeClass
