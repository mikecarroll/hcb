# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptMatch::Shadow do
  let(:user) { create(:user) }
  let(:event) { create(:event) }
  let(:stripe_card) { create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:) }
  let(:image) { Squishling::Image.new(data: File.binread(file_fixture("receipt.png"))) }

  let!(:hcb_code) do
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents: -12_34)
    canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents: -12_34, event:)
    canonical_pending_transaction.local_hcb_code.reload
  end

  let(:receipt) do
    receipt = Receipt.new(user:, upload_method: :receipt_center)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt.update!(extracted_total_amount_cents: 12_34, extracted_card_last4: stripe_card.last4, extracted_date: hcb_code.date,
                    extracted_merchant_name: "merchant 1", data_extracted: true)
    receipt
  end

  before do
    Flipper.enable(ReceiptMatch::FLAG)
    allow(ReceiptMatch::Images).to receive(:for).and_return([image])
  end

  def run_match
    described_class.call(receipt:, extracted: receipt, hcb_codes: [hcb_code])
  end

  it "runs the model alongside the Ruby matcher under a call id of its own, and records what each picked" do
    fake = fake_squishling { |llm| llm.step("gpt-5.6-terra").reply(hcb_code_id: hcb_code.hashid, confidence: 0.8, rationale: "Same total") }

    matched = run_match

    expect(matched.result.hcb_code_id).to eq(hcb_code.hashid) # the Ruby matcher's answer
    expect(fake.requests.size).to eq(1)

    run = ReceiptMatchRun.sole
    expect(run.receipt).to eq(receipt)
    expect(run.call_id).to start_with("receipt-match:")
    expect(run.request_id).to eq("#{run.call_id}.1")
    expect(run.client_unique_id).to eq(run.request_id)
    expect(run).to have_attributes(ruby_hcb_code_hashid: hcb_code.hashid, llm_hcb_code_hashid: hcb_code.hashid, agreed: true,
                                   candidate_count: 1, candidates_truncated: false, error_class: nil)
    expect(run.reported_at).to be_present
  end

  it "records when the model picks differently" do
    fake_squishling { |llm| llm.step(:any).reply(hcb_code_id: nil, confidence: 0.0, rationale: nil) }

    run_match

    expect(ReceiptMatchRun.sole).to have_attributes(ruby_hcb_code_hashid: hcb_code.hashid, llm_hcb_code_hashid: nil, agreed: false)
  end

  it "records a model failure, and still returns the Ruby answer" do
    fake_squishling { |llm| llm.step(:any).fail(:server_error) }

    expect(run_match.result.hcb_code_id).to eq(hcb_code.hashid)
    expect(ReceiptMatchRun.sole).to have_attributes(agreed: nil, llm_hcb_code_hashid: nil, request_id: nil, error_class: "Squishling::LLMError")
  end

  it "scores every candidate for the receipt bin" do
    assert_no_llm_call { Flipper.disable(ReceiptMatch::FLAG) && run_match }

    matched = run_match
    expect(matched.hcb_codes).to eq([hcb_code])
    expect(matched.match.distance(matched.candidates.first)).to be < ReceiptService::Match::MAX_DISTANCE
  end

  describe "when the model reads a receipt" do
    def runs_after_match
      assert_no_llm_call { run_match }
      ReceiptMatchRun.count
    end

    it "doesn't unless the experiment is on for the receipt's owner" do
      Flipper.disable(ReceiptMatch::FLAG)

      expect(runs_after_match).to eq(0)
    end

    it "doesn't for a receipt that's already on a transaction" do
      receipt.update!(receiptable: create(:ledger_item))

      expect(runs_after_match).to eq(0)
    end

    it "doesn't without transactions to match" do
      assert_no_llm_call { described_class.call(receipt:, extracted: receipt, hcb_codes: []) }

      expect(ReceiptMatchRun.count).to eq(0)
    end

    it "doesn't for a receipt with nothing to read, such as a spreadsheet" do
      allow(ReceiptMatch::Images).to receive(:for).and_return([])

      expect(runs_after_match).to eq(0)
    end

    it "doesn't past the hourly limit for the user" do
      ReceiptMatchRun::HOURLY_LIMIT_PER_USER.times { ReceiptMatchRun.start!(receipt:, candidates: []) }

      assert_no_llm_call { run_match }
      expect(ReceiptMatchRun.count).to eq(ReceiptMatchRun::HOURLY_LIMIT_PER_USER)
    end
  end
end
