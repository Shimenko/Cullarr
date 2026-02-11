Rails.application.config.after_initialize do
  next if Rails.env.test?
  next if defined?(Rails::Console)
  next if ENV["DISABLE_SYNC_STARTUP_RECOVERY"] == "1"

  command = ARGV.first.to_s
  executable = File.basename($PROGRAM_NAME)
  boot_process = defined?(Rails::Server) || command.in?(%w[server start]) || executable == "jobs"
  next unless boot_process

  Sync::RecoverStaleRuns.new(
    correlation_id: "startup-#{SecureRandom.uuid}",
    actor: nil,
    enqueue_replacement: true
  ).call
rescue StandardError => error
  Rails.logger.warn("sync_startup_recovery_failed class=#{error.class} message=#{error.message}")
end
