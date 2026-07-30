module Auditable
  AUDIT_PREFIX = "audit"

  def audit_tag
    "#{AUDIT_PREFIX}:#{self.class.name}"
  end
end
