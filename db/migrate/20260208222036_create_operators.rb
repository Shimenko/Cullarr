class CreateOperators < ActiveRecord::Migration[8.0]
  def change
    create_table :operators do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.datetime :last_login_at

      t.timestamps
    end

    add_index :operators, :email, unique: true
  end
end
