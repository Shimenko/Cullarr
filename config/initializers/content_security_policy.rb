Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.object_src :none
    policy.frame_ancestors :none
    policy.form_action :self
    policy.font_src :self, :https, :data
    policy.img_src :self, :https, :data, :blob
    policy.script_src :self, :https
    policy.style_src :self, :https
    policy.connect_src :self, :https, :wss, :ws
    policy.upgrade_insecure_requests if Rails.env.production?
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
