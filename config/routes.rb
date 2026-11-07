Pay::Whop::Engine.routes.draw do
  post "webhooks", to: "pay/whop/webhooks#create"
end
