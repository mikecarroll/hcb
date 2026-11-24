# frozen_string_literal: true

module ReceiptService
  # Reads a receipt (ReceiptService::Extract), then finds the user's transactions it could belong to
  # (ReceiptService::Match), and saves a SuggestedPairing for each. A receipt sent by email that matches
  # closely enough is attached automatically.
  class Suggest
    include Turbo::Streams::ActionHelper
    include Turbo::Streams::StreamName

    # An email receipt this close to a transaction is attached to it without asking.
    AUTO_ATTACH_DISTANCE = 20

    def initialize(receipt:)
      @receipt = receipt
    end

    def run!(include_details: false)
      return nil if user.nil?

      has_text = @receipt.has_textual_content?
      @extracted = ::ReceiptService::Extract.new(receipt: @receipt).run! if has_text

      # Matching is for receipts in the receipt bin; one that's already on a transaction has nothing to match.
      return nil unless Receipt.in_receipt_bin.exists?(@receipt.id)

      # Even a receipt the OCR couldn't read goes through the match, so the model can read its image.
      matched = ::ReceiptMatch::Shadow.call(receipt: @receipt, extracted: @extracted, hcb_codes: potential_hcb_codes.to_a)
      return nil unless has_text

      pairings = matched.hcb_codes.zip(matched.candidates).map do |hcb_code, candidate|
        { hcb_code:, distance: matched.match.distance(candidate) }
      end

      if pairings.present?
        pairs = pairings.map do |pairing|
          {
            receipt_id: @receipt.id,
            hcb_code_id: pairing[:hcb_code].id,
            ledger_item_id: pairing[:hcb_code].ledger_item_id,
            distance: pairing[:distance],
            aasm_state: "unreviewed"
          }
        end

        pairings = SuggestedPairing.upsert_all(pairs, unique_by: [:receipt_id, :hcb_code_id]) if pairs.any?

        if @receipt.receiptable.nil?
          content = turbo_stream_action_tag(:refresh_suggested_pairings)
          Turbo::StreamsChannel.broadcast_action_to([@receipt.user, :receipt_bin], action: :refresh_suggested_pairings)

          if @receipt.email_receipt_bin? && pair = @receipt.suggested_pairings
                                                           .unreviewed
                                                           .where("distance <= ?", AUTO_ATTACH_DISTANCE)
                                                           .order(:receipt_id, distance: :asc)
                                                           .select("DISTINCT ON (receipt_id) suggested_pairings.*")
                                                           .select { |pairing| pairing.hcb_code.missing_receipt? }
                                                           .first
            pair.mark_accepted!
            ReceiptMatchEvent.record!(receipt: @receipt, kind: "auto_attached", hcb_code: pair.hcb_code, human: false)

            return pair
          end
        end

        pairings
      end
    end

    private

    def user
      @receipt.user
    end

    def potential_hcb_codes
      user.transactions_missing_receipt
    end

  end
end
