require_relative "model_base"
require_relative "auditable"
require_relative "trackable"

class User < ModelBase
  include Auditable
  include Trackable

  validates :email, presence: true

  attr_accessor :email

  def initialize(email)
    @email = email
  end
end
