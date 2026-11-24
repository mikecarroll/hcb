# frozen_string_literal: true

class Receipt
  # Sends what a person did with a receipt-matching suggestion to Coolhand as feedback on the LLM request it
  # concerns (see ReceiptMatchEvent#feedback). The model's request is logged in the background, so the feedback
  # waits for that to finish, and a failed send is retried because Coolhand's client reports failure only as nil.
  class SendMatchFeedbackJob < ApplicationJob
    class NotSent < StandardError; end

    queue_as :low
    retry_on NotSent, wait: 1.minute, attempts: 5

    def perform(event_id, attributes)
      return unless Coolhand.configuration.enabled && Coolhand.configuration.api_key.present?

      Coolhand.flush(timeout: 2) # the log the feedback names may still be queued
      raise NotSent, "Coolhand didn't accept the feedback" if Coolhand.feedback_service.create_feedback(attributes.symbolize_keys).nil?

      ReceiptMatchEvent.where(id: event_id).update_all(feedback_sent_at: Time.current) # the event is gone if its receipt was deleted
    end

  end

end
