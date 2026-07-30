# Minimal validates-style macro so the fixture exercises real macro
# accumulation semantics without a Rails dependency.
class ModelBase
  def self.validations = @validations ||= []

  def self.validates(field, presence: false)
    validations << [field, presence]
  end

  def valid?
    self.class.validations.all? do |field, presence|
      !presence || !send(field).to_s.empty?
    end
  end
end
