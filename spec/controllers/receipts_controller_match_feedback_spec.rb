# frozen_string_literal: true

require "rails_helper"

# What ReceiptsController tells ReceiptMatchEvent (see receipts_controller_spec.rb for the rest of it).
RSpec.describe ReceiptsController, type: :controller do
  include SessionSupport

  let(:user) { create(:user) }
  let(:hcb_code) { create_card_charge(user:) }
  let(:receipt) { create_bin_receipt(user:) }
  let!(:run) { create_match_run(receipt:, llm: hcb_code) }

  before do
    Flipper.enable(ReceiptMatch::FLAG)
    create_session(user, verified: true)
  end

  it "records a receipt the user attached to a transaction themselves" do
    post :link, params: { receipt_id: receipt.id, receiptable_type: "Ledger::Item", receiptable_id: hcb_code.ledger_item.id }, format: :turbo_stream

    expect(response).to be_successful
    expect(ReceiptMatchEvent.last).to have_attributes(kind: "manually_linked", hcb_code_id: hcb_code.id, receipt_match_run: run)
  end

  it "records a match the user undid" do
    receipt.update!(receiptable: hcb_code.ledger_item)

    post :reverse, params: { id: receipt.id }, format: :turbo_stream

    expect(receipt.reload.receiptable).to be_nil
    expect(ReceiptMatchEvent.last).to have_attributes(kind: "reversed", hcb_code_id: hcb_code.id)
  end

  it "records a receipt deleted from the bin, and sends the feedback though the receipt is gone" do
    expect { delete :destroy, params: { id: receipt.id }, format: :turbo_stream }
      .to have_enqueued_job(Receipt::SendMatchFeedbackJob)

    expect(Receipt.exists?(receipt.id)).to be(false)
  end

  it "doesn't record deleting a receipt that was on a transaction" do
    receipt.update!(receiptable: hcb_code.ledger_item)

    expect { delete :destroy, params: { id: receipt.id }, format: :turbo_stream }.not_to change(ReceiptMatchEvent, :count)
  end
end
