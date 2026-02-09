class CreateDeletionRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :deletion_runs do |t|
      t.references :operator, null: false, foreign_key: true
      t.string :status, null: false
      t.string :scope, null: false
      t.json :selected_plex_user_ids_json, null: false, default: []
      t.json :summary_json, null: false, default: {}
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_code
      t.text :error_message

      t.timestamps
    end

    add_index :deletion_runs, :status
    add_index :deletion_runs, :scope
    add_index :deletion_runs, :started_at
  end
end
