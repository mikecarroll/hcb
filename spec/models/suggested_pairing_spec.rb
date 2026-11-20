# frozen_string_literal: true

require "rails_helper"

RSpec.describe SuggestedPairing, type: :model do
  describe "#mark_accepted!" do
    it "attaches the receipt to the transaction's ledger item" do
      hcb_code = create(:canonical_pending_transaction).local_hcb_code
      receipt = Receipt.new(user: create(:user), upload_method: :api)
      receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
      receipt.save!
      pairing = described_class.create!(receipt:, hcb_code:, distance: 1)

      pairing.mark_accepted!

      expect(receipt.reload.receiptable).to eq(hcb_code.ledger_item)
      expect(hcb_code.receipts).to contain_exactly(receipt)
    end
  end

  describe "Coolhand feedback" do
    let(:receipt) do
      Receipt.new(user: create(:user), upload_method: :api).tap do |receipt|
        receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
        receipt.save!
      end
    end
    let(:pairing) { described_class.create!(receipt:, hcb_code: create(:canonical_pending_transaction).local_hcb_code, distance: 1) }

    after { Coolhand.reset_configuration! }

    context "with Coolhand configured" do
      before { Coolhand.configuration.api_key = "test-key" }

      it "queues feedback for each review of a suggestion" do
        expect { pairing.mark_accepted! }.to have_enqueued_job(SuggestedPairing::CoolhandFeedbackJob).with(pairing, "accepted")
        expect { pairing.mark_reversed! }.to have_enqueued_job(SuggestedPairing::CoolhandFeedbackJob).with(pairing, "reversed")
      end

      it "queues feedback when a suggestion is ignored" do
        expect { pairing.mark_ignored! }.to have_enqueued_job(SuggestedPairing::CoolhandFeedbackJob).with(pairing, "ignored")
      end

      it "queues nothing for a new or rescored suggestion" do
        expect { pairing.update!(distance: 2) }.not_to have_enqueued_job(SuggestedPairing::CoolhandFeedbackJob)
      end
    end

    it "queues nothing without a Coolhand API key" do
      expect { pairing.mark_ignored! }.not_to have_enqueued_job(SuggestedPairing::CoolhandFeedbackJob)
    end
  end
end
