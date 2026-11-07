module Pay
  module Whop
    class PaymentMethod < Pay::PaymentMethod
      def whop? = true

      %i[make_default! detach].each do |operation|
        define_method(operation) do |*args, **options|
          raise Pay::NotSupportedError, "Manage payment methods in Whop"
        end
      end
    end
  end
end
