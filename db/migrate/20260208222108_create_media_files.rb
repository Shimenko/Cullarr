class CreateMediaFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :media_files do |t|
      t.references :attachable, polymorphic: true, null: false
      t.references :integration, null: false, foreign_key: true
      t.integer :arr_file_id, limit: 8, null: false
      t.text :path, null: false
      t.text :path_canonical, null: false
      t.integer :size_bytes, limit: 8, null: false
      t.json :quality_json, null: false, default: {}
      t.datetime :culled_at

      t.timestamps
    end

    add_index :media_files, %i[integration_id arr_file_id], unique: true
    add_index :media_files, :path_canonical
    add_index :media_files, :size_bytes
    add_index :media_files, :culled_at
  end
end
