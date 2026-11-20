# frozen_string_literal: true

module ReceiptService
  # Compares the text extractor (ReceiptService::Extract.fields_from_text) with the vision one
  # (ReceiptService::VisionExtract) on receipts already attached to a card charge, using the charge as the answer:
  # the amount charged, its date (within a day), and the card's last four digits. Both extractors call the provider,
  # so a run takes a receipt limit and a token cap, and stops before the receipt that would start past the cap.
  # Nothing is saved: the receipts' stored extraction and text are left as they are.
  class ExtractionEval
    EXTRACTORS = %i[text vision].freeze
    FIELDS = %i[amount date card_last_four].freeze

    # Sums the token usage of the Squishling requests it wraps (see Squishling::Observer).
    class TokenMeter
      attr_reader :tokens

      def initialize
        @tokens = { input_tokens: 0, output_tokens: 0 }
      end

      def around(_call)
        usage = yield
        @tokens[:input_tokens] += usage.input_tokens.to_i
        @tokens[:output_tokens] += usage.output_tokens.to_i
      end

    end

    def initialize(from:, to:, limit:, max_tokens:)
      raise ArgumentError, "limit must be positive" unless limit.to_i.positive?
      raise ArgumentError, "max_tokens must be positive" unless max_tokens.to_i.positive?

      @from = from
      @to = to
      @limit = limit.to_i
      @max_tokens = max_tokens.to_i
    end

    def run
      tokens = EXTRACTORS.index_with { { input_tokens: 0, output_tokens: 0 } }
      rows = []
      stopped = false

      receipts.each do |receipt|
        break if rows.size >= @limit
        next unless (charge = receipt.hcb_code)&.card_charge?

        if tokens.values.sum { |used| used.values.sum } >= @max_tokens
          stopped = true
          break
        end

        rows << compare(receipt, charge, tokens)
      end

      { receipts: rows.size, stopped_on_token_cap: stopped, tokens:,
        fields: EXTRACTORS.index_with { |extractor| field_summary(rows, extractor) }, rows:
}
    end

    private

    def receipts
      Receipt.where(created_at: @from.beginning_of_day..@to.end_of_day, receiptable_type: "Ledger::Item")
             .with_attached_file
             .find_each
    end

    def compare(receipt, charge, tokens)
      text = receipt.textual_content || receipt.extract_textual_content[:text]
      text_fields = failures_as_errors do
        fields, used = ReceiptService::Extract.fields_from_text(text) if text.present?
        add(tokens[:text], used) if used
        fields
      end
      vision_fields = failures_as_errors do
        metered(tokens[:vision]) { ReceiptService::VisionExtract.fields_for(receipt, text:) }
      end

      { receipt_id: receipt.id, hcb_code_id: charge.id,
        text: outcomes(text_fields, charge), vision: outcomes(vision_fields, charge)
}
    end

    # A failed extraction counts as :error on every field, rather than ending the run.
    def failures_as_errors
      yield
    rescue Squishling::Error, Faraday::Error => e
      e
    end

    def metered(totals)
      meter = TokenMeter.new
      previous = Squishling.config.observer
      Squishling.configure { |config| config.observer = meter }
      yield
    ensure
      Squishling.configure { |config| config.observer = previous }
      add(totals, meter.tokens)
    end

    def add(totals, used)
      used.each { |key, count| totals[key] += count.to_i }
    end

    def outcomes(fields, charge)
      return FIELDS.index_with { :error } if fields.is_a?(Exception)

      fields = (fields || {}).with_indifferent_access
      {
        amount: outcome(fields[:total_amount_cents]) { |cents| cents.to_i.abs == charged_cents(charge) },
        date: outcome(fields[:date]) { |date| (Date.parse(date.to_s) - charged_on(charge)).abs <= 1 },
        card_last_four: outcome(fields[:card_last_four]) { |last4| last4.to_s == charge.card&.last4 },
      }
    end

    def outcome(value)
      return :missing if value.blank?

      yield(value) ? :correct : :wrong
    rescue Date::Error
      :wrong
    end

    def charged_cents(charge)
      merchant_amount = charge.pt&.raw_pending_stripe_transaction&.stripe_transaction&.[]("merchant_amount")
      (merchant_amount || charge.amount_cents).abs
    end

    def charged_on(charge)
      (charge.pt&.raw_pending_stripe_transaction&.created_at || charge.date).to_date
    end

    def field_summary(rows, extractor)
      FIELDS.index_with do |field|
        counts = rows.map { |row| row[extractor][field] }.tally
        { correct: counts.fetch(:correct, 0), wrong: counts.fetch(:wrong, 0), missing: counts.fetch(:missing, 0),
          error: counts.fetch(:error, 0),
          accuracy: rows.empty? ? nil : (counts.fetch(:correct, 0).to_f / rows.size).round(3)
}
      end
    end

  end
end
