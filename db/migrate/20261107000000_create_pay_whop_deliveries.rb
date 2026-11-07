class CreatePayWhopDeliveries < ActiveRecord::Migration[7.0]
  def change
    create_table :pay_whop_deliveries do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :resource_id, null: false
      t.string :account_id, null: false
      t.string :environment, null: false
      t.datetime :processed_at
      t.timestamps
    end
    add_index :pay_whop_deliveries, [:environment, :account_id, :event_id], unique: true, name: "pay_whop_delivery_identity"
    add_index :pay_whop_deliveries, :processed_at
  end
end
