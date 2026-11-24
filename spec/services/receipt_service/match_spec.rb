# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::Match do
  let(:receipt) do
    Receipt.new(extracted_total_amount_cents: 12_34, extracted_card_last4: "4242", extracted_date: Date.new(2026, 11, 1),
                extracted_merchant_name: "acme", extracted_merchant_zip_code: "94110", data_extracted: true)
  end
  let(:image) { Squishling::Image.new(data: File.binread(file_fixture("receipt.png"))) }

  def candidate(hcb_code_id, **overrides)
    { hcb_code_id:, amount_cents: -12_34, merchant_amount_cents: nil, date: Date.new(2026, 11, 1), card_last4: "4242",
      merchant_name: "ACME CORP", merchant_zip: "94110", memo: "ACME CORP"
}.merge(overrides)
  end

  it "is a valid squished class" do
    expect(described_class).to be_squishling_valid
  end

  describe "the Ruby matcher" do
    subject(:match) { described_class.new(receipt:) }

    it "picks the closest candidate" do
      far = candidate("far", amount_cents: -99_99, card_last4: "1111", merchant_name: "OTHER")
      near = candidate("near")

      result = match.call(images: [], candidates: [far, near])

      expect(result.hcb_code_id).to eq("near")
      expect(result.confidence).to eq(1.0)
      expect(result.squished?).to be(false)
    end

    it "suggests nothing when every candidate is too far away" do
      result = match.call(images: [], candidates: [candidate("a", amount_cents: -1, card_last4: "1111", merchant_name: "OTHER", date: Date.new(2026, 1, 1), merchant_zip: "10001")])

      expect(result.hcb_code_id).to be_nil
      expect(result.confidence).to eq(0.0)
    end

    it "breaks ties by candidate order instead of arbitrarily" do
      result = match.call(images: [], candidates: [candidate("first"), candidate("second")])

      expect(result.hcb_code_id).to eq("first")
    end

    it "suggests nothing for a receipt that hasn't been read" do
      result = described_class.new(receipt:, extracted: nil).call(images: [], candidates: [candidate("a")])

      expect(result.hcb_code_id).to be_nil
    end

    it "gives partial credit for a date a few days off, and ignores the placeholder postal code" do
      off_by_three = match.distance(candidate("a", date: Date.new(2026, 11, 4)))
      placeholder_zip = match.distance(candidate("a", merchant_zip: "00000"))

      expect(off_by_three).to be_within(0.01).of((0.2 + 0.8 * (3 / 5r)) * 100 / 600 * 100)
      expect(placeholder_zip).to eq(0.0)
    end

    it "treats a card with no merchant name as a miss" do
      expect(match.distance(candidate("a", merchant_name: nil))).to be_within(0.01).of(50 / 600.0 * 100)
    end
  end

  describe "squishling_preview" do
    it "sends the receipt's image and the candidates, with the class's own code as context" do
      preview = squishling_preview(described_class, images: [image], candidates: [candidate("a")], receiver: described_class.new(receipt:))

      expect(preview[:system_prompt]).to include("def distance", "MAX_DISTANCE")
      expect(preview[:images]).to eq([image])
      expect(preview[:user_message]).to include("hcb_code_id")
      expect(preview[:user_message]).not_to include("extracted_", "textual_content")
      expect(preview[:step].model).to eq("gpt-5.6-terra")
    end
  end

  describe "apprentice mode" do
    subject(:match) { described_class.new(receipt:) }

    it "runs the model on the receipt's image alongside the Ruby matcher, and returns the Ruby answer" do
      fake = fake_squishling { |llm| llm.step("gpt-5.6-terra").reply(hcb_code_id: "other", confidence: 0.9, rationale: "Looks like it") }

      result = match.call(images: [image], candidates: [candidate("near"), candidate("other", card_last4: "1111")])

      expect(result.hcb_code_id).to eq("near")
      expect(result.squished?).to be(false)
      expect(fake.requests.size).to eq(1)
      expect(fake.requests.first).to be_apprentice
      expect(fake.requests.first.images).to eq([image])
      expect(fake.requests.first.arguments.keys).to contain_exactly("images", "candidates")
    end

    it "doesn't run the model without an image" do
      assert_no_llm_call { match.call(images: [], candidates: [candidate("near")]) }
    end

    it "returns the Ruby answer even when the model fails" do
      fake_squishling { |llm| llm.step(:any).fail(:server_error) }

      expect(match.call(images: [image], candidates: [candidate("near")]).hcb_code_id).to eq("near")
    end
  end
end
