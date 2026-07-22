require "spec_helper"

RSpec.describe User do
  it "is invalid without an email" do
    expect(User.new("").valid?).to be(false)
  end

  it "is valid with an email" do
    expect(User.new("a@b.c").valid?).to be(true)
  end

  it "tags audits with the audit prefix" do
    expect(User.new("a@b.c").audit_tag).to eq("audit:User")
  end

  # Uses described_class (not the bare constant) on purpose: this is the case
  # that regressed when class-body mutants were reloaded AFTER the example
  # group bound described_class. If the `validates :email` macro is deleted or
  # its `presence: true` is flipped, described_class.new("") becomes valid and
  # this example fails — proving the mutant is killed via described_class.
  it "rejects a blank email via described_class" do
    expect(described_class.new("").valid?).to be(false)
  end
end
