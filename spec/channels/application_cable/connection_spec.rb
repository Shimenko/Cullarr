require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  it "connects when a valid signed operator cookie is present" do
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    cookies.signed[ApplicationCable::Connection::CABLE_OPERATOR_COOKIE] = operator.id

    connect

    expect(connection.current_operator).to eq(operator)
  end

  it "rejects connection when cable auth cookie is missing" do
    expect { connect }.to have_rejected_connection
  end

  it "rejects connection when cable auth cookie references a stale operator id" do
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    stale_operator_id = operator.id
    operator.destroy!
    cookies.signed[ApplicationCable::Connection::CABLE_OPERATOR_COOKIE] = stale_operator_id

    expect { connect }.to have_rejected_connection
  end
end
