require "rails_helper"

RSpec.describe ActiveRecordEncryptionConfig do
  describe ".resolve_keys" do
    it "accepts a primary key ring from env" do
      keys = described_class.resolve_keys(
        env: {
          "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS" => "old-key,new-key",
          "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "det-key",
          "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt-key"
        }
      )

      expect(keys).to eq([ [ "old-key", "new-key" ], "det-key", "salt-key" ])
    end

    it "raises in production when keys are missing" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect do
        described_class.resolve_keys(env: {})
      end.to raise_error(ArgumentError, /ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS/)
    end

    it "uses deterministic fallback keys in non-production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

      primary_keys, deterministic_key, key_derivation_salt = described_class.resolve_keys(env: {})

      expect(primary_keys.size).to eq(1)
      expect(primary_keys.first).to be_present
      expect(deterministic_key).to be_present
      expect(key_derivation_salt).to be_present
    end
  end
end
