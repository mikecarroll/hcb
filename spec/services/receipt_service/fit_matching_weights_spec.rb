# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::FitMatchingWeights do
  describe ".wilson_lower_bound" do
    it "matches the Wilson score interval" do
      expect(described_class.wilson_lower_bound(9, 10, z: 1.96)).to be_within(1e-4).of(0.5958)
    end

    it "is the observed rate when z is zero" do
      expect(described_class.wilson_lower_bound(3, 4, z: 0)).to eq(0.75)
    end

    it "is zero with nothing to measure" do
      expect(described_class.wilson_lower_bound(0, 0, z: 1.96)).to eq(0.0)
    end
  end

  describe ".lowest_threshold" do
    let(:decisions) do
      [
        { probability: 0.95, correct: true },
        { probability: 0.9, correct: true },
        { probability: 0.8, correct: true },
        { probability: 0.7, correct: false },
        { probability: 0.6, correct: true },
      ]
    end

    it "picks the lowest threshold whose precision bound clears the minimum" do
      result = described_class.lowest_threshold(decisions, min_precision: 0.9, z: 0, total: 10)

      expect(result).to include(threshold: 0.8, acted: 3, coverage: 0.3, precision: 1.0)
    end

    it "goes lower when the minimum allows" do
      expect(described_class.lowest_threshold(decisions, min_precision: 0.75, z: 0, total: 10)).to include(threshold: 0.6, acted: 5)
    end

    it "accounts for how few decisions back a threshold" do
      expect(described_class.lowest_threshold(decisions, min_precision: 0.9, z: 1.96, total: 10)).to be_nil
    end
  end

  describe ".time_split" do
    it "tests on the latest uploads and keeps each receipt's rows together" do
      rows = [3, 1, 5, 2, 4].flat_map do |receipt_id|
        [{ receipt_id:, uploaded_at: receipt_id.days.ago }, { receipt_id:, uploaded_at: receipt_id.days.ago }]
      end

      train, test = described_class.time_split(rows, test_fraction: 0.4)

      expect(train.pluck(:receipt_id).uniq).to contain_exactly(5, 4, 3)
      expect(test.pluck(:receipt_id).uniq).to contain_exactly(2, 1)
    end
  end

  describe "#run" do
    let(:user) { create(:user) }
    let(:event) { create(:event) }
    let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }

    def create_pending_card_charge(amount_cents:)
      raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
      canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
      canonical_pending_transaction.local_hcb_code.reload
    end

    it "fits on the earlier receipts and evaluates on the later ones" do
      charges = (1..3).map { |n| [create_pending_card_charge(amount_cents: -n * 10_00), create_pending_card_charge(amount_cents: -n * 10_00 - 3_33)] }

      charges.each_with_index do |(right, _wrong), index|
        receipt = Receipt.new(user:, upload_method: :receipt_center, data_extracted: true,
                              extracted_total_amount_cents: right.amount_cents.abs, extracted_date: right.date)
        receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
        receipt.save!
        receipt.update_columns(created_at: (index + 1).minutes.from_now)
        receipt.update!(receiptable: right.ledger_item)
      end

      fit = described_class.new(from: Date.current, to: Date.tomorrow, min_precision: 0.5, test_fraction: 1.0 / 3)
      report = fit.run

      expect(fit.rows.group_by { |row| row[:receipt_id] }.values).to all(satisfy { |rows| rows.count { |row| row[:label] == 1 } == 1 })
      expect(report[:receipts]).to eq(train: 2, test: 1)
      expect(report[:coefficients].keys).to eq([:intercept, *described_class::FEATURE_NAMES])
      expect(report[:auto_attach]).to include(min_precision: 0.5)
      expect(report[:curve].size).to eq(9)
    end

    it "requires a minimum precision between 0 and 1" do
      expect { described_class.new(from: Date.current, to: Date.current, min_precision: 95) }.to raise_error(ArgumentError)
    end
  end
end
