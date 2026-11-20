# frozen_string_literal: true

require "rails_helper"
require "squishling/testing"

RSpec.describe ReceiptService::ExtractionEval do
  include Squishling::Testing::RSpec

  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }
  let(:charge) do
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents: -12_34)
    create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents: -12_34, event:)
      .local_hcb_code.reload
  end

  def attached_receipt
    Receipt.new(user:, upload_method: :transaction_page, textual_content: "TOTAL 12.34",
                receiptable: charge.ledger_item).tap do |receipt|
      receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
      receipt.save!
    end
  end

  def vision_reply(**fields)
    Squishling::Testing::Reply.new(
      Squishling::Testing.valid_reply_for(ReceiptService::VisionExtract, is_receipt: true, currency: nil,
                                                                         card_last_four: nil, date: nil, **fields),
      usage: { input_tokens: 900, output_tokens: 60 }
    )
  end

  before do
    allow(ReceiptService::Extract).to receive(:fields_from_text).and_return(
      [{ "total_amount_cents" => 12_34, "date" => Date.current.to_s, "card_last_four" => nil },
       { input_tokens: 400, output_tokens: 40 }]
    )
  end

  it "scores each extractor's fields against the charge, with the tokens each used" do
    receipt = attached_receipt
    fake_squishling do |llm|
      llm.step(:any).reply(vision_reply(total_amount_cents: 99, date: Date.current.to_s,
                                        card_last_four: stripe_card.last4))
    end

    report = described_class.new(from: Date.current, to: Date.current, limit: 5, max_tokens: 10_000).run

    expect(report[:rows].sole).to eq(
      receipt_id: receipt.id, hcb_code_id: charge.id,
      text: { amount: :correct, date: :correct, card_last_four: :missing },
      vision: { amount: :wrong, date: :correct, card_last_four: :correct }
    )
    expect(report[:tokens]).to eq(text: { input_tokens: 400, output_tokens: 40 },
                                  vision: { input_tokens: 900, output_tokens: 60 })
    expect(report[:fields][:vision][:card_last_four]).to include(correct: 1, accuracy: 1.0)
    expect(receipt.reload.data_extracted).to be(false)
  end

  it "stops before the receipt that would start past the token cap" do
    2.times { attached_receipt }
    fake_squishling { |llm| llm.step(:any).reply(vision_reply) }

    report = described_class.new(from: Date.current, to: Date.current, limit: 5, max_tokens: 1_000).run

    expect(report).to include(receipts: 1, stopped_on_token_cap: true)
  end

  it "stops at the receipt limit" do
    2.times { attached_receipt }
    fake_squishling { |llm| llm.step(:any).reply(vision_reply) }

    expect(described_class.new(from: Date.current, to: Date.current, limit: 1, max_tokens: 10_000).run[:receipts]).to eq(1)
  end

  it "counts a failed extraction as an error on every field and carries on" do
    attached_receipt
    fake_squishling { |llm| llm.step(:any).fail(:server_error) }

    report = described_class.new(from: Date.current, to: Date.current, limit: 5, max_tokens: 10_000).run

    expect(report[:rows].sole[:vision]).to eq(amount: :error, date: :error, card_last_four: :error)
  end

  it "needs a positive limit and token cap" do
    expect { described_class.new(from: Date.current, to: Date.current, limit: 0, max_tokens: 1) }
      .to raise_error(ArgumentError, /limit/)
    expect { described_class.new(from: Date.current, to: Date.current, limit: 1, max_tokens: nil) }
      .to raise_error(ArgumentError, /max_tokens/)
  end
end
