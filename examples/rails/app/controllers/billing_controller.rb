class BillingController < ActionController::Base
  layout "application"
  before_action :load_customer
  before_action :require_customer, except: [:show, :start]
  rate_limit to: 10, within: 1.minute, only: [:start, :checkout, :cancel, :resume, :refund, :pause, :sync_methods, :charge, :invoice, :simulate, :retry_payment, :reconcile], with: -> { redirect_to root_path, alert: "Please wait a minute before trying again." }

  rescue_from Pay::Error, Whop_sdk::Errors::ApiError do |error|
    message = if error.is_a?(Pay::Whop::PaymentIncomplete)
      "Whop has not confirmed this test payment yet. Refresh after its webhook arrives; no successful charge has been recorded."
    elsif (error.is_a?(Pay::Whop::ApiError) && error.code == "not_enough_balance") || error.message.include?("not_enough_balance")
      "Whop cannot refund this test payment while the seller's sandbox funds are pending. Your payment has not been marked refunded."
    else
      "Whop could not complete that operation. Your confirmed billing state is shown below. Please try again later."
    end
    flash[:recovery_url] = error.recovery_url if error.is_a?(Pay::Whop::PaymentIncomplete)
    redirect_to root_path, alert: message
  end

  def show
    @subscriptions = scoped_subscriptions.order(created_at: :desc)
    @charges = scoped_charges.order(created_at: :desc)
    @methods = @customer ? @customer.payment_methods : []
    @invoices = @customer ? @customer.invoices.order(created_at: :desc) : []
    @marketplace_enabled = ENV["DEMO_MERCHANT_ID"].present?
    @simulations = @user ? @user.demo_simulations.index_by(&:kind) : {}
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
    flow = params.fetch(:flow, "subscription")
    raise ActionController::BadRequest unless %w[subscription one_time setup marketplace].include?(flow)
    url = (flow == "subscription") ? user.checkout_url : user.checkout_urls[flow]
    if url.blank?
      options = {redirect_url: ENV.fetch("WHOP_RETURN_URL"), idempotency_key: "#{user.checkout_key}-#{flow}"}
      checkout = case flow
      when "subscription" then @customer.checkout(variant_id: ENV.fetch("WHOP_VARIANT_ID"), **options)
      when "one_time" then @customer.checkout_charge(amount: 500, **options)
      when "setup" then @customer.setup_checkout(**options)
      when "marketplace"
        merchant = Pay::Whop::Merchant.find_by!(processor_id: ENV.fetch("DEMO_MERCHANT_ID"))
        merchant.customer_for(user).checkout_charge(amount: 500, application_fee_amount: 100, **options)
      end
      url = checkout.purchase_url
      uri = URI.parse(url)
      raise Pay::Whop::Error, "Expected sandbox checkout" unless uri.scheme == "https" && uri.host == "sandbox.whop.com"
      if flow == "subscription"
        user.update!(checkout_url: url)
      else
        user.with_lock { user.update!(checkout_urls: user.checkout_urls.merge(flow => url)) }
      end
    end
    redirect_to url, allow_other_host: true
  end

  def cancel
    scoped_subscriptions.find(params[:id]).cancel
    redirect_to root_path
  end

  def resume
    scoped_subscriptions.find(params[:id]).resume
    redirect_to root_path
  end

  def refund
    charge = scoped_charges.find(params[:id])
    amount = (params[:partial] == "1") ? [100, charge.amount - charge.amount_refunded.to_i].min : nil
    charge.refund!(amount)
    redirect_to root_path
  end

  def pause
    scoped_subscriptions.find(params[:id]).pause
    redirect_to root_path
  end

  def sync_methods
    @customer.sync_payment_methods
    redirect_to root_path
  end

  def retry_payment
    subscription = scoped_subscriptions.find(params[:id])
    payment = subscription.latest_payment
    raise Pay::Whop::Error, "No payment is available to retry" unless payment
    subscription.retry_failed_payment(payment_id: payment.id, idempotency_key: "#{@user.checkout_key}-retry-#{payment.id}")
    redirect_to root_path
  end

  def reconcile
    @customer.reconcile!
    redirect_to root_path
  end

  def charge
    @customer.add_payment_method(params.require(:payment_method_id), default: true)
    @customer.charge(500, idempotency_key: "#{@customer.owner.checkout_key}-saved-charge")
    redirect_to root_path
  end

  def invoice
    @customer.create_invoice(items: [{variant_id: ENV.fetch("WHOP_ONE_TIME_VARIANT_ID"), quantity: 1}],
      idempotency_key: "#{@customer.owner.checkout_key}-invoice")
    redirect_to root_path
  end

  def simulate
    raise ActiveRecord::RecordNotFound unless Pay::Whop.environment == "sandbox"
    kind = params[:kind]
    raise ActionController::BadRequest unless DemoSimulation::FLOWS.key?(kind)
    if params[:event] == "start"
      @user.with_lock { @user.demo_simulations.find_or_create_by!(kind: kind) }
    else
      @user.demo_simulations.find_by!(kind: kind).advance!(params[:event])
    end
    redirect_to root_path(anchor: "simulations")
  rescue DemoSimulation::InvalidTransition
    redirect_to root_path(anchor: "simulations"), alert: "That simulation step is no longer available. The current simulated state is shown below."
  end

  private

  def load_customer
    @user = User.find_by(id: session[:demo_user_id]) if session[:demo_user_id]
    @customer = @user&.payment_processor
  end

  def customer_ids
    @user ? @user.pay_customers.where(type: "Pay::Whop::Customer").pluck(:id) : []
  end

  def scoped_subscriptions = Pay::Whop::Subscription.where(customer_id: customer_ids)
  def scoped_charges = Pay::Whop::Charge.where(customer_id: customer_ids)

  def require_customer
    redirect_to root_path, alert: "Start a sandbox session first." unless @customer
  end
end
