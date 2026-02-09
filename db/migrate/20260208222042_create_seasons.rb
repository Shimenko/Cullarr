class CreateSeasons < ActiveRecord::Migration[8.0]
  def change
    create_table :seasons do |t|
      t.references :series, null: false
      t.integer :season_number, null: false

      t.timestamps
    end

    add_index :seasons, %i[series_id season_number], unique: true
  end
end
