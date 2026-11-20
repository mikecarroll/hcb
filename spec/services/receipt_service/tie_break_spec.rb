# frozen_string_literal: true

require "rails_helper"
require "squishling/testing"

RSpec.describe ReceiptService::TieBreak do
  include Squishling::Testing::RSpec

  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }

  def create_pending_card_charge(amount_cents:)
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
    canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
    canonical_pending_transaction.local_hcb_code.reload
  end

  def create_receipt(upload_method: :receipt_center, **extracted)
    receipt = Receipt.new(user:, upload_method:, data_extracted: true, **extracted)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt
  end

  def decide(receipt, charges)
    suggest = ReceiptService::Suggest.new(receipt:)
    suggest.decide(suggest.rank(charges, extracted: receipt))
  end

  # Two charges for the same amount on the same day: the matcher can't tell
  # them apart.
  let!(:first) { create_pending_card_charge(amount_cents: -15_00) }
  let!(:second) { create_pending_card_charge(amount_cents: -15_00) }
  let(:receipt) { create_receipt(extracted_total_amount_cents: 15_00, extracted_date: first.date) }

  it "isn't consulted while the flag is off" do
    fake = fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: second.id, reason: "x" }) }

    expect(decide(receipt, [first, second])).to include(action: :none, tied: true)
    expect(fake.requests).to be_empty
  end

  context "with the flag on" do
    before { Flipper.enable(ReceiptService::Suggest::TIEBREAK_FLAG, user) }

    it "isn't consulted when the closest charge is well ahead" do
      other = create_pending_card_charge(amount_cents: -99_00)
      fake = fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: other.id, reason: "x" }) }

      expect(decide(receipt, [first, other])).to include(action: :suggest, hcb_code: first)
      expect(fake.requests).to be_empty
    end

    it "suggests the charge the model picks, and the receipt bin shows it" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: first.id, reason: "Same day." }) }
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: [first.id, second.id]))
      allow(receipt).to receive(:has_textual_content?).and_return(true)

      ReceiptService::Suggest.new(receipt:).run!

      expect(fake.requests.size).to eq(1)
      expect(fake.requests.first.arguments.deep_symbolize_keys[:candidates].pluck(:hcb_code_id)).to contain_exactly(first.id, second.id)
      expect(receipt.suggested_pairings.find_by(hcb_code: first).tiebreak_verdict).to eq("picked")
      expect(user.receipt_bin.suggested_receipt_pairings.map(&:hcb_code)).to eq([first])
    end

    it "suggests nothing when the model can't tell the charges apart" do
      fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: nil, reason: "Identical charges." }) }
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: [first.id, second.id]))
      allow(receipt).to receive(:has_textual_content?).and_return(true)

      ReceiptService::Suggest.new(receipt:).run!

      expect(receipt.suggested_pairings.pluck(:tiebreak_verdict).uniq).to eq(["rejected"])
      expect(user.receipt_bin.suggested_receipt_pairings).to be_empty
    end

    it "rejects a charge that wasn't a candidate, then decides without the model" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: 0, reason: "Made up." }) }

      expect(decide(receipt, [first, second])).to include(action: :none, tied: true)
      expect(fake.requests.size).to eq(2)
      expect(fake.requests.last.errors.join).to include("hcb_code_id must be null or one of")
    end

    it "never attaches a receipt on the model's say-so" do
      emailed = create_receipt(upload_method: :email_receipt_bin, extracted_total_amount_cents: 15_00,
                               extracted_card_last4: stripe_card.last4, extracted_date: first.date)
      fake_squishling { |llm| llm.step(:any).reply({ hcb_code_id: second.id, reason: "x" }) }

      expect(decide(emailed, [first, second])).to include(action: :suggest, hcb_code: second)
    end
  end
end
