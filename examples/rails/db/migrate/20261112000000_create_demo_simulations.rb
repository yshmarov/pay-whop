class CreateDemoSimulations < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_simulations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false
      t.json :history, default: [], null: false
      t.timestamps
    end
    add_index :demo_simulations, [:user_id, :kind], unique: true
  end
end
