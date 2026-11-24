# frozen_string_literal: true

require "rails_helper"

# The wiring end to end, with the real Squishling adapter, observer and Coolhand client, and only the HTTP
# endpoints stubbed: the model request carries a call id we chose, Coolhand logs it under that id, and the
# comparison with the Ruby matcher is sent as feedback on the same request.
RSpec.describe "Receipt matching with Coolhand" do
  let(:user) { create(:user) }
  let(:image) { Squishling::Image.new(data: File.binread(file_fixture("receipt.png"))) }
  let(:coolhand_logs) { [] }
  let(:coolhand_feedback) { [] }

  let!(:hcb_code) { create_card_charge(user:) }
  let(:receipt) do
    receipt = create_bin_receipt(user:)
    receipt.update!(extracted_total_amount_cents: 12_34, extracted_card_last4: hcb_code.card.last4, extracted_date: hcb_code.date,
                    extracted_merchant_name: "merchant 1", data_extracted: true)
    receipt
  end

  def model_reply(hcb_code_id)
    { choices: [{ message: { content: { hcb_code_id:, confidence: 0.9, rationale: nil }.to_json } }], model: "gpt-5.6-terra-2026-07-09",
      usage: { prompt_tokens: 100, completion_tokens: 10 }
}.to_json
  end

  before do
    Flipper.enable(ReceiptMatch::FLAG)
    allow(ReceiptMatch::Images).to receive(:for).and_return([image])
    allow(Credentials).to receive(:fetch).and_call_original
    allow(Credentials).to receive(:fetch).with(:OPENAI, :RECEIPT_EXTRACTION).and_return("sk-test")

    Coolhand.configure do |config|
      config.api_key = "coolhand-test"
      config.enabled = true
      config.capture = false # as in config/initializers/coolhand.rb
      config.silent = true
    end
    Squishling.configure do |config|
      config.adapter = { type: :openai_compatible, base_url: "https://api.openai.com/v1", api_key: -> { Credentials.fetch(:OPENAI, :RECEIPT_EXTRACTION) }, default_model: "gpt-5.6-terra" }
      config.observer = ReceiptMatch::Observer.new
    end

    stub_request(:post, /coolhandlabs.com\/api\/v2\/llm_request_logs\z/).to_return do |request|
      coolhand_logs << JSON.parse(request.body)
      { status: 200, body: { id: 1 }.to_json }
    end
    stub_request(:post, /coolhandlabs.com\/api\/v2\/llm_request_log_feedbacks\z/).to_return do |request|
      coolhand_feedback << JSON.parse(request.body)
      { status: 200, body: { id: 2 }.to_json }
    end
  end

  after do
    Coolhand::NetHttpInterceptor.unpatch!
    Coolhand.configuration.enabled = false
    Squishling.configure { |config| config.observer = false }
  end

  it "tags the model request with the run's call id and sends the comparison as feedback on it" do
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(status: 200, body: model_reply("not-the-charge"), headers: { "Content-Type" => "application/json" })

    ReceiptMatch::Shadow.call(receipt:, extracted: receipt, hcb_codes: [hcb_code])
    Coolhand.flush

    run = ReceiptMatchRun.sole
    expect(run.request_id).to eq("#{run.call_id}.1")

    log = coolhand_logs.sole.fetch("llm_request_log")
    expect(log["client_unique_id"]).to eq(run.request_id)
    expect(log.dig("declared", "workload", "key")).to eq("ReceiptService::Match#call")

    feedback = coolhand_feedback.sole.fetch("llm_request_log_feedback")
    expect(feedback).to include("client_unique_id" => run.request_id, "sentiment" => "dislike")
    expect(JSON.parse(feedback["revised_output"])).to include("hcb_code_id" => hcb_code.hashid) # the Ruby matcher's pick
  end

  it "sends nothing to Coolhand for a receipt whose owner isn't in the experiment" do
    Flipper.disable(ReceiptMatch::FLAG)

    ReceiptMatch::Shadow.call(receipt:, extracted: receipt, hcb_codes: [hcb_code])
    Coolhand.flush

    expect(coolhand_logs).to be_empty
    expect(coolhand_feedback).to be_empty
  end
end
