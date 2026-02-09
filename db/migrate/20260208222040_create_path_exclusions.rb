class CreatePathExclusions < ActiveRecord::Migration[8.0]
  def change
    create_table :path_exclusions do |t|
      t.string :name, null: false
      t.string :path_prefix, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :path_exclusions, :path_prefix, unique: true
    add_index :path_exclusions, :enabled
  end
end
