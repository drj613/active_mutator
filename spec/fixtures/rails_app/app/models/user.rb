class User < ApplicationRecord
  def adult?
    age >= 18
  end

  def self.adults
    where("age >= ?", 18)
  end
end
