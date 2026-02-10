class CreateSavedViews < ActiveRecord::Migration[8.0]
  def change
    create_table :saved_views do |t|
      t.string :name, null: false
      t.string :scope, null: false
      t.json :filters_json, null: false, default: {}

      t.timestamps
    end

    add_index :saved_views, :name, unique: true
    add_index :saved_views, :scope
    add_check_constraint :saved_views,
                         "scope IN ('movie','tv_show','tv_season','tv_episode')",
                         name: "saved_views_scope_check"
  end
end
