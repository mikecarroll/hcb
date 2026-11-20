# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::Extract do
  def build_receipt(**attributes)
    user = create(:user)
    Receipt.new(upload_method: :api, user:, textual_content: "some receipt text", **attributes).tap do |receipt|
      receipt.file.attach(
        io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/receipt.png"))),
        filename: "receipt.png",
        content_type: "image/png"
      )
      receipt.save!
    end
  end

  let(:extracted_data) do
    {
      transaction_memo: "☕ Coffee from Cafe",
      total_amount_cents: 500,
      currency: "usd"
    }
  end

  let(:ai_response_body) do
    {
      choices: [
        {
          message: {
            content: extracted_data.to_json
          }
        }
      ]
    }.to_json
  end

  before do
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: ai_response_body, headers: { "Content-Type" => "application/json" })
  end

  it "persists the extracted data onto the receipt" do
    receipt = build_receipt

    described_class.new(receipt:).run!

    receipt.reload
    expect(receipt.data_extracted?).to be(true)
    expect(receipt.suggested_memo).to eq("☕ Coffee from Cafe")
  end

  # Broadcasting through the HcbCode model made Turbo add an `hcb_code` local,
  # which the ledger item partial's strict `(item:)` locals rejected, so the
  # broadcast job raised ActionView::Template::Error.
  it "broadcasts the AI memo suggestion to a linked ledger item without error" do
    ledger_item = create(:ledger_item)
    hcb_code = create(:hcb_code, ledger_item:)
    receipt = build_receipt(receiptable: hcb_code)

    expect {
      perform_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
        described_class.new(receipt:).run!
      end
    }.not_to raise_error
  end

  # The OpenAI request above is slow enough that a user can delete the
  # receipt (or its file) from under the job while it's in flight. Before the
  # fix, the final `@receipt.update!` would re-validate `attached: true`
  # against the now-gone attachment and raise ActiveRecord::RecordInvalid
  # ("File can't be blank") instead of just no-oping.
  it "does not raise when the receipt is deleted while the extraction request is in flight" do
    receipt = build_receipt

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return do |_request|
        # simulate a separate request (e.g. the user deleting the receipt from
        # the UI) racing the job, rather than mutating the job's own in-memory
        # object directly
        Receipt.find(receipt.id).destroy!
        { status: 200, body: ai_response_body, headers: { "Content-Type" => "application/json" } }
      end

    expect { described_class.new(receipt:).run! }.not_to raise_error
    expect(Receipt.exists?(receipt.id)).to be(false)
  end

  context "with vision extraction on for the uploader" do
    it "reads the receipt with the vision extractor instead of the text model" do
      receipt = build_receipt
      Flipper.enable(:receipt_vision_extraction_2026_11_20, receipt.user)
      allow(ReceiptService::VisionExtract).to receive(:fields_for)
        .and_return({ total_amount_cents: 12_34, currency: "usd", transaction_memo: "🧾 Lunch" }.with_indifferent_access)

      described_class.new(receipt:).run!

      expect(ReceiptService::VisionExtract).to have_received(:fields_for).with(receipt, text: "some receipt text")
      expect(receipt.reload).to have_attributes(extracted_total_amount_cents: 12_34, extracted_currency: "USD",
                                                suggested_memo: "🧾 Lunch", data_extracted: true)
      expect(a_request(:post, "https://api.openai.com/v1/chat/completions")).not_to have_been_made
    end

    it "reads a receipt with no text, which the text model would skip" do
      receipt = build_receipt(textual_content: nil)
      Flipper.enable(:receipt_vision_extraction_2026_11_20, receipt.user)
      allow_any_instance_of(Receipt).to receive(:extract_textual_content!).and_return({ text: nil })
      allow(ReceiptService::VisionExtract).to receive(:fields_for)
        .and_return({ total_amount_cents: 5_00 }.with_indifferent_access)

      described_class.new(receipt:).run!

      expect(receipt.reload.extracted_total_amount_cents).to eq(5_00)
    end
  end
end
