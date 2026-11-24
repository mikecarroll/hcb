# frozen_string_literal: true

require "rails_helper"

RSpec.describe Receipt::SendMatchFeedbackJob do
  let(:user) { create(:user) }
  let(:receipt) { create_bin_receipt(user:) }
  let(:event) { ReceiptMatchEvent.create!(receipt:, kind: "suggestion_accepted") }
  let(:attributes) { { "client_unique_id" => "receipt-match:abc.1", "sentiment" => "like", "creator_type" => "human" } }
  let(:feedback_service) { instance_double(Coolhand::FeedbackService) }

  before do
    allow(Coolhand.configuration).to receive_messages(enabled: true, api_key: "key")
    allow(Coolhand).to receive(:flush)
    allow(Coolhand).to receive(:feedback_service).and_return(feedback_service)
  end

  it "sends the feedback to Coolhand and marks the event sent" do
    allow(feedback_service).to receive(:create_feedback).and_return({ id: 1 })

    described_class.perform_now(event.id, attributes)

    expect(feedback_service).to have_received(:create_feedback).with(client_unique_id: "receipt-match:abc.1", sentiment: "like", creator_type: "human")
    expect(Coolhand).to have_received(:flush) # the log it names may still be queued
    expect(event.reload.feedback_sent_at).to be_present
  end

  it "fails, to be retried, when Coolhand doesn't accept it" do
    allow(feedback_service).to receive(:create_feedback).and_return(nil)

    expect { described_class.perform_now(event.id, attributes) }.to have_enqueued_job(described_class)
    expect(event.reload.feedback_sent_at).to be_nil
  end

  it "still sends feedback for an event that went with its deleted receipt" do
    allow(feedback_service).to receive(:create_feedback).and_return({ id: 1 })

    expect { described_class.perform_now(0, attributes) }.not_to raise_error
    expect(feedback_service).to have_received(:create_feedback)
  end

  it "sends nothing when Coolhand isn't set up" do
    allow(Coolhand.configuration).to receive(:enabled).and_return(false)
    expect(feedback_service).not_to receive(:create_feedback)

    described_class.perform_now(event.id, attributes)
  end
end
