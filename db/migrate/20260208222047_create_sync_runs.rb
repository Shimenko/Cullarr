class CreateSyncRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :sync_runs do |t|
      t.string :status, null: false
      t.string :trigger, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.string :phase
      t.json :phase_counts_json, null: false, default: {}
      t.string :error_code
      t.text :error_message
      t.boolean :queued_next, null: false, default: false

      t.timestamps
    end

    add_index :sync_runs, :status
    add_index :sync_runs, :started_at
    add_index :sync_runs, :finished_at
  end
end
