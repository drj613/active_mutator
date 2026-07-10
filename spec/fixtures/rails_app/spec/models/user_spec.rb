require "rails_helper"

RSpec.describe User do
  describe "#adult?" do
    it { expect(User.new(age: 18).adult?).to be(true) }
    it { expect(User.new(age: 17).adult?).to be(false) }
  end

  describe ".adults" do
    it "queries the database" do
      User.create!(age: 20)
      User.create!(age: 10)
      expect(User.adults.count).to eq(1)
    end
  end
end
