# frozen_string_literal: true

# Builders for specs of receipt matching: a user's card charge missing a receipt, a receipt in their bin, and
# the shadow run that read it.
module ReceiptMatchSupport

  def create_card_charge(user:, amount_cents: -12_34)
    event = create(:event)
    stripe_card = create(:stripe_card, :with_stripe_id, stripe_cardholder: create(:stripe_cardholder, user:), event:)
    raw_pending_stripe_transaction = create(:raw_pending_stripe_transaction, stripe_card:, amount_cents:)
    canonical_pending_transaction = create(:canonical_pending_transaction, raw_pending_stripe_transaction:, amount_cents:, event:)
    canonical_pending_transaction.local_hcb_code.reload
  end

  def create_bin_receipt(user:, suggested_memo: nil)
    receipt = Receipt.new(user:, upload_method: :receipt_center)
    receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    receipt.save!
    receipt.update!(suggested_memo:, data_extracted: true) if suggested_memo
    receipt
  end

  # A finished shadow run in which the model picked `llm` (an HcbCode, or nil for none) and the Ruby matcher `ruby`.
  def create_match_run(receipt:, llm:, ruby: llm)
    run = ReceiptMatchRun.start!(receipt:, candidates: [])
    run.update!(request_id: "#{run.call_id}.1", reported_at: Time.current, ruby_hcb_code_hashid: ruby&.hashid,
                llm_hcb_code_hashid: llm&.hashid, agreed: ruby&.id == llm&.id)
    run
  end

end

RSpec.configure { |config| config.include ReceiptMatchSupport }
