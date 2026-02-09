class CreateArrTags < ActiveRecord::Migration[8.0]
  def change
    create_table :arr_tags do |t|
      t.references :integration, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :arr_tag_id, limit: 8, null: false

      t.timestamps
    end

    add_index :arr_tags, %i[integration_id name], unique: true
    add_index :arr_tags, %i[integration_id arr_tag_id], unique: true
  end
end
