# frozen_string_literal: true

require "rails_helper"

RSpec.describe SuggestedPairing::CoolhandFeedbackJob do
  let(:user) { create(:user) }
  let(:receipt) do
    Receipt.new(user:, upload_method: :receipt_center, extraction_request_id: "req_123").tap do |receipt|
      receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
      receipt.save!
    end
  end
  let(:pairing) { SuggestedPairing.create!(receipt:, hcb_code: create(:canonical_pending_transaction).local_hcb_code, distance: 1) }
  let(:feedback_service) { instance_double(Coolhand::FeedbackService, create_feedback: nil) }

  before { allow(Coolhand).to receive(:feedback_service).and_return(feedback_service) }
  after { Coolhand.reset_configuration! }

  context "with Coolhand configured" do
    before { Coolhand.configuration.api_key = "test-key" }

    it "sends feedback linked to the extraction call by OpenAI's request ID" do
      described_class.perform_now(pairing, "reversed")

      expect(feedback_service).to have_received(:create_feedback).with(
        hash_including(llm_provider_unique_id: "req_123", sentiment: "dislike", creator_type: "human", creator_unique_id: user.public_id)
      )
    end

    it "sends nothing for a receipt extracted before request IDs were saved" do
      receipt.update!(extraction_request_id: nil)

      described_class.perform_now(pairing, "accepted")

      expect(feedback_service).not_to have_received(:create_feedback)
    end
  end

  it "sends nothing without a Coolhand API key" do
    described_class.perform_now(pairing, "accepted")

    expect(feedback_service).not_to have_received(:create_feedback)
  end
end
