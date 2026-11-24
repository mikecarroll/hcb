# frozen_string_literal: true

# == Schema Information
#
# Table name: receipt_match_events
#
#  id                   :bigint           not null, primary key
#  feedback_sent_at     :datetime
#  human                :boolean          default(TRUE), not null
#  kind                 :string           not null
#  payload              :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  hcb_code_id          :bigint
#  receipt_id           :bigint           not null
#  receipt_match_run_id :bigint
#
# Indexes
#
#  index_receipt_match_events_on_receipt_id            (receipt_id)
#  index_receipt_match_events_on_receipt_match_run_id  (receipt_match_run_id)
#
# Foreign Keys
#
#  fk_rails_...  (receipt_id => receipts.id) ON DELETE => cascade
#  fk_rails_...  (receipt_match_run_id => receipt_match_runs.id) ON DELETE => nullify
#
# Something a person (or, for auto_attached, the system) did with a receipt-matching suggestion. Each human
# event is also sent to Coolhand as feedback on the LLM request it says something about (see #feedback and
# Receipt::SendMatchFeedbackJob): match events on ReceiptService::Match's request, memo events on the extraction
# request that wrote the receipt's suggested memo. Events are append-only, so they also serve as ground truth
# for evaluating matching.
class ReceiptMatchEvent < ApplicationRecord
  belongs_to :receipt
  belongs_to :receipt_match_run, optional: true # memo events don't depend on a match run

  MATCH_KINDS = %w[suggestion_accepted suggestion_ignored reversed manually_linked receipt_deleted auto_attached].freeze
  MEMO_KINDS = %w[memo_accepted memo_edited].freeze
  validates :kind, inclusion: { in: MATCH_KINDS + MEMO_KINDS }

  # The job is given the feedback itself rather than the event: deleting a receipt cascades to its events, and
  # the feedback on that deletion still has to go out.
  after_create_commit do
    attributes = feedback
    Receipt::SendMatchFeedbackJob.perform_later(id, attributes.deep_stringify_keys) if attributes.present?
  end

  # Records an event when ReceiptMatch is enabled for the receipt's owner and there is an LLM request for it to
  # be feedback on; otherwise it does nothing, so callers can call it unconditionally.
  # Recording is telemetry: it never fails what the person was doing.
  def self.record!(receipt:, kind:, hcb_code: nil, human: true, **payload)
    return unless ReceiptMatch.enabled_for?(receipt.user)

    run = receipt.receipt_match_runs.answered.order(:id).last
    if kind.to_s.in?(MEMO_KINDS)
      return unless receipt.data_extracted? && receipt.suggested_memo.present?
    elsif run.nil?
      return
    end

    create!(receipt:, receipt_match_run: run, kind:, hcb_code_id: hcb_code&.id, human:, payload:)
  rescue => e
    Rails.error.report(e, context: { receipt_id: receipt&.id, kind: }, handled: true)
    nil
  end

  # A person saved a memo on a transaction. If a receipt had suggested one and none was in use yet (the AI memo
  # icon was showing), keeping it as it was is accepting the suggestion, and anything else is editing it.
  def self.record_memo!(hcb_code:, previous_memo:, memo:)
    return if hcb_code.nil? || memo.blank? || previous_memo.present?

    receipt = hcb_code.receipts.where.not(suggested_memo: [nil, ""]).order(:id).last
    return if receipt.nil?

    if memo == receipt.suggested_memo
      record!(receipt:, kind: "memo_accepted", hcb_code:)
    else
      record!(receipt:, kind: "memo_edited", hcb_code:, memo:)
    end
  rescue => e
    Rails.error.report(e, context: { hcb_code_id: hcb_code&.id }, handled: true)
    nil
  end

  def hcb_code
    HcbCode.find_by(id: hcb_code_id) if hcb_code_id
  end

  # The attributes of the Coolhand feedback for this event, or nil when it says nothing about a request (a
  # system event, an ignored suggestion that wasn't the model's). The feedback is about the model's answer:
  # "like" when the person's choice is what the model picked, "dislike" with the person's choice as the revised
  # output when it isn't. Ignoring is only a weak negative, and only for the very transaction the model picked.
  def feedback
    return unless human

    attributes = kind.in?(MEMO_KINDS) ? memo_feedback : match_feedback
    attributes&.merge(creator_type: "human", creator_unique_id: "hcb-user:#{receipt.user.hashid}")
  end

  private

  def memo_feedback
    base = { client_unique_id: ReceiptMatch.extract_client_id(receipt) }
    case kind
    when "memo_accepted"
      base.merge(sentiment: "like", explanation: "The user kept the suggested memo as it was.")
    when "memo_edited"
      base.merge(sentiment: "dislike", explanation: "The user changed the suggested memo.", revised_output: payload.to_h.with_indifferent_access[:memo])
    end
  end

  def match_feedback
    return if receipt_match_run&.request_id.nil?

    chosen = hcb_code&.hashid
    picked = receipt_match_run.llm_hcb_code_hashid
    base = { client_unique_id: receipt_match_run.client_unique_id }

    case kind
    when "suggestion_accepted", "manually_linked"
      how = kind == "manually_linked" ? "attached the receipt to this transaction" : "accepted the suggestion for this transaction"
      return if chosen.nil?

      if picked == chosen
        base.merge(sentiment: "like", explanation: "The user #{how}, which is what the model picked.")
      else
        base.merge(sentiment: picked.nil? ? "neutral" : "dislike",
                   explanation: "The user #{how}; the model #{picked.nil? ? 'picked none' : 'picked a different one'}.",
                   revised_output: JSON.generate(hcb_code_id: chosen, confidence: 1.0, rationale: nil))
      end
    when "suggestion_ignored"
      base.merge(sentiment: "dislike", explanation: "The user ignored the suggestion for the transaction the model picked.") if picked.present? && picked == chosen
    when "reversed"
      base.merge(sentiment: "dislike", explanation: "The user undid the match to the transaction the model picked.") if picked.present? && picked == chosen
    when "receipt_deleted"
      if picked.nil?
        base.merge(sentiment: "neutral", explanation: "The user deleted the receipt from their bin; the model picked no transaction.")
      else
        base.merge(sentiment: "dislike", explanation: "The user deleted the receipt from their bin; the model picked a transaction.")
      end
    end
  end

end
