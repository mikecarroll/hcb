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

    it "doesn't match a receipt that's already on a transaction" do
      hcb_code = create_pending_card_charge
      receipt.update!(receiptable: hcb_code.ledger_item)
      allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: hcb_code.id))

      expect(described_class.new(receipt:).run!).to be_nil
      expect(SuggestedPairing.where(receipt:)).to be_empty
    end

    context "when the experiment is on" do
      let(:hcb_code) { create_pending_card_charge }
      let(:image) { Squishling::Image.new(data: File.binread(file_fixture("receipt.png"))) }

      before do
        Flipper.enable(ReceiptMatch::FLAG)
        allow(ReceiptMatch::Images).to receive(:for).and_return([image])
        allow(user).to receive(:transactions_missing_receipt).and_return(HcbCode.where(id: hcb_code.id))
      end

      it "has the model read the receipt alongside the matcher without changing what's suggested" do
        fake = fake_squishling { |llm| llm.step("gpt-5.6-terra").reply(hcb_code_id: nil, confidence: 0.0, rationale: nil) }

        described_class.new(receipt:).run!

        expect(fake.requests.size).to eq(1)
        expect(ReceiptMatchRun.sole).to have_attributes(receipt:, ruby_hcb_code_hashid: nil, llm_hcb_code_hashid: nil)
        expect(SuggestedPairing.find_by!(receipt:, hcb_code:)).to be_unreviewed
      end

      it "has the model read a receipt the OCR couldn't, without suggesting anything from it" do
        allow(receipt).to receive(:has_textual_content?).and_return(false)
        fake = fake_squishling { |llm| llm.step("gpt-5.6-terra").reply(hcb_code_id: hcb_code.hashid, confidence: 0.9, rationale: nil) }

        expect(described_class.new(receipt:).run!).to be_nil

        expect(fake.requests.size).to eq(1)
        expect(SuggestedPairing.where(receipt:)).to be_empty
      end

      it "records an automatic attachment, which a later reversal is judged against" do
        fake_squishling { |llm| llm.step(:any).reply(hcb_code_id: hcb_code.hashid, confidence: 0.9, rationale: nil) }
        receipt.update!(extracted_total_amount_cents: 12_34, extracted_card_last4: stripe_card.last4,
                        extracted_date: hcb_code.date, extracted_merchant_name: "merchant 1")

        described_class.new(receipt:).run!

        expect(ReceiptMatchEvent.sole).to have_attributes(kind: "auto_attached", human: false, hcb_code_id: hcb_code.id)
        expect { ReceiptMatchEvent.sole.feedback }.not_to raise_error
        expect(ReceiptMatchEvent.sole.feedback).to be_nil # a system event isn't feedback
      end
    end
  end
end
