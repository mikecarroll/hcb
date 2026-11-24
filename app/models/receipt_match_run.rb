# frozen_string_literal: true

# == Schema Information
#
# Table name: receipt_match_runs
#
#  id                   :bigint           not null, primary key
#  agreed               :boolean
#  candidate_count      :integer
#  candidates_truncated :boolean          default(FALSE), not null
#  error_class          :string
#  llm_confidence       :float
#  llm_hcb_code_hashid  :string
#  llm_seconds          :float
#  model                :string
#  reported_at          :datetime
#  ruby_confidence      :float
#  ruby_hcb_code_hashid :string
#  ruby_seconds         :float
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  call_id              :string           not null
#  receipt_id           :bigint           not null
#  request_id           :string
#
# Indexes
#
#  index_receipt_match_runs_on_call_id     (call_id) UNIQUE
#  index_receipt_match_runs_on_receipt_id  (receipt_id)
#
# Foreign Keys
#
#  fk_rails_...  (receipt_id => receipts.id) ON DELETE => cascade
#
# The LLM shadow run of ReceiptService::Match for one receipt: what the Ruby matcher picked, what the model
# picked, and the Coolhand ids that tie them together. Started before the call (its call_id goes to
# Squishling.with_call_id) and completed by the apprentice report hook once the model has answered.
class ReceiptMatchRun < ApplicationRecord
  belongs_to :receipt
  has_many :events, class_name: "ReceiptMatchEvent", dependent: :nullify

  # Each user can have this many shadow runs an hour, so a bulk upload can't run up a bill.
  HOURLY_LIMIT_PER_USER = 20

  scope :reported, -> { where.not(reported_at: nil) }
  # The run's model request is known, so feedback can name it.
  scope :answered, -> { where.not(request_id: nil) }

  def self.start!(receipt:, candidates:, truncated: false)
    create!(receipt:, call_id: "receipt-match:#{SecureRandom.uuid}", candidate_count: candidates.size, candidates_truncated: truncated)
  end

  def self.under_limit?(user)
    joins(:receipt).where(receipts: { user_id: user.id }).where(created_at: 1.hour.ago..).count < HOURLY_LIMIT_PER_USER
  end

  # The apprentice report hook (see ReceiptService::Match). It runs when the shadow run ends, successfully or not.
  # The ids are hashids of HcbCode, which is how candidates are named to the model.
  def self.record_report!(ruby:, llm:, match:, error:, metadata:)
    run = find_by(call_id: metadata[:call_id])
    return if run.nil?

    run.update!(
      request_id: metadata[:request_id],
      model: metadata[:model],
      ruby_hcb_code_hashid: ruby.hcb_code_id,
      ruby_confidence: ruby.confidence,
      llm_hcb_code_hashid: llm&.hcb_code_id,
      llm_confidence: llm&.confidence,
      agreed: match,
      error_class: error&.class&.name,
      ruby_seconds: metadata[:ruby_seconds],
      llm_seconds: metadata[:llm_seconds],
      reported_at: Time.current
    )
  end

  # The Coolhand client_unique_id of the model request that answered, which feedback on its answer names.
  def client_unique_id
    request_id
  end

end
