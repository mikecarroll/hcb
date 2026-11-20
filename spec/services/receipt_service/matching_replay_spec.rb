# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::MatchingReplay do
  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }
  let(:points) { { right_attach: 3, right_suggest: 2, none: 0, ignored_right: 0, wrong_suggest: -1, wrong_attach: -4 } }

  def create_pending_card_charge(amount_cents:)
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
    canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
    canonical_pending_transaction.local_hcb_code.reload
  end

  def create_receipt(**attributes)
    receipt = Receipt.new(user:, **attributes)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt
  end

  it "scores what users did, what was stored, and what the matcher decides now" do
    right = create_pending_card_charge(amount_cents: -12_34)
    wrong = create_pending_card_charge(amount_cents: -56_78)
    receipt = create_receipt(upload_method: :email_receipt_bin, data_extracted: true,
                             extracted_total_amount_cents: 12_34, extracted_card_last4: stripe_card.last4,
                             extracted_date: right.date, extracted_merchant_name: "merchant 1")

    # The matcher at upload time suggested the wrong charge; the user ignored it
    # and attached the receipt to the right one themselves.
    SuggestedPairing.create!(receipt:, hcb_code: wrong, distance: 30, aasm_state: "ignored")
    receipt.update!(receiptable: right.ledger_item)

    report = described_class.new(from: Date.current, to: Date.current, points:).run
    row = report[:rows].sole

    expect(row).to include(truth_hcb_code_id: right.id, truth_was_candidate: true,
                           online: :wrong_suggest, stored: :wrong_suggest, replayed: :right_attach)
    expect(report[:scores][:online][:score]).to eq(-100.0)
    expect(report[:scores][:replayed][:score]).to eq(300.0)
  end

  it "doesn't score receipts that never ended up on a transaction" do
    create_receipt(upload_method: :receipt_center)

    report = described_class.new(from: Date.current, to: Date.current, points:).run

    expect(report[:scores][:replayed]).to include(score: nil, scored: 0, no_ground_truth: 1)
  end

  it "needs points for every outcome" do
    expect { described_class.new(from: Date.current, to: Date.current, points: points.except(:wrong_attach)) }
      .to raise_error(ArgumentError, /wrong_attach/)
  end
end
