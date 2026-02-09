class CreatePathMappings < ActiveRecord::Migration[8.0]
  def change
    create_table :path_mappings do |t|
      t.references :integration, null: false, foreign_key: true
      t.string :from_prefix, null: false
      t.string :to_prefix, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :path_mappings, %i[integration_id from_prefix to_prefix], unique: true
  end
end
