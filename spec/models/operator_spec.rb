require "rails_helper"

RSpec.describe Operator, type: :model do
  it "normalizes email before validation" do
    operator = described_class.create!(
      email: " OWNER@EXAMPLE.COM ",
      password: "password123",
      password_confirmation: "password123"
    )

    expect(operator.email).to eq("owner@example.com")
  end

  it "enforces exactly one operator record" do
    described_class.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")
    second_operator = described_class.new(email: "owner2@example.com", password: "password123", password_confirmation: "password123")

    expect(second_operator).not_to be_valid
    expect(second_operator.errors[:base]).to include("Only one operator account is allowed")
  end
end
