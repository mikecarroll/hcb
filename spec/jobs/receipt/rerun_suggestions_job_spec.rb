# frozen_string_literal: true

require "rails_helper"

RSpec.describe Receipt::RerunSuggestionsJob do
  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }

  def create_pending_card_charge(amount_cents: -12_34)
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
    create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
  end

  def create_extracted_receipt(owner: user, upload_method: :receipt_center, **extracted)
    receipt = Receipt.new(user: owner, upload_method:, data_extracted: true, textual_content: "receipt text", **extracted)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt
  end

  describe "enqueueing" do
    it "enqueues when a card charge is created and the flag is on for anyone" do
      Flipper.enable(described_class::FLAG, user)

      expect { create_pending_card_charge }.to have_enqueued_job(described_class)
    end

    it "doesn't enqueue while the flag is off" do
      expect { create_pending_card_charge }.not_to have_enqueued_job(described_class)
    end

    it "doesn't enqueue for refunds or charges that aren't card charges" do
      Flipper.enable(described_class::FLAG)

      expect(described_class.enqueue_for?(build(:canonical_pending_transaction, amount_cents: 5_00, raw_pending_stripe_transaction_id: 1))).to be(false)
      expect(described_class.enqueue_for?(build(:canonical_pending_transaction, amount_cents: -5_00, raw_pending_stripe_transaction_id: nil))).to be(false)
    end
  end

  describe "#perform" do
    before { Flipper.enable(described_class::FLAG, user) }

    it "re-matches the cardholder's receipts dated near the new charge, without extracting again" do
      near = create_extracted_receipt(extracted_total_amount_cents: 12_34, extracted_date: Time.current)
      undated = create_extracted_receipt(extracted_total_amount_cents: 12_34)
      far = create_extracted_receipt(extracted_total_amount_cents: 12_34, extracted_date: 90.days.ago)
      someone_elses = create_extracted_receipt(owner: create(:user), extracted_total_amount_cents: 12_34, extracted_date: Time.current)
      charge = create_pending_card_charge

      expect(Faraday).not_to receive(:new)
      described_class.perform_now(charge)

      hcb_code = charge.local_hcb_code
      expect(SuggestedPairing.where(hcb_code:).pluck(:receipt_id)).to contain_exactly(near.id, undated.id)
      expect(far.suggested_pairings).to be_empty
      expect(someone_elses.suggested_pairings).to be_empty
    end

    it "does nothing for a user without the flag" do
      Flipper.disable(described_class::FLAG, user)
      receipt = create_extracted_receipt(extracted_total_amount_cents: 12_34, extracted_date: Time.current)

      described_class.perform_now(create_pending_card_charge)

      expect(receipt.suggested_pairings).to be_empty
    end

    it "attaches an emailed receipt automatically once its charge posts" do
      receipt = create_extracted_receipt(upload_method: :email_receipt_bin, extracted_total_amount_cents: 12_34,
                                         extracted_card_last4: stripe_card.last4, extracted_date: Time.current)
      charge = create_pending_card_charge

      described_class.perform_now(charge)

      expect(receipt.reload.receiptable).to eq(charge.local_hcb_code.ledger_item)
    end

    it "keeps a pairing the user ignored, and doesn't attach it automatically" do
      receipt = create_extracted_receipt(upload_method: :email_receipt_bin, extracted_total_amount_cents: 12_34,
                                         extracted_card_last4: stripe_card.last4, extracted_date: Time.current)
      charge = create_pending_card_charge
      ignored = SuggestedPairing.create!(receipt:, hcb_code: charge.local_hcb_code, distance: 90, aasm_state: "ignored")

      described_class.perform_now(charge)

      expect(ignored.reload.aasm_state).to eq("ignored")
      expect(ignored.distance).to be < 90
      expect(receipt.reload.receiptable).to be_nil
    end
  end
end
