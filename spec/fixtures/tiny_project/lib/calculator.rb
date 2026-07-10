class Calculator
  def eligible?(age)
    if age >= 18
      "yes"
    else
      "no"
    end
  end

  def discount(total)
    return 0 if total < 100
    total / 10
  end

  def untested_helper
    42
  end
end
