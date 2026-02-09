class CreateAuditEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_events do |t|
      t.references :operator, foreign_key: true
      t.string :event_name, null: false
      t.string :subject_type
      t.integer :subject_id, limit: 8
      t.string :correlation_id
      t.json :payload_json, null: false, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :audit_events, :event_name
    add_index :audit_events, :occurred_at
    add_index :audit_events, %i[subject_type subject_id]
    add_index :audit_events, :correlation_id
  end
end
