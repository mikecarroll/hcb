# frozen_string_literal: true

require "rails_helper"
require "squishling/testing"
require "squishling/rspec"

RSpec.describe ReceiptService::VisionExtract do
  include Squishling::Testing::RSpec

  let(:receipt) do
    Receipt.new(user: create(:user), upload_method: :receipt_center).tap do |receipt|
      receipt.file.attach(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
      receipt.save!
    end
  end

  let(:reply) do
    Squishling::Testing.valid_reply_for(described_class, is_receipt: true, total_amount_cents: 12_34,
                                                         currency: nil, card_last_four: "4242", date: "2026-11-05")
  end

  it "has a valid squishling definition" do
    expect(described_class).to be_squishling_valid
  end

  it "reads the receipt from its image, as a PNG, with any text already extracted" do
    fake = fake_squishling { |llm| llm.step(:any).reply(reply) }

    fields = described_class.fields_for(receipt, text: "TOTAL 12.34")

    expect(fields).to include(total_amount_cents: 12_34, card_last_four: "4242", date: "2026-11-05")
    expect(fields).not_to have_key(:is_receipt)
    request = fake.requests.first
    expect(request.images.map(&:media_type)).to eq(["image/png"])
    expect(request.arguments).to eq("pages" => [{ "attached_image" => 1 }], "embedded_text" => "TOTAL 12.34")
  end

  it "returns nothing for an image that isn't a receipt" do
    fake_squishling { |llm| llm.step(:any).reply(reply.merge("is_receipt" => false)) }

    expect(described_class.fields_for(receipt)).to be_nil
  end

  it "makes no request for a file it can't read as an image" do
    receipt.file.attach(io: StringIO.new("a,b\n1,2\n"), filename: "receipt.csv", content_type: "text/csv")
    attempts = Squishling::Testing.no_llm_call { expect(described_class.fields_for(receipt)).to be_nil }

    expect(attempts).to be_empty
  end

  it "takes its models from RECEIPT_VISION_MODELS, smallest first" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("RECEIPT_VISION_MODELS", anything).and_return("small, large")

    expect(described_class.escalation).to eq([{ model: "small", attempts: 2 }, "large"])
  end
end
