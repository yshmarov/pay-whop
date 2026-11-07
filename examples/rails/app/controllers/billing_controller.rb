class BillingController < ActionController::Base
  layout "application"
  before_action :load_customer
  before_action :require_customer, except: [:show, :start]
  rate_limit to: 10, within: 1.minute, only: [:start, :checkout, :cancel, :resume, :refund], with: -> { redirect_to root_path, alert: "Please wait a minute before trying again." }

  rescue_from Pay::Error, Whop_sdk::Errors::ApiError do |error|
    message = if error.message.include?("not_enough_balance")
      "Whop cannot refund this test payment while the seller's sandbox funds are pending. Your payment has not been marked refunded."
    else
      "Whop could not complete that operation. Your confirmed billing state is shown below. Please try again later."
    end
    redirect_to root_path, alert: message
  end

  def show
    @subscriptions = @customer ? @customer.subscriptions.order(created_at: :desc) : []
    @charges = @customer ? @customer.charges.order(created_at: :desc) : []
  end

  def start
    unless @customer
      user = User.create!(email: "#{SecureRandom.uuid}@demo.example.test", checkout_key: SecureRandom.uuid)
      session[:demo_user_id] = user.id
      user.set_payment_processor(:whop)
    end
    redirect_to root_path
  end

  def checkout
    user = @customer.owner
    if user.checkout_url.blank?
      checkout = @customer.checkout(variant_id: ENV.fetch("WHOP_VARIANT_ID"), redirect_url: ENV.fetch("WHOP_RETURN_URL"), idempotency_key: user.checkout_key)
      uri = URI.parse(checkout.purchase_url)
      raise Pay::Whop::Error, "Expected sandbox checkout" unless uri.scheme == "https" && uri.host == "sandbox.whop.com"
      user.update!(checkout_url: checkout.purchase_url)
    end
    redirect_to user.checkout_url, allow_other_host: true
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

  def load_customer
    user = User.find_by(id: session[:demo_user_id]) if session[:demo_user_id]
    @customer = user&.payment_processor
  end

  def require_customer
    redirect_to root_path, alert: "Start a sandbox session first." unless @customer
  end
end
