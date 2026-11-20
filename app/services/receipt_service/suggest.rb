# frozen_string_literal: true

module ReceiptService
  class Suggest
    include Turbo::Streams::ActionHelper
    include Turbo::Streams::StreamName

    AUTO_ATTACH_MAX_DISTANCE = 20
    SUGGEST_MAX_DISTANCE = 50

    def initialize(receipt:)
      @receipt = receipt
    end

    def run!(include_details: false)
      return nil if user.nil?
      return nil unless @receipt.has_textual_content?

      @extracted = ::ReceiptService::Extract.new(receipt: @receipt).run!

      pairings = rank(potential_hcb_codes)

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
          Turbo::StreamsChannel.broadcast_action_to([@receipt.user, :receipt_bin], action: :refresh_suggested_pairings)

          if @receipt.email_receipt_bin? && pair = @receipt.suggested_pairings
                                                           .unreviewed
                                                           .where("distance <= ?", AUTO_ATTACH_MAX_DISTANCE)
                                                           .order(:receipt_id, distance: :asc)
                                                           .select("DISTINCT ON (receipt_id) suggested_pairings.*")
                                                           .select { |pairing| pairing.hcb_code.missing_receipt? }
                                                           .first
            pair.mark_accepted!

            return pair
          end
        end

        pairings
      end
    end

    # The charges worth scoring for this receipt.
    def candidates(hcb_codes, extracted: @extracted)
      hcb_codes
    end

    # Scores candidates against what was extracted from the receipt, closest
    # first. Nothing extracted means every candidate scores nil.
    def rank(hcb_codes, extracted: @extracted)
      hcb_codes.map do |hcb_code|
        { hcb_code:, distance: extracted && distance_from(features(hcb_code, extracted)) }
      end.sort_by { |pairing| [pairing[:distance] || Float::INFINITY, -pairing[:hcb_code].id] }
    end

    # What run! and the receipt bin would do with a ranked list: :auto_attach
    # (emailed receipts only), :suggest, or :none.
    def decide(ranked)
      best = ranked.first
      return { action: :none } if best.nil? || best[:distance].nil?

      if @receipt.email_receipt_bin? && best[:distance] <= AUTO_ATTACH_MAX_DISTANCE
        { action: :auto_attach, hcb_code: best[:hcb_code] }
      elsif best[:distance] <= SUGGEST_MAX_DISTANCE
        { action: :suggest, hcb_code: best[:hcb_code] }
      else
        { action: :none }
      end
    end

    def distance(hcb_code)
      return if @extracted.nil?

      distance_from(features(hcb_code, @extracted))
    end

    private

    # Each feature's value runs from 0 (match) to 1 (miss); a nil value is left
    # out of the score.
    def features(hcb_code, extracted)
      merchant_amount = hcb_code.pt&.raw_pending_stripe_transaction&.stripe_transaction&.[]("merchant_amount")

      {
        amount_cents: {
          value: extracted.extracted_total_amount_cents && ((merchant_amount || hcb_code.amount_cents).abs - extracted.extracted_total_amount_cents.abs).abs == 0 ? 0 : 1,
          weight: 200,
        },
        card_last_four: {
          value: extracted.extracted_card_last4 == hcb_code.card&.last4 ? 0 : 1,
          weight: 200,
        },
        date: {
          value: begin
            if extracted.extracted_date.present?
              distance = ((hcb_code.pt&.raw_pending_stripe_transaction&.created_at || hcb_code.date).to_date - extracted.extracted_date.to_date).abs

              if distance <= 1
                0
              elsif distance <= 5
                0.2 + 0.8 * (distance / 5)
              else
                1
              end
            else
              1
            end
          end,
          weight: 100,
        },
        merchant_zip_code: {
          value: begin
            stripe_zip = hcb_code.stripe_merchant["postal_code"]
            if stripe_zip == "00000"
              nil
              # https://mapofzipcodes.com/blog/00000-zip-code
              # many postal codes are reported as 000000, and we don't
              # want a lack of information to hurt pairing suggestions
            else
              stripe_zip = stripe_zip.to_i
              receipt_zip = extracted.extracted_merchant_zip_code.to_i
              distance = (stripe_zip - receipt_zip).abs
              if distance.zero?
                0
              elsif distance < 75
                0.5
              else
                1
              end
            end
          end,
          weight: 50,
        },
        merchant_name: {
          value: extracted.extracted_merchant_name&.downcase&.in?(hcb_code.stripe_merchant["name"]&.downcase) ? 0 : 1,
          weight: 50,
        }
      }
    end

    def distance_from(features)
      known = features.values.reject { |feature| feature[:value].nil? }

      value = known.sum { |feature| feature[:value] * feature[:weight] }.to_f
      weight = known.sum { |feature| feature[:weight] }.to_f

      value / weight * 100
    end

    def user
      @receipt.user
    end

    def potential_hcb_codes
      candidates(user.transactions_missing_receipt)
    end

  end
end
