# frozen_string_literal: true

module ReceiptService
  # Which of a user's card charges that are missing a receipt does a receipt belong to?
  #
  # This is a Squishling class in apprentice mode (https://github.com/Coolhand-Labs/squishling): the Ruby
  # implementation below answers every call, exactly as the receipt bin's suggestions always have, and when
  # `shadow` runs the LLM reads the receipt's image alongside it, on the same candidates. The two answers are
  # compared and reported to Coolhand, so the model can be measured against this code before it serves anything.
  # See dev-docs/guides/receipt_matching.md.
  #
  # The LLM gets the receipt's image and the candidates, and nothing the OCR or the extraction produced, so
  # the two paths are independent readings of the same receipt. The Ruby path reads what ReceiptService::Extract
  # saved on the receipt, which is held on the instance and never sent.
  class Match
    include Squishling

    # The farthest a candidate may be from the receipt and still be suggested (the receipt bin's threshold).
    MAX_DISTANCE = 50

    # Candidates beyond this many (most recent first) aren't offered to either path.
    MAX_CANDIDATES = 200

    squishling model: "gpt-5.6-terra",
               apprentice: {
                 # Shadow runs are decided by ReceiptMatch::Shadow, which only passes images when one should run.
                 when: ->(images:, **) { images.any? },
                 # Both paths agree when they pick the same transaction (or both pick none).
                 compare: ->(ruby, llm, **) { ruby.hcb_code_id == llm.hcb_code_id },
                 report: ->(ruby:, llm:, match:, error:, metadata:, **) {
                   ReceiptMatchRun.record_report!(ruby:, llm:, match:, error:, metadata:)
                 }
               }

    purpose <<~PURPOSE
      A user uploaded the attached receipt (an image of a receipt, invoice, or order confirmation) to their receipt
      bin. Decide which of the candidate card transactions it belongs to, or that it belongs to none of them.

      Read the merchant, the total (including tip and tax), the date, the last four digits of the card, and the
      merchant's postal code from the receipt, and compare them with each candidate. Card statements often show a
      different merchant name than the receipt does, and a transaction's amount can differ from the receipt's total
      (tips, foreign currency), so weigh all of the evidence together.

      Precision matters much more than coverage: attaching a receipt to the wrong transaction is far worse than
      suggesting nothing. Choose a candidate only when you are confident, and otherwise return no transaction.
    PURPOSE

    append_to_purpose "The Ruby implementation that answers this call today, which your answer is compared against:", self

    output_schema do
      optional :hcb_code_id, description: "The hcb_code_id of the matching candidate, or null when none of them matches." do
        string
      end
      number :confidence, description: "How likely it is that the chosen candidate is the right one, from 0 to 1. Use 0 when there is no match."
      optional :rationale, description: "One short sentence on what decided it. Don't repeat card numbers or addresses." do
        string
      end
    end

    # receipt: the receipt being matched. extracted: the receipt once ReceiptService::Extract has read it, or nil
    # when it hasn't (nothing to compare then).
    def initialize(receipt:, extracted: receipt)
      @receipt = receipt
      @extracted = extracted
    end

    # images: the receipt's pages, for the LLM (the Ruby path ignores them; they are empty unless a shadow run
    # should happen). candidates: Match.candidate for each of the user's charges missing a receipt.
    def call(images:, candidates:)
      best, best_distance = candidates.each_with_index
                                      .filter_map { |candidate, index| (d = distance(candidate)) && [candidate, d, index] }
                                      .select { |_, d, _| d <= MAX_DISTANCE }
                                      .min_by { |_, d, index| [d, index] } # ties go to the first candidate, not an arbitrary one
                                      &.then { |candidate, d, _| [candidate, d] }

      {
        hcb_code_id: best&.fetch(:hcb_code_id),
        confidence: best ? (1 - best_distance / 100.0).round(3) : 0.0,
        rationale: nil
      }
    end

    # A candidate charge as plain data (it is sent to the LLM as JSON, so never an ActiveRecord object).
    def self.candidate(hcb_code)
      stripe_merchant = hcb_code.stripe_merchant || {}

      {
        hcb_code_id: hcb_code.hashid,
        amount_cents: hcb_code.amount_cents, # negative: money out of the organization
        merchant_amount_cents: hcb_code.pt&.raw_pending_stripe_transaction&.stripe_transaction&.[]("merchant_amount"), # in the merchant's currency
        date: (hcb_code.pt&.raw_pending_stripe_transaction&.created_at || hcb_code.date).to_date,
        card_last4: hcb_code.card&.last4,
        merchant_name: stripe_merchant["name"],
        merchant_zip: stripe_merchant["postal_code"],
        memo: hcb_code.memo
      }
    end

    # How far a candidate is from the receipt, from 0 (every check passes) to 100 (none does): the weighted share
    # of checks that miss. A check that can't be made (a card that reports no postal code) doesn't count.
    # Nil when the receipt hasn't been read. Also used to rank every candidate for the receipt bin.
    def distance(candidate)
      return if @extracted.nil?

      distances = {
        amount_cents: {
          value: @extracted.extracted_total_amount_cents && ((candidate[:merchant_amount_cents] || candidate[:amount_cents]).abs - @extracted.extracted_total_amount_cents.abs).abs == 0 ? 0 : 1,
          weight: 200,
        },
        card_last_four: {
          value: @extracted.extracted_card_last4 == candidate[:card_last4] ? 0 : 1,
          weight: 200,
        },
        date: {
          value: begin
            if @extracted.extracted_date.present?
              days = (candidate[:date] - @extracted.extracted_date.to_date).abs

              if days <= 1
                0
              elsif days <= 5
                0.2 + 0.8 * (days / 5)
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
            card_zip = candidate[:merchant_zip]
            if card_zip == "00000"
              nil
              # https://mapofzipcodes.com/blog/00000-zip-code
              # many postal codes are reported as 000000, and we don't
              # want a lack of information to hurt pairing suggestions
            else
              zip_distance = (card_zip.to_i - @extracted.extracted_merchant_zip_code.to_i).abs
              if zip_distance.zero?
                0
              elsif zip_distance < 75
                0.5
              else
                1
              end
            end
          end,
          weight: 50,
        },
        merchant_name: {
          # the receipt's name is found inside the name the card statement shows
          value: @extracted.extracted_merchant_name && candidate[:merchant_name].to_s.downcase.include?(@extracted.extracted_merchant_name.downcase) ? 0 : 1,
          weight: 50,
        }
      }

      features = distances.values.reject { |data| data[:value].nil? }

      value = features.map { |data| data[:value] * data[:weight] }.sum.to_f
      weight = features.map { |data| data[:weight] }.sum.to_f

      value / weight * 100
    end

  end
end
