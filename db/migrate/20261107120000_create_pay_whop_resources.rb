class CreatePayWhopResources < ActiveRecord::Migration[7.0]
  def change
    create_table :pay_whop_resources do |t|
      t.string :type, null: false
      t.string :processor_id, null: false
      t.string :account_id, null: false
      t.string :environment, null: false
      t.references :customer, foreign_key: {to_table: :pay_customers}
      t.references :merchant, foreign_key: {to_table: :pay_merchants}
      t.string :status
      t.bigint :amount
      t.string :currency
      t.json :data, default: {}, null: false
      t.timestamps
    end
    add_index :pay_whop_resources, [:type, :environment, :account_id, :processor_id], unique: true, name: "pay_whop_resource_identity"
  end
end
