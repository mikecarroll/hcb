# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptService::MerchantName do
  def distance(card_name, receipt_name, receipt_url: nil, card_url: nil)
    described_class.distance(receipt_name:, receipt_url:, card_name:, card_url:)
  end

  describe ".distance" do
    {
      "SQ *BLUE BOTTLE COFFEE #12" => "Blue Bottle Coffee",
      "AMZN Mktp US*2K4RT1QZ0"     => "Amazon",
      "Amazon.com*RT4G21"          => "Amazon.com",
      "TST* DOMINOS 6789"          => "Domino's",
      "UBER *TRIP HELP.UBER.COM"   => "Uber",
      "LYFT *RIDE"                 => "Lyft",
      "PAYPAL *GITHUB"             => "GitHub, Inc.",
      "GOOGLE *YouTubePremium"     => "YouTube Premium",
      "STICKERMULE.COM"            => "Sticker Mule",
      "DIGIKEY ELECTRONICS"        => "Digi-Key",
      "HOME DEPOT 4521"            => "The Home Depot",
      "CVS/PHARMACY #1234"         => "CVS Pharmacy",
      "WAL-MART #2131"             => "Walmart",
      "MCMASTER-CARR"              => "McMaster Carr Supply Co.",
    }.each do |card_name, receipt_name|
      it "matches #{card_name.inspect} with #{receipt_name.inspect}" do
        expect(distance(card_name, receipt_name)).to eq(0)
      end
    end

    it "gives partial credit to an abbreviated descriptor" do
      expect(distance("WHOLEFDS MKT 10234", "Whole Foods Market")).to eq(0.5)
    end

    {
      "UBER *TRIP"             => "Lyft",
      "SQ *BLUE BOTTLE COFFEE" => "Starbucks",
      "STAPLES 00123"          => "Starbucks",
      "TARGET 00012345"        => "Walmart",
      "DELTA AIR LINES"        => "Delta Hotels",
      "ADAFRUIT INDUSTRIES"    => "SparkFun Electronics",
    }.each do |card_name, receipt_name|
      it "doesn't match #{card_name.inspect} with #{receipt_name.inspect}" do
        expect(distance(card_name, receipt_name)).to eq(1)
      end
    end

    it "matches the receipt's website when it has no merchant name" do
      expect(distance("FIGMA", nil, receipt_url: "https://www.figma.com/billing")).to eq(0)
      expect(distance("FIGMA", nil, receipt_url: "https://shop.example.co.uk/order/1")).to eq(1)
    end

    it "matches the charge's website against the receipt" do
      expect(distance("PADDLE.NET* NOTION", "Notion Labs", card_url: "notion.so")).to eq(0)
    end

    it "has nothing to compare when either side is blank" do
      expect(distance(nil, "Amazon")).to be_nil
      expect(distance("AMZN Mktp US*2K4RT1QZ0", "", receipt_url: "not a url")).to be_nil
    end
  end
end
