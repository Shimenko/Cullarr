# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_02_08_222435) do
  create_table "app_settings", force: :cascade do |t|
    t.string "key", null: false
    t.json "value_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_app_settings_on_key", unique: true
  end

  create_table "arr_tags", force: :cascade do |t|
    t.integer "integration_id", null: false
    t.string "name", null: false
    t.integer "arr_tag_id", limit: 8, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[integration_id arr_tag_id], name: "index_arr_tags_on_integration_id_and_arr_tag_id", unique: true
    t.index %w[integration_id name], name: "index_arr_tags_on_integration_id_and_name", unique: true
    t.index ["integration_id"], name: "index_arr_tags_on_integration_id"
  end

  create_table "audit_events", force: :cascade do |t|
    t.integer "operator_id"
    t.string "event_name", null: false
    t.string "subject_type"
    t.integer "subject_id", limit: 8
    t.string "correlation_id"
    t.json "payload_json", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["correlation_id"], name: "index_audit_events_on_correlation_id"
    t.index ["event_name"], name: "index_audit_events_on_event_name"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
    t.index ["operator_id"], name: "index_audit_events_on_operator_id"
    t.index %w[subject_type subject_id], name: "index_audit_events_on_subject_type_and_subject_id"
  end

  create_table "delete_mode_unlocks", force: :cascade do |t|
    t.integer "operator_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_delete_mode_unlocks_on_expires_at"
    t.index ["operator_id"], name: "index_delete_mode_unlocks_on_operator_id"
    t.index ["token_digest"], name: "index_delete_mode_unlocks_on_token_digest", unique: true
  end

  create_table "deletion_actions", force: :cascade do |t|
    t.integer "deletion_run_id", null: false
    t.integer "media_file_id", null: false
    t.integer "integration_id", null: false
    t.string "idempotency_key", null: false
    t.string "status", null: false
    t.integer "retry_count", default: 0, null: false
    t.string "error_code"
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.json "stage_timestamps_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[deletion_run_id media_file_id], name: "index_deletion_actions_on_deletion_run_id_and_media_file_id", unique: true
    t.index ["deletion_run_id"], name: "index_deletion_actions_on_deletion_run_id"
    t.index ["finished_at"], name: "index_deletion_actions_on_finished_at"
    t.index %w[integration_id idempotency_key], name: "index_deletion_actions_on_integration_id_and_idempotency_key", unique: true
    t.index ["integration_id"], name: "index_deletion_actions_on_integration_id"
    t.index ["media_file_id"], name: "index_deletion_actions_on_media_file_id"
    t.index ["status"], name: "index_deletion_actions_on_status"
  end

  create_table "deletion_runs", force: :cascade do |t|
    t.integer "operator_id", null: false
    t.string "status", null: false
    t.string "scope", null: false
    t.json "selected_plex_user_ids_json", default: [], null: false
    t.json "summary_json", default: {}, null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.string "error_code"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["operator_id"], name: "index_deletion_runs_on_operator_id"
    t.index ["scope"], name: "index_deletion_runs_on_scope"
    t.index ["started_at"], name: "index_deletion_runs_on_started_at"
    t.index ["status"], name: "index_deletion_runs_on_status"
  end

  create_table "episodes", force: :cascade do |t|
    t.integer "season_id", null: false
    t.integer "integration_id", null: false
    t.integer "sonarr_episode_id", limit: 8, null: false
    t.integer "episode_number", null: false
    t.string "title"
    t.date "air_date"
    t.integer "duration_ms", limit: 8
    t.integer "tvdb_id", limit: 8
    t.string "imdb_id"
    t.integer "tmdb_id", limit: 8
    t.string "plex_rating_key"
    t.string "plex_guid"
    t.json "metadata_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["duration_ms"], name: "index_episodes_on_duration_ms"
    t.index %w[integration_id sonarr_episode_id], name: "index_episodes_on_integration_id_and_sonarr_episode_id", unique: true
    t.index ["integration_id"], name: "index_episodes_on_integration_id"
    t.index ["plex_rating_key"], name: "index_episodes_on_plex_rating_key"
    t.index ["season_id"], name: "index_episodes_on_season_id"
  end

  create_table "integrations", force: :cascade do |t|
    t.string "kind", null: false
    t.string "name", null: false
    t.string "base_url", null: false
    t.text "api_key_ciphertext", null: false
    t.boolean "verify_ssl", default: true, null: false
    t.json "settings_json", default: {}, null: false
    t.string "status", default: "unknown", null: false
    t.datetime "last_checked_at"
    t.text "last_error"
    t.string "reported_version"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_integrations_on_kind"
    t.index ["name"], name: "index_integrations_on_name", unique: true
  end

  create_table "keep_markers", force: :cascade do |t|
    t.string "keepable_type", null: false
    t.integer "keepable_id", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[keepable_type keepable_id], name: "index_keep_markers_on_keepable"
    t.index %w[keepable_type keepable_id], name: "index_keep_markers_on_keepable_type_and_keepable_id", unique: true
  end

  create_table "media_files", force: :cascade do |t|
    t.string "attachable_type", null: false
    t.integer "attachable_id", null: false
    t.integer "integration_id", null: false
    t.integer "arr_file_id", limit: 8, null: false
    t.text "path", null: false
    t.text "path_canonical", null: false
    t.integer "size_bytes", limit: 8, null: false
    t.json "quality_json", default: {}, null: false
    t.datetime "culled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[attachable_type attachable_id], name: "index_media_files_on_attachable"
    t.index ["culled_at"], name: "index_media_files_on_culled_at"
    t.index %w[integration_id arr_file_id], name: "index_media_files_on_integration_id_and_arr_file_id", unique: true
    t.index ["integration_id"], name: "index_media_files_on_integration_id"
    t.index ["path_canonical"], name: "index_media_files_on_path_canonical"
    t.index ["size_bytes"], name: "index_media_files_on_size_bytes"
  end

  create_table "movies", force: :cascade do |t|
    t.integer "integration_id", null: false
    t.integer "radarr_movie_id", limit: 8, null: false
    t.string "title", null: false
    t.integer "year"
    t.integer "tmdb_id", limit: 8
    t.string "imdb_id"
    t.string "plex_rating_key"
    t.string "plex_guid"
    t.integer "duration_ms", limit: 8
    t.json "metadata_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[integration_id radarr_movie_id], name: "index_movies_on_integration_id_and_radarr_movie_id", unique: true
    t.index ["integration_id"], name: "index_movies_on_integration_id"
    t.index ["plex_rating_key"], name: "index_movies_on_plex_rating_key"
    t.index %w[title year], name: "index_movies_on_title_and_year"
    t.index ["tmdb_id"], name: "index_movies_on_tmdb_id"
  end

  create_table "operators", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "last_login_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_operators_on_email", unique: true
  end

  create_table "path_exclusions", force: :cascade do |t|
    t.string "name", null: false
    t.string "path_prefix", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_path_exclusions_on_enabled"
    t.index ["path_prefix"], name: "index_path_exclusions_on_path_prefix", unique: true
  end

  create_table "path_mappings", force: :cascade do |t|
    t.integer "integration_id", null: false
    t.string "from_prefix", null: false
    t.string "to_prefix", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[integration_id from_prefix to_prefix], name: "idx_on_integration_id_from_prefix_to_prefix_852ff14293", unique: true
    t.index ["integration_id"], name: "index_path_mappings_on_integration_id"
  end

  create_table "plex_users", force: :cascade do |t|
    t.integer "tautulli_user_id", limit: 8, null: false
    t.string "friendly_name", null: false
    t.boolean "is_hidden", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tautulli_user_id"], name: "index_plex_users_on_tautulli_user_id", unique: true
  end

  create_table "seasons", force: :cascade do |t|
    t.integer "series_id", null: false
    t.integer "season_number", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[series_id season_number], name: "index_seasons_on_series_id_and_season_number", unique: true
    t.index ["series_id"], name: "index_seasons_on_series_id"
  end

  create_table "series", force: :cascade do |t|
    t.integer "integration_id", null: false
    t.integer "sonarr_series_id", limit: 8, null: false
    t.string "title", null: false
    t.integer "year"
    t.integer "tvdb_id", limit: 8
    t.string "imdb_id"
    t.integer "tmdb_id", limit: 8
    t.string "plex_rating_key"
    t.string "plex_guid"
    t.json "metadata_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[integration_id sonarr_series_id], name: "index_series_on_integration_id_and_sonarr_series_id", unique: true
    t.index ["integration_id"], name: "index_series_on_integration_id"
    t.index %w[title year], name: "index_series_on_title_and_year"
    t.index ["tvdb_id"], name: "index_series_on_tvdb_id"
  end

  create_table "sync_runs", force: :cascade do |t|
    t.string "status", null: false
    t.string "trigger", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.string "phase"
    t.json "phase_counts_json", default: {}, null: false
    t.string "error_code"
    t.text "error_message"
    t.boolean "queued_next", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["finished_at"], name: "index_sync_runs_on_finished_at"
    t.index ["started_at"], name: "index_sync_runs_on_started_at"
    t.index ["status"], name: "index_sync_runs_on_status"
  end

  create_table "watch_stats", force: :cascade do |t|
    t.integer "plex_user_id", null: false
    t.string "watchable_type", null: false
    t.integer "watchable_id", null: false
    t.integer "play_count", default: 0, null: false
    t.datetime "last_watched_at"
    t.boolean "watched", default: false, null: false
    t.boolean "in_progress", default: false, null: false
    t.integer "max_view_offset_ms", limit: 8, default: 0, null: false
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["in_progress"], name: "index_watch_stats_on_in_progress"
    t.index ["last_watched_at"], name: "index_watch_stats_on_last_watched_at"
    t.index %w[plex_user_id watchable_type watchable_id], name: "idx_on_plex_user_id_watchable_type_watchable_id_55200a16f6", unique: true
    t.index ["plex_user_id"], name: "index_watch_stats_on_plex_user_id"
    t.index %w[watchable_type watchable_id], name: "index_watch_stats_on_watchable"
  end

  add_foreign_key "arr_tags", "integrations"
  add_foreign_key "audit_events", "operators"
  add_foreign_key "delete_mode_unlocks", "operators"
  add_foreign_key "deletion_actions", "deletion_runs"
  add_foreign_key "deletion_actions", "integrations"
  add_foreign_key "deletion_actions", "media_files"
  add_foreign_key "deletion_runs", "operators"
  add_foreign_key "episodes", "integrations"
  add_foreign_key "episodes", "seasons"
  add_foreign_key "media_files", "integrations"
  add_foreign_key "movies", "integrations"
  add_foreign_key "path_mappings", "integrations"
  add_foreign_key "seasons", "series"
  add_foreign_key "series", "integrations"
  add_foreign_key "watch_stats", "plex_users"
end
