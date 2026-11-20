# frozen_string_literal: true

class SuggestedPairing
  # Tells Coolhand what became of a suggestion, as feedback on the extraction
  # call it came from. The feedback finds that call by OpenAI's request ID.
  class CoolhandFeedbackJob < ApplicationJob
    queue_as :low
    discard_on ActiveJob::DeserializationError

    FEEDBACK = {
      "accepted" => {
        sentiment: "like",
        creator_type: "unknown",
        explanation: "The receipt was attached to the suggested transaction, by the user or automatically.",
      },
      "ignored"  => {
        sentiment: "dislike",
        creator_type: "human",
        explanation: "The user dismissed the suggested transaction for this receipt.",
      },
      "reversed" => {
        sentiment: "dislike",
        creator_type: "human",
        explanation: "The receipt had been attached to the suggested transaction, and the user moved it back to their receipt bin.",
      },
    }.freeze

    def perform(pairing, state)
      return if Coolhand.configuration.api_key.blank?

      request_id = pairing.receipt.extraction_request_id
      return if request_id.blank?

      Coolhand.feedback_service.create_feedback(
        llm_provider_unique_id: request_id,
        creator_unique_id: pairing.receipt.user&.public_id,
        **FEEDBACK.fetch(state)
      )
    end

  end

end
