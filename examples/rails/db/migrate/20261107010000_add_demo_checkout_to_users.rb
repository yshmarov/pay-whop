class AddDemoCheckoutToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :checkout_key, :string
    add_column :users, :checkout_url, :text
    add_index :users, :checkout_key, unique: true
  end
end
