Rails.application.routes.draw do
  root "billing#show"
  post "checkout", to: "billing#checkout"
  post "subscriptions/:id/cancel", to: "billing#cancel", as: :cancel_subscription
  post "subscriptions/:id/resume", to: "billing#resume", as: :resume_subscription
  post "charges/:id/refund", to: "billing#refund", as: :refund_charge
end
