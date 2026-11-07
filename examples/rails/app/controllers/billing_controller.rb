class BillingController < ActionController::Base
  layout "application"
  before_action :authenticate_demo
  before_action :load_customer

  rescue_from Pay::Error, Whop_sdk::Errors::ApiError do |error|
    redirect_to root_path, alert: "The operation did not complete (#{error.class.name}). Check the server and Whop dashboard before retrying."
  end

  def show
    @subscriptions = @customer.subscriptions.order(created_at: :desc)
    @charges = @customer.charges.order(created_at: :desc)
    @pending_deliveries = Pay::Whop::Delivery.pending.count
  end

  def checkout
    checkout = @customer.checkout(variant_id: ENV.fetch("WHOP_VARIANT_ID"), redirect_url: ENV.fetch("WHOP_RETURN_URL"))
    redirect_to checkout.purchase_url, allow_other_host: true
  end

  def cancel
    @customer.subscriptions.find(params[:id]).cancel
    redirect_to root_path
  end

  def resume
    @customer.subscriptions.find(params[:id]).resume
    redirect_to root_path
  end

  def refund
    @customer.charges.find(params[:id]).refund!
    redirect_to root_path
  end

  private

  def authenticate_demo
    password = ENV["DEMO_PASSWORD"]
    return head :service_unavailable if password.blank?
    authenticate_or_request_with_http_basic("pay-whop demo") do |user, provided|
      user == "demo" && ActiveSupport::SecurityUtils.secure_compare(provided, password)
    end
  end

  def load_customer
    user = User.find_by!(email: "demo@example.test")
    @customer = user.payment_processor || user.set_payment_processor(:whop)
  end
end
