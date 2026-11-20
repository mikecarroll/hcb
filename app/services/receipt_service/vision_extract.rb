# frozen_string_literal: true

module ReceiptService
  # Reads a receipt from its image (or the first page of a PDF) with a vision model, instead of from OCR text. Behind
  # the receipt_vision_extraction_2026_11_20 flag in ReceiptService::Extract, and compared with the text extractor by
  # ReceiptService::ExtractionEval.
  #
  # The models come from RECEIPT_VISION_MODELS (comma-separated, smallest first): the first gets two attempts, and
  # each later one is tried when the one before it can't produce output that fits the schema.
  # RECEIPT_VISION_MAX_TOKENS caps the tokens one receipt may use across those attempts.
  class VisionExtract
    include Squishling

    # The longest edge, in pixels, an image is scaled down to before it's sent.
    MAX_EDGE = 2048
    # The most embedded PDF text sent alongside the page.
    MAX_TEXT = 20_000

    def self.escalation
      first, *rest = ENV.fetch("RECEIPT_VISION_MODELS", "gpt-5.6-luna").split(",").map(&:strip).compact_blank
      [{ model: first, attempts: 2 }, *rest]
    end

    def self.budget
      max = ENV["RECEIPT_VISION_MAX_TOKENS"].presence&.to_i
      max ? { max_total_input_tokens: max, max_total_output_tokens: max } : {}
    end

    squishling escalation:, **budget
    purpose "Read the card receipt in the attached image. Copy what it says; leave a field null when the receipt " \
            "doesn't show it. embedded_text, when present, is text taken from the same PDF and may help with " \
            "small print."
    output_schema do
      boolean :is_receipt, description: "Whether the image is a receipt, invoice, or order confirmation for a purchase"
      optional(:total_amount_cents, description: "The final amount paid, in cents, tip included") { integer }
      optional(:subtotal_amount_cents, description: "The amount before tax and tip, in cents") { integer }
      optional(:tip_amount_cents, description: "The tip or gratuity, in cents") { integer }
      optional(:currency, description: "3-letter ISO 4217 code, e.g. USD") { string pattern: "^[A-Z]{3}$" }
      optional(:card_last_four, description: "The last four digits of the card used") { string pattern: "^[0-9]{4}$" }
      optional(:card_brand, description: "Visa, Mastercard, Amex, or Discover") { string }
      optional(:date, description: "The transaction date, YYYY-MM-DD") { string pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" }
      optional(:merchant_name, description: "The merchant's short, common name, without store numbers") { string }
      optional(:merchant_descriptor, description: "The name as a card statement would show it, if printed") { string }
      optional(:merchant_city) { string }
      optional(:merchant_state) { string }
      optional(:merchant_country, description: "2-letter ISO 3166 code") { string }
      optional(:merchant_zip_code) { string }
      optional(:merchant_url, description: "The merchant's website, with https://") { string }
      optional(:transaction_memo, description: "Under 60 characters: what was bought and from whom, e.g. " \
                                                "\"🚕 Uber to SFO Airport\"") { string }
    end

    class << self
      # The fields read off the receipt, keyed like ReceiptService::Extract's, or nil when it isn't a receipt or
      # there is no image to read. text is any text already extracted from the file.
      def fields_for(receipt, text: nil)
        pages = images_for(receipt)
        return if pages.empty?

        result = call(pages:, embedded_text: text.presence&.truncate(MAX_TEXT))
        return unless result.is_receipt

        result.to_h.except(:is_receipt).with_indifferent_access
      end

      # The receipt as images: the file itself, or a PDF's first page, scaled down to MAX_EDGE.
      def images_for(receipt)
        file = receipt.file
        return [] unless file.attached?

        if file.content_type == "application/pdf"
          [image_from(file.preview(resize: "#{MAX_EDGE}x#{MAX_EDGE}").processed.image.blob)]
        elsif file.content_type.start_with?("image/")
          [image_from(file.blob)]
        else
          []
        end
      end

      private

      def image_from(blob)
        blob.open do |tempfile|
          png = ImageProcessing::MiniMagick.source(tempfile.path).resize_to_limit(MAX_EDGE, MAX_EDGE).convert("png").call
          Squishling::Image.new(data: File.binread(png.path), media_type: "image/png")
        ensure
          png&.close!
        end
      end

    end

  end
end
