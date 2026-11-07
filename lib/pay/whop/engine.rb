module Pay
  module Whop
    class Engine < ::Rails::Engine
      engine_name "pay_whop"

      initializer "pay_whop.routes" do |app|
        app.routes.append do
          mount Pay::Whop::Engine, at: "/pay/whop", as: "pay_whop"
        end
      end
    end
  end
end
