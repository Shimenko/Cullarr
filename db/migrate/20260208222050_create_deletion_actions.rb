class CreateDeletionActions < ActiveRecord::Migration[8.0]
  def change
    create_table :deletion_actions do |t|
      t.references :deletion_run, null: false, foreign_key: true
      t.references :media_file, null: false
      t.references :integration, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :status, null: false
      t.integer :retry_count, null: false, default: 0
      t.string :error_code
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.json :stage_timestamps_json, null: false, default: {}

      t.timestamps
    end

    add_index :deletion_actions, %i[integration_id idempotency_key], unique: true
    add_index :deletion_actions, %i[deletion_run_id media_file_id], unique: true
    add_index :deletion_actions, :status
    add_index :deletion_actions, :finished_at
  end
end
