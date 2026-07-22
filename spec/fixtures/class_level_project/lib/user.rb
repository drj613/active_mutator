require_relative "model_base"
require_relative "auditable"

class User < ModelBase
  include Auditable

  validates :email, presence: true

  attr_accessor :email

  def initialize(email)
    @email = email
  end
end
