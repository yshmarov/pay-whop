class User < ApplicationRecord
  pay_customer
  pay_merchant
  has_many :demo_simulations, dependent: :destroy
end
