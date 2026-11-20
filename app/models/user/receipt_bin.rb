# frozen_string_literal: true

class User
  class ReceiptBin
    def initialize(user)
      @user = user
    end

    def suggested_receipt_pairings
      @receipts = Receipt.in_receipt_bin.where(user: @user)
      # Don't suggest receipts ignored more than twice
      ineligible_receipt_ids = SuggestedPairing.ignored.group("receipt_id").having("COUNT(*) >= 2").pluck(:receipt_id)

      ranked = SuggestedPairing
               .unreviewed
               .where(receipt_id: @receipts.ids - ineligible_receipt_ids)
               .where("distance <= ?", ReceiptService::Suggest::SUGGEST_MAX_DISTANCE)
               .select("suggested_pairings.*",
                       "RANK() OVER (PARTITION BY receipt_id ORDER BY distance) AS distance_rank",
                       "COUNT(*) OVER (PARTITION BY receipt_id, distance) AS distance_ties")

      # Only the closest pairing for each receipt, and none when two are
      # equally close: picking one of a tie would be a guess.
      SuggestedPairing
        .from(ranked, :suggested_pairings)
        .where(distance_rank: 1, distance_ties: 1)
        .order(:receipt_id)
        .select { |pairing| pairing.hcb_code.missing_receipt? }
    end

  end

end
