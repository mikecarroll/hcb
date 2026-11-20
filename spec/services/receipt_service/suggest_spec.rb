# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::Suggest do
  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }

  # A pending card charge on the user's card, missing its receipt.
  def create_pending_card_charge(amount_cents: -12_34)
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
    canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
    canonical_pending_transaction.local_hcb_code.reload
  end

  def create_receipt_in_bin
    receipt = Receipt.new(user:, upload_method: :email_receipt_bin)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt
  end

  describe "#run!" do
    let(:receipt) { create_receipt_in_bin }

    before do
      # The suggestions are scored against what the extractor read off the
      # receipt; the extraction itself (OCR and an LLM call) is out of scope.
      allow(receipt).to receive(:has_textual_content?).and_return(true)
      allow(ReceiptService::Extract).to receive(:new).with(receipt:).and_return(instance_double(ReceiptService::Extract, run!: receipt))
    end

    it "writes a pairing with the charge's HCB code and its ledger item" do
      hcb_code = create_pending_card_charge
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: hcb_code.id))

      described_class.new(receipt:).run!

      pairing = SuggestedPairing.find_by!(receipt:, hcb_code:)
      expect(pairing.ledger_item).to eq(hcb_code.ledger_item)
      expect(pairing).to be_unreviewed
    end

    it "pairs the receipt automatically when a charge matches closely" do
      hcb_code = create_pending_card_charge(amount_cents: -12_34)
      receipt.update!(extracted_total_amount_cents: 12_34, extracted_card_last4: stripe_card.last4,
                      extracted_date: hcb_code.date, extracted_merchant_name: "merchant 1")
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: hcb_code.id))

      pairing = described_class.new(receipt:).run!

      expect(pairing).to be_accepted
      expect(receipt.reload.receiptable).to eq(hcb_code.ledger_item)
    end

    it "doesn't attach automatically without a card match, however close" do
      hcb_code = create_pending_card_charge(amount_cents: -12_34)
      receipt.update!(extracted_total_amount_cents: 12_34, extracted_date: hcb_code.date)
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: hcb_code.id))

      described_class.new(receipt:).run!

      expect(SuggestedPairing.find_by!(receipt:, hcb_code:)).to be_unreviewed
      expect(receipt.reload.receiptable).to be_nil
    end

    it "doesn't attach automatically when two charges match equally well" do
      first = create_pending_card_charge(amount_cents: -12_34)
      second = create_pending_card_charge(amount_cents: -12_34)
      receipt.update!(extracted_total_amount_cents: 12_34, extracted_card_last4: stripe_card.last4,
                      extracted_date: first.date, extracted_merchant_name: "merchant 1")
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: [first.id, second.id]))

      described_class.new(receipt:).run!

      expect(receipt.reload.receiptable).to be_nil
      expect(user.receipt_bin.suggested_receipt_pairings).to be_empty
    end

    it "only considers charges near the receipt's date" do
      recent = create_pending_card_charge
      old = create_pending_card_charge
      old.update_column(:created_at, 60.days.ago)
      receipt.update!(extracted_total_amount_cents: 12_34, extracted_date: Time.current)
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: [recent.id, old.id]))

      described_class.new(receipt:).run!

      expect(receipt.suggested_pairings.pluck(:hcb_code_id)).to eq([recent.id])
    end
  end

  describe "#rank" do
    let(:receipt) { create_receipt_in_bin }
    let(:hcb_code) { create_pending_card_charge(amount_cents: -10_00) }

    def distance_for(**extracted)
      receipt.assign_attributes(extracted)
      described_class.new(receipt:).rank([hcb_code], extracted: receipt).first[:distance]
    end

    it "leaves out what the receipt doesn't say instead of counting it as a miss" do
      expect(distance_for(extracted_total_amount_cents: 10_00)).to eq(0)
    end

    it "still counts a missing amount as a miss" do
      expect(distance_for(extracted_card_last4: stripe_card.last4)).to eq(50)
    end

    it "gives partial credit for a charge that includes a tip" do
      expect(distance_for(extracted_total_amount_cents: 8_50)).to eq(50)
      expect(distance_for(extracted_total_amount_cents: 5_00)).to eq(100)
    end

    it "leaves out the postcode when either side doesn't have one" do
      allow(hcb_code).to receive(:stripe_merchant).and_return({ "name" => "merchant 1", "postal_code" => "00000" })

      expect(distance_for(extracted_total_amount_cents: 10_00, extracted_merchant_zip_code: nil)).to eq(0)
    end

    it "compares postcodes that aren't US ZIP codes as text" do
      allow(hcb_code).to receive(:stripe_merchant).and_return({ "name" => "merchant 1", "postal_code" => "SW1A 1AA" })

      expect(distance_for(extracted_total_amount_cents: 10_00, extracted_merchant_zip_code: "sw1a1aa")).to eq(0)
      expect(distance_for(extracted_total_amount_cents: 10_00, extracted_merchant_zip_code: "EC1A 1BB")).to be > 0
    end

    it "matches ZIP+4 codes on their first five digits" do
      allow(hcb_code).to receive(:stripe_merchant).and_return({ "name" => "merchant 1", "postal_code" => "94103" })

      expect(distance_for(extracted_total_amount_cents: 10_00, extracted_merchant_zip_code: "94103-1234")).to eq(0)
    end
  end
end
