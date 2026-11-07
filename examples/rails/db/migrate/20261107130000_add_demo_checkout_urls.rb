class AddDemoCheckoutUrls < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :checkout_urls, :json, default: {}, null: false
  end
end
