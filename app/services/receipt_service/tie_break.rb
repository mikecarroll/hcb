# frozen_string_literal: true

module ReceiptService
  # Asks a model which of a few equally plausible card charges a receipt is for.
  # Only ever used to choose a suggestion the user then confirms.
  class TieBreak
    include Squishling

    MODEL = Credentials.fetch(:RECEIPT_MATCHING, :TIEBREAK_MODEL, fallback: "gpt-5.6-luna")

    squishling escalation: [{ model: MODEL, attempts: 2 }]

    purpose <<~PURPOSE
      A receipt was uploaded without saying which card charge it's for, and several of the uploader's charges match
      it about equally well. Pick the charge the receipt is for, or none if you can't tell them apart from the
      evidence. Merchant names on card statements are often abbreviated or prefixed (e.g. "SQ *", "TST*",
      "AMZN Mktp US*"), and a charge can be higher than the receipt's total when a tip was added afterwards.
    PURPOSE

    output_schema do
      optional(:hcb_code_id, description: "The hcb_code_id of the charge the receipt is for, exactly as given; null if none clearly is.") { integer }
      string :reason, description: "One short sentence on what decided it."
    end

    squish_validate do |result, candidates:, **|
      ids = candidates.map { |candidate| candidate[:hcb_code_id] }
      "hcb_code_id must be null or one of #{ids.join(", ")}" unless result.hcb_code_id.nil? || ids.include?(result.hcb_code_id)
    end

    def self.input_for(receipt:, ranked:)
      {
        receipt: {
          total_cents: receipt.extracted_total_amount_cents,
          currency: receipt.extracted_currency,
          card_last4: receipt.extracted_card_last4,
          date: receipt.extracted_date&.to_date&.iso8601,
          merchant_name: receipt.extracted_merchant_name,
          merchant_url: receipt.extracted_merchant_url,
          merchant_zip_code: receipt.extracted_merchant_zip_code,
        },
        candidates: ranked.map { |pairing| candidate(pairing[:hcb_code]) },
      }
    end

    def self.candidate(hcb_code)
      stripe_transaction = hcb_code.pt&.raw_pending_stripe_transaction&.stripe_transaction || {}
      merchant = hcb_code.stripe_merchant || {}

      {
        hcb_code_id: hcb_code.id,
        amount_cents: hcb_code.amount_cents.abs,
        merchant_amount_cents: stripe_transaction["merchant_amount"]&.abs,
        merchant_currency: stripe_transaction["merchant_currency"]&.upcase,
        date: hcb_code.date&.iso8601,
        card_last4: hcb_code.card&.last4,
        merchant_name: merchant["name"],
        merchant_city: merchant["city"],
        merchant_postal_code: merchant["postal_code"],
      }
    end

  end
end
