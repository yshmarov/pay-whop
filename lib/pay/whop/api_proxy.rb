module Pay
  module Whop
    class ApiProxy
      def initialize(target)
        @target = target
      end

      def method_missing(name, *args, **options, &block)
        result = Whop.with_api_errors { @target.public_send(name, *args, **options, &block) }
        if result.class.name.start_with?("Whop_sdk::") && result.class.name.end_with?("::Client")
          self.class.new(result)
        elsif result.is_a?(::Whop_sdk::Internal::CursorItemIterator)
          Enumerator.new { |output| Whop.with_api_errors { result.each { |item| output << item } } }
        else
          result
        end
      end

      def respond_to_missing?(name, include_private = false)
        @target.respond_to?(name, include_private) || super
      end
    end
  end
end
