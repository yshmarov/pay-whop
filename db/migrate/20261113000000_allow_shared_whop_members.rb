class AllowSharedWhopMembers < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_index :pay_customers, [:processor, :processor_id], unique: true,
      where: "processor <> 'whop'", name: "pay_non_whop_processor_identity", **index_options
    add_index :pay_customers, [:processor, :processor_id],
      where: "processor = 'whop'", name: "pay_whop_member_lookup", **index_options
    remove_index :pay_customers, name: "index_pay_customers_on_processor_and_processor_id", **index_options
  end

  def down
    add_index :pay_customers, [:processor, :processor_id], unique: true,
      name: "index_pay_customers_on_processor_and_processor_id", **index_options
    remove_index :pay_customers, name: "pay_non_whop_processor_identity", **index_options
    remove_index :pay_customers, name: "pay_whop_member_lookup", **index_options
  end

  private

  def index_options
    (connection.adapter_name == "PostgreSQL") ? {algorithm: :concurrently} : {}
  end
end
