class AddDeferredForeignKeys < ActiveRecord::Migration[8.0]
  def change
    add_foreign_key :seasons, :series
    add_foreign_key :deletion_actions, :media_files
  end
end
