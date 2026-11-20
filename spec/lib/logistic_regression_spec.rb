# frozen_string_literal: true

require "rails_helper"

RSpec.describe LogisticRegression do
  # One binary feature: 1 of 4 rows positive when it's 0, 3 of 4 when it's 1.
  # Unpenalized, the fit has a closed form: the intercept is logit(1/4) and the
  # weight is logit(3/4) - logit(1/4).
  let(:rows) { [[0], [0], [0], [0], [1], [1], [1], [1]] }
  let(:labels) { [1, 0, 0, 0, 1, 1, 1, 0] }

  it "recovers the maximum-likelihood coefficients" do
    model = described_class.fit(rows, labels, l2: 1e-9)

    expect(model.intercept).to be_within(1e-6).of(-Math.log(3))
    expect(model.weights.first).to be_within(1e-6).of(2 * Math.log(3))
    expect(model.probability([1])).to be_within(1e-6).of(0.75)
  end

  it "shrinks the weights, but not the intercept's role, as the penalty grows" do
    loose = described_class.fit(rows, labels, l2: 1e-9)
    tight = described_class.fit(rows, labels, l2: 10.0)

    expect(tight.weights.first.abs).to be < loose.weights.first.abs
    expect(tight.probability([0]) + tight.probability([1])).to be_within(1e-6).of(1.0)
  end

  it "converges on perfectly separable data instead of diverging" do
    model = described_class.fit([[0], [0], [1], [1]], [0, 0, 1, 1], l2: 1.0)

    expect(model.probability([1])).to be > 0.5
    expect(model.probability([0])).to be < 0.5
    expect(model.weights.first).to be_finite
  end

  it "refuses mismatched rows and labels" do
    expect { described_class.new([[0]], [0, 1]) }.to raise_error(ArgumentError)
  end
end
