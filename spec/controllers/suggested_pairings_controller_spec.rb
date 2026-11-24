# frozen_string_literal: true

require "rails_helper"

RSpec.describe SuggestedPairingsController, type: :controller do
  include SessionSupport

  let(:user) { create(:user) }
  let(:hcb_code) { create_card_charge(user:) }
  let(:receipt) { create_bin_receipt(user:, suggested_memo: "🏷️ Event stickers") }
  let!(:run) { create_match_run(receipt:, llm: hcb_code) }
  let(:pairing) { SuggestedPairing.create!(receipt:, hcb_code:, ledger_item: hcb_code.ledger_item, distance: 10, aasm_state: "unreviewed") }

  before do
    Flipper.enable(ReceiptMatch::FLAG)
    create_session(user, verified: true)
  end

  describe "#accept" do
    it "records the acceptance as feedback on the model's answer" do
      expect { post :accept, params: { id: pairing.id }, format: :turbo_stream }.to change(ReceiptMatchEvent, :count).by(1)

      expect(response).to be_successful
      expect(ReceiptMatchEvent.last).to have_attributes(kind: "suggestion_accepted", hcb_code_id: hcb_code.id, receipt:, receipt_match_run: run)
      expect(receipt.reload.receiptable).to eq(hcb_code.ledger_item)
    end

    it "also records the suggested memo being used when it's accepted with the pairing" do
      post :accept, params: { id: pairing.id, memo: "true" }, format: :turbo_stream

      expect(ReceiptMatchEvent.pluck(:kind)).to contain_exactly("suggestion_accepted", "memo_accepted")
    end

    it "doesn't record anything when the experiment is off" do
      Flipper.disable(ReceiptMatch::FLAG)

      expect { post :accept, params: { id: pairing.id }, format: :turbo_stream }.not_to change(ReceiptMatchEvent, :count)
      expect(receipt.reload.receiptable).to eq(hcb_code.ledger_item)
    end
  end

  describe "#ignore" do
    it "records the suggestion being ignored" do
      post :ignore, params: { id: pairing.id }, format: :turbo_stream

      expect(ReceiptMatchEvent.last).to have_attributes(kind: "suggestion_ignored", hcb_code_id: hcb_code.id)
      expect(pairing.reload).to be_ignored
    end
  end
end
