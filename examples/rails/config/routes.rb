Rails.application.routes.draw do
  root "billing#show"
  get "up", to: "rails/health#show", as: :rails_health_check
  post "session", to: "billing#start", as: :start_session
  post "checkout", to: "billing#checkout"
  post "subscriptions/:id/cancel", to: "billing#cancel", as: :cancel_subscription
  post "subscriptions/:id/resume", to: "billing#resume", as: :resume_subscription
  post "subscriptions/:id/pause", to: "billing#pause", as: :pause_subscription
  post "payment_methods/sync", to: "billing#sync_methods", as: :sync_payment_methods
  post "charge", to: "billing#charge", as: :saved_charge
  post "invoice", to: "billing#invoice", as: :create_invoice
  post "simulations/:kind/:event", to: "billing#simulate", as: :simulation
  post "charges/:id/refund", to: "billing#refund", as: :refund_charge
end
