# frozen_string_literal: true

module ReceiptService
  # Scores receipt matching on past receipt-bin uploads. Each receipt gets an
  # outcome per system, and each outcome is worth the points given in `points`
  # (one value per key in OUTCOMES).
  #
  # The systems:
  # - online: what users actually did with the suggestions they were shown
  # - stored: what the matcher decided at upload time, from the saved distances
  # - replayed: what ReceiptService::Suggest decides now, on the transactions
  #   that were missing a receipt when the receipt was uploaded
  #
  # stored and replayed assume a right suggestion is accepted and a wrong one is
  # caught. Compare them with each other, and use online to see how far that
  # assumption is from real behaviour.
  class MatchingReplay
    OUTCOMES = %i[right_attach right_suggest none ignored_right wrong_suggest wrong_attach].freeze

    def initialize(from:, to:, points:, upload_methods: MatchingHistory::RECEIPT_BIN_UPLOAD_METHODS)
      missing = OUTCOMES - points.keys.map(&:to_sym)
      raise ArgumentError, "points are missing #{missing.join(", ")}" if missing.any?

      @history = MatchingHistory.new(from:, to:, upload_methods:)
      @points = points.transform_keys(&:to_sym)
    end

    def run
      rows = @history.receipts.find_each.map { |receipt| replay(receipt) }

      {
        receipts: rows.size,
        truth_posted_after_upload: rows.count { |row| row[:truth_hcb_code_id] && !row[:truth_was_candidate] },
        scores: %i[online stored replayed].index_with { |system| score(rows.pluck(system)) },
        rows:,
      }
    end

    def replay(receipt)
      truth = receipt.hcb_code
      candidates = @history.candidates_at(receipt)

      suggest = ReceiptService::Suggest.new(receipt:)
      extracted = receipt if receipt.data_extracted?
      ranked = suggest.rank(suggest.candidates(candidates, extracted:), extracted:)

      {
        receipt_id: receipt.id,
        upload_method: receipt.upload_method,
        truth_hcb_code_id: truth&.id,
        truth_was_candidate: truth.present? && candidates.exists?(id: truth.id),
        online: online_outcome(receipt, truth),
        stored: proxy_outcome(stored_decision(receipt), truth),
        replayed: proxy_outcome(suggest.decide(ranked), truth),
      }
    end

    private

    def score(outcomes)
      scored = outcomes.reject { |outcome| outcome == :unknown }
      points = scored.sum { |outcome| @points.fetch(outcome) }

      {
        score: scored.empty? ? nil : (points.to_f / scored.size * 100).round(1),
        scored: scored.size,
        no_ground_truth: outcomes.size - scored.size,
        outcomes: scored.tally,
      }
    end

    def online_outcome(receipt, truth)
      pairings = receipt.suggested_pairings

      if (reversed = pairings.find { |pairing| pairing.aasm_state == "reversed" })
        reversed.hcb_code_id == truth&.id ? :none : :wrong_attach
      elsif (accepted = pairings.find { |pairing| pairing.aasm_state == "accepted" })
        accepted.hcb_code_id == truth&.id ? :right_attach : :wrong_attach
      elsif truth.nil?
        :unknown
      elsif (ignored = pairings.select { |pairing| pairing.aasm_state == "ignored" }).any?
        ignored.any? { |pairing| pairing.hcb_code_id == truth.id } ? :ignored_right : :wrong_suggest
      else
        :none
      end
    end

    def stored_decision(receipt)
      best = receipt.suggested_pairings.reject { |pairing| pairing.distance.nil? }.min_by { |pairing| [pairing.distance, pairing.id] }

      if best.nil?
        { action: :none }
      elsif receipt.email_receipt_bin? && best.distance <= ReceiptService::Suggest::AUTO_ATTACH_MAX_DISTANCE
        { action: :auto_attach, hcb_code: best.hcb_code }
      elsif best.distance <= ReceiptService::Suggest::SUGGEST_MAX_DISTANCE
        { action: :suggest, hcb_code: best.hcb_code }
      else
        { action: :none }
      end
    end

    def proxy_outcome(decision, truth)
      return :unknown if truth.nil?

      case decision[:action]
      when :auto_attach then decision[:hcb_code].id == truth.id ? :right_attach : :wrong_attach
      when :suggest then decision[:hcb_code].id == truth.id ? :right_suggest : :wrong_suggest
      else :none
      end
    end

  end
end
