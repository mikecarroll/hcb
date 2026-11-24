# frozen_string_literal: true

# Shared pieces of the receipt-matching experiment: ReceiptService::Match runs
# an LLM alongside the Ruby matcher (Squishling apprentice mode), and what people
# do with the suggestions is reported to Coolhand as feedback.
module ReceiptMatch
  FLAG = :receipt_match_apprentice_2026_11_24

  # Coolhand capture, the LLM shadow run, and feedback are all gated by this flag,
  # per receipt owner, because receipts and transactions hold personal data.
  def self.enabled_for?(user)
    user.present? && Flipper.enabled?(FLAG, user)
  end

  # Coolhand only captures what's inside this block (see config/initializers/coolhand.rb),
  # so other LLM calls, such as card grant pre-authorization, aren't sent to it.
  def self.capture(user, &)
    enabled_for?(user) ? Coolhand.with_capture(&) : yield
  end

  # Runs the block (ReceiptService::Extract's OpenAI call) as a Coolhand workload of its own, tagged with the
  # receipt's extract_client_id so feedback on the suggested memo can find the request. Captured only when
  # enabled_for? the receipt's owner.
  def self.extraction(receipt, &block)
    return yield unless enabled_for?(receipt.user)

    Coolhand.with_capture do
      Coolhand.with_context(
        reporter: "hcb",
        workload: { key: "ReceiptService::Extract#run!", name: "ReceiptService::Extract#run!", description: "Reads a receipt's text into structured fields and a suggested memo" },
        template: { key: "ReceiptService::Extract#run!/chat", name: "ReceiptService::Extract#run! · chat" },
        client_unique_id: extract_client_id(receipt),
        &block
      )
    end
  end

  # The Coolhand client_unique_id of the request that extracted a receipt's data
  # (see ReceiptService::Extract). Extraction runs once per receipt, so the id is stable.
  def self.extract_client_id(receipt)
    "receipt-extract:#{receipt.id}"
  end

end
