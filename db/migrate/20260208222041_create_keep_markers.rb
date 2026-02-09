class CreateKeepMarkers < ActiveRecord::Migration[8.0]
  def change
    create_table :keep_markers do |t|
      t.references :keepable, polymorphic: true, null: false
      t.text :note

      t.timestamps
    end

    add_index :keep_markers, %i[keepable_type keepable_id], unique: true
  end
end
