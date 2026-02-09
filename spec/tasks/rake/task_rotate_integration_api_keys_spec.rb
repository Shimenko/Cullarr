require "rails_helper"
require "base64"
require "rake"
require "securerandom"

RSpec.describe Rake::Task do
  let(:task_name) { "cullarr:encryption:rotate_integration_api_keys" }

  def random_encryption_key
    Base64.strict_encode64(SecureRandom.random_bytes(32))
  end

  def rotation_task
    Rake::Task[task_name]
  end

  before do
    Rails.application.load_tasks unless described_class.task_defined?(task_name)
    rotation_task.reenable
  end

  it "re-encrypts integration api keys with the active primary key" do
    old_key = random_encryption_key
    new_key = random_encryption_key

    integration, old_ciphertext = create_integration_with_key(old_key)
    rotate_with_key_ring(old_key, new_key)

    integration.reload
    expect(integration.api_key).to eq("rotate-with-task")
    expect(integration.read_attribute_before_type_cast("api_key_ciphertext")).not_to eq(old_ciphertext)
  end

  def create_integration_api_key!(api_key:)
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Task Rotation",
      base_url: "https://sonarr.task-rotation.local",
      api_key:,
      verify_ssl: true
    )
  end

  def create_integration_with_key(old_key)
    with_primary_key_ring([ old_key ]) do
      integration = create_integration_api_key!(api_key: "rotate-with-task")
      old_ciphertext = integration.read_attribute_before_type_cast("api_key_ciphertext")
      [ integration, old_ciphertext ]
    end
  end

  def rotate_with_key_ring(old_key, new_key)
    with_primary_key_ring([ old_key, new_key ]) do
      rotation_task.invoke
    end
  end

  def with_primary_key_ring(keys)
    original_primary_keys = ActiveRecord::Encryption.config.primary_key
    ActiveRecord::Encryption.config.primary_key = keys
    yield
  ensure
    ActiveRecord::Encryption.config.primary_key = original_primary_keys
  end
end
