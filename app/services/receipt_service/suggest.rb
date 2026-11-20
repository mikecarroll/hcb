# frozen_string_literal: true

module ReceiptService
  class Suggest
    include Turbo::Streams::ActionHelper
    include Turbo::Streams::StreamName

    AUTO_ATTACH_MAX_DISTANCE = 20
    SUGGEST_MAX_DISTANCE = 50
    # Charges this much above the receipt's total still get partial credit, for
    # tips added after the receipt was printed.
    TIP_ALLOWANCE = 0.3
    # Candidates are charges created from this long before the receipt's date to
    # this long after it.
    DATE_WINDOW_BEFORE = 7.days
    DATE_WINDOW_AFTER = 30.days

    def initialize(receipt:)
      @receipt = receipt
    end

    def run!(include_details: false)
      return nil if user.nil?
      return nil unless @receipt.has_textual_content?

      @extracted = ::ReceiptService::Extract.new(receipt: @receipt).run!

      ranked = rank(potential_hcb_codes)

      if ranked.present?
        pairs = ranked.map do |pairing|
          {
            receipt_id: @receipt.id,
            hcb_code_id: pairing[:hcb_code].id,
            ledger_item_id: pairing[:hcb_code].ledger_item_id,
            distance: pairing[:distance],
            aasm_state: "unreviewed"
          }
        end

        pairings = SuggestedPairing.upsert_all(pairs, unique_by: [:receipt_id, :hcb_code_id])

        if @receipt.receiptable.nil?
          Turbo::StreamsChannel.broadcast_action_to([@receipt.user, :receipt_bin], action: :refresh_suggested_pairings)

          decision = decide(ranked)
          if decision[:action] == :auto_attach && decision[:hcb_code].missing_receipt? &&
             (pair = @receipt.suggested_pairings.unreviewed.find_by(hcb_code: decision[:hcb_code]))
            pair.mark_accepted!

            return pair
          end
        end

        pairings
      end
    end

    # The charges worth scoring for this receipt: those near its date, when it
    # has one.
    def candidates(hcb_codes, extracted: @extracted)
      date = extracted&.extracted_date&.to_date
      return hcb_codes if date.nil?

      hcb_codes.where(created_at: (date - DATE_WINDOW_BEFORE).beginning_of_day..(date + DATE_WINDOW_AFTER).end_of_day)
    end

    # Scores candidates against what was extracted from the receipt, closest
    # first. Nothing extracted means every candidate scores nil.
    def rank(hcb_codes, extracted: @extracted)
      hcb_codes.map do |hcb_code|
        features = extracted && features(hcb_code, extracted)
        { hcb_code:, features:, distance: features && distance_from(features) }
      end.sort_by { |pairing| [pairing[:distance] || Float::INFINITY, -pairing[:hcb_code].id] }
    end

    # What to do with a ranked list: :auto_attach (emailed receipts only),
    # :suggest, or :none. A tie for closest is never acted on.
    def decide(ranked)
      best, runner_up = ranked.first(2)
      return { action: :none } if best.nil? || best[:distance].nil?
      return { action: :none, tied: true } if runner_up && runner_up[:distance] == best[:distance]

      if @receipt.email_receipt_bin? && auto_attachable?(best)
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

    # Each feature's value runs from 0 (match) to 1 (miss). A nil value means
    # the receipt or the charge doesn't say, and the feature is left out of the
    # score rather than counted as a miss. The amount is always counted.
    def features(hcb_code, extracted)
      {
        amount_cents: { value: amount_value(hcb_code, extracted), weight: 200 },
        card_last_four: { value: card_value(hcb_code, extracted), weight: 200 },
        date: { value: date_value(hcb_code, extracted), weight: 100 },
        merchant_zip_code: { value: zip_value(hcb_code, extracted), weight: 50 },
        merchant_name: { value: merchant_name_value(hcb_code, extracted), weight: 50 },
      }
    end

    def distance_from(features)
      known = features.values.reject { |feature| feature[:value].nil? }

      value = known.sum { |feature| feature[:value] * feature[:weight] }.to_f
      weight = known.sum { |feature| feature[:weight] }.to_f

      value / weight * 100
    end

    def auto_attachable?(pairing)
      pairing[:distance] <= AUTO_ATTACH_MAX_DISTANCE &&
        pairing[:features][:amount_cents][:value].zero? &&
        pairing[:features][:card_last_four][:value]&.zero?
    end

    def amount_value(hcb_code, extracted)
      receipt_total = extracted.extracted_total_amount_cents&.abs
      return 1 if receipt_total.nil?

      merchant_amount = hcb_code.pt&.raw_pending_stripe_transaction&.stripe_transaction&.[]("merchant_amount")
      charged = (merchant_amount || hcb_code.amount_cents).abs

      if charged == receipt_total
        0
      elsif charged > receipt_total && charged <= receipt_total * (1 + TIP_ALLOWANCE)
        0.5
      else
        1
      end
    end

    def card_value(hcb_code, extracted)
      receipt_last4 = extracted.extracted_card_last4.presence
      card_last4 = hcb_code.card&.last4.presence
      return nil if receipt_last4.nil? || card_last4.nil?

      receipt_last4 == card_last4 ? 0 : 1
    end

    def date_value(hcb_code, extracted)
      return nil if extracted.extracted_date.blank?

      distance = ((hcb_code.pt&.raw_pending_stripe_transaction&.created_at || hcb_code.date).to_date - extracted.extracted_date.to_date).abs

      if distance <= 1
        0
      elsif distance <= 5
        0.2 + 0.8 * (distance / 5)
      else
        1
      end
    end

    def zip_value(hcb_code, extracted)
      receipt_zip = normalize_postcode(extracted.extracted_merchant_zip_code)
      stripe_zip = normalize_postcode(hcb_code.stripe_merchant&.[]("postal_code"))
      return nil if receipt_zip.nil? || stripe_zip.nil?

      if receipt_zip.match?(/\A\d{5}\z/) && stripe_zip.match?(/\A\d{5}\z/)
        distance = (stripe_zip.to_i - receipt_zip.to_i).abs
        if distance.zero?
          0
        elsif distance < 75
          0.5
        else
          1
        end
      else
        receipt_zip == stripe_zip ? 0 : 1
      end
    end

    # Many card networks report "00000" when they don't have a postal code
    # (https://mapofzipcodes.com/blog/00000-zip-code); treat it as unknown.
    def normalize_postcode(postcode)
      normalized = postcode.to_s.upcase.delete(" -")
      return nil if normalized.empty? || normalized.match?(/\A0+\z/)

      normalized.match?(/\A\d{9}\z/) ? normalized.first(5) : normalized
    end

    def merchant_name_value(hcb_code, extracted)
      receipt_name = extracted.extracted_merchant_name.presence&.downcase
      card_name = hcb_code.stripe_merchant&.[]("name").presence&.downcase
      return nil if receipt_name.nil? || card_name.nil?

      card_name.include?(receipt_name) ? 0 : 1
    end

    def user
      @receipt.user
    end

    def potential_hcb_codes
      candidates(user.transactions_missing_receipt)
    end

  end
end
