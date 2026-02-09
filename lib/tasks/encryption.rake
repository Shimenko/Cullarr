namespace :cullarr do
  namespace :encryption do
    desc "Re-encrypt integration API keys with the active Active Record encryption key"
    task rotate_integration_api_keys: :environment do
      rotated = 0
      skipped = 0

      Integration.find_each do |integration|
        if integration.rotate_api_key_ciphertext!
          rotated += 1
        else
          skipped += 1
        end
      end

      puts "Integration API key rotation complete. Rotated: #{rotated}, skipped: #{skipped}."
    end
  end
end
