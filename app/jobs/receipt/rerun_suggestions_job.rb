# frozen_string_literal: true

class Receipt
  # A receipt uploaded before its charge posts was matched against charges that
  # didn't include it. When a card charge posts, this re-matches the
  # cardholder's receipt-bin receipts that could belong to it. Extraction is
  # never repeated: only receipts whose data was already extracted are
  # re-matched, so no extraction request is made.
  class RerunSuggestionsJob < ApplicationJob
    queue_as :low

    FLAG = :receipt_matching_rerun_on_new_charges
    RECENT_UPLOADS = 60.days
    MAX_RECEIPTS = 25

    def self.enqueue_for?(canonical_pending_transaction)
      canonical_pending_transaction.raw_pending_stripe_transaction_id.present? &&
        canonical_pending_transaction.amount_cents.negative? &&
        !Flipper[FLAG].off?
    end

    def perform(canonical_pending_transaction)
      user = canonical_pending_transaction.raw_pending_stripe_transaction&.stripe_card&.user
      return if user.nil? || !Flipper.enabled?(FLAG, user)

      hcb_code = canonical_pending_transaction.local_hcb_code
      return unless hcb_code&.missing_receipt?

      receipts(user, hcb_code.created_at.to_date).each do |receipt|
        ::ReceiptService::Suggest.new(receipt:).run!
      end
    end

    private

    # Receipts whose date window (see ReceiptService::Suggest#candidates) could
    # include a charge created on `charged_on`, or that have no date at all.
    def receipts(user, charged_on)
      window = (charged_on - ReceiptService::Suggest::DATE_WINDOW_AFTER).beginning_of_day..
               (charged_on + ReceiptService::Suggest::DATE_WINDOW_BEFORE).end_of_day

      extracted = Receipt.in_receipt_bin
                         .where(user:, data_extracted: true, created_at: RECENT_UPLOADS.ago..)
                         .where.not(textual_content_ciphertext: nil)

      extracted.where(extracted_date: window).or(extracted.where(extracted_date: nil))
               .order(created_at: :desc)
               .limit(MAX_RECEIPTS)
               .includes(:user)
    end

  end

end
