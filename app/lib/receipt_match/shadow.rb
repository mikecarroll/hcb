# frozen_string_literal: true

module ReceiptMatch
  # Calls ReceiptService::Match, and decides whether the LLM should read the receipt alongside the Ruby matcher.
  # The Ruby answer is what's returned either way; a shadow run only produces a ReceiptMatchRun and Coolhand logs.
  module Shadow

    # The match: the ReceiptService::Match (which scores any candidate), the Ruby matcher's answer, and every
    # candidate, parallel to the hcb_codes it was built from.
    Matched = Struct.new(:match, :result, :hcb_codes, :candidates)

    # Runs the match. extracted: the receipt once ReceiptService::Extract has read it, or nil.
    # hcb_codes: the user's transactions missing a receipt, most recent first.
    def self.call(receipt:, extracted:, hcb_codes:)
      all = hcb_codes.map { |hcb_code| ReceiptService::Match.candidate(hcb_code) }
      offered = all.first(ReceiptService::Match::MAX_CANDIDATES)
      match = ReceiptService::Match.new(receipt:, extracted:)

      images = wanted?(receipt, offered) ? ReceiptMatch::Images.for(receipt) : []
      if images.empty?
        result = match.call(images:, candidates: offered)
      else
        run = ReceiptMatchRun.start!(receipt:, candidates: offered, truncated: all.size > offered.size)
        # The id names the call's requests in Coolhand ("<call_id>.<n>"), so feedback can find them later.
        result = Squishling.with_call_id(run.call_id) { match.call(images:, candidates: offered) }
      end

      Matched.new(match, result, hcb_codes, all)
    end

    # The LLM only reads receipts that are still in the receipt bin, for people the experiment is on for, with
    # something to match against, and not in bulk.
    def self.wanted?(receipt, candidates)
      candidates.any? &&
        ReceiptMatch.enabled_for?(receipt.user) &&
        Receipt.in_receipt_bin.exists?(receipt.id) &&
        ReceiptMatchRun.under_limit?(receipt.user)
    end

  end

end
