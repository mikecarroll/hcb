# frozen_string_literal: true

module ReceiptService
  # Past receipt-bin uploads, and the card charges each one could have matched
  # when it was uploaded.
  class MatchingHistory
    RECEIPT_BIN_UPLOAD_METHODS = %w[
      receipts_page receipts_page_drag_and_drop receipt_center receipt_center_drag_and_drop email_receipt_bin sms
    ].freeze

    def initialize(from:, to:, upload_methods: RECEIPT_BIN_UPLOAD_METHODS)
      @from = from
      @to = to
      @upload_methods = upload_methods
    end

    def receipts
      Receipt.where(upload_method: @upload_methods, created_at: @from.beginning_of_day..@to.end_of_day)
             .where.not(user_id: nil)
             .includes(:suggested_pairings)
    end

    # The uploader's card charges that existed and had no receipt when this
    # receipt was uploaded. Receipts don't record when they were attached, so a
    # receipt's upload time stands in for its attach time.
    def candidates_at(receipt)
      uploaded_at = receipt.created_at
      cards = receipt.user.stripe_cards.includes(event: :plan).where.not(plan: { type: Event::Plan::SalaryAccount.name })

      earlier_receipt_sql = Receipt.select("1")
                                   .where("receipts.receiptable_type = 'Ledger::Item' AND receipts.receiptable_id = hcb_codes.ledger_item_id")
                                   .where("receipts.created_at < ?", uploaded_at)
                                   .where.not(id: receipt.id)
                                   .to_sql

      HcbCode.where(hcb_code: cards.flat_map(&:all_hcb_codes))
             .receipt_required
             .where("hcb_codes.created_at <= ?", uploaded_at)
             .where("hcb_codes.marked_no_or_lost_receipt_at IS NULL OR hcb_codes.marked_no_or_lost_receipt_at > ?", uploaded_at)
             .where("NOT EXISTS (#{earlier_receipt_sql})")
             .distinct
    end

  end
end
