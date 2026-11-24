# frozen_string_literal: true

require "open3"
require "tmpdir"

module ReceiptMatch
  # A receipt's pages as images for the LLM (ReceiptService::Match). Images are downscaled JPEGs and PDFs
  # are rendered a page at a time, so a request stays small enough for Coolhand to capture whole.
  module Images
    MAX_PAGES = 3
    MAX_EDGE = 1024
    PDF_DPI = 110

    # Receipts that aren't an image or a PDF (CSVs) have nothing for a model to read.
    def self.for(receipt)
      return [] unless receipt.file.attached?

      content_type = receipt.file.content_type
      if content_type.start_with?("image/")
        [from_image(receipt)]
      elsif content_type == "application/pdf"
        from_pdf(receipt)
      else
        []
      end
    rescue => e
      # A file ImageMagick or poppler can't read just means no shadow run for this receipt.
      Rails.error.report(e, context: { receipt_id: receipt.id }, handled: true)
      []
    end

    # Processed from a temporary copy rather than as an ActiveStorage variant, so no extra files are stored.
    def self.from_image(receipt)
      receipt.file.blob.open do |tempfile|
        scaled = ImageProcessing::MiniMagick.source(tempfile.path).resize_to_limit(MAX_EDGE, MAX_EDGE).convert!("jpeg")
        jpeg(File.binread(scaled.path))
      end
    end

    # The first MAX_PAGES pages, rendered with poppler's pdftoppm (installed in the Dockerfile).
    def self.from_pdf(receipt)
      Dir.mktmpdir("receipt-match") do |dir|
        pdf = File.join(dir, "receipt.pdf")
        File.binwrite(pdf, receipt.file.download)
        _out, err, status = Open3.capture3("pdftoppm", "-jpeg", "-r", PDF_DPI.to_s, "-l", MAX_PAGES.to_s, pdf, File.join(dir, "page"))
        raise "pdftoppm failed: #{err.truncate(200)}" unless status.success?

        Dir.glob(File.join(dir, "page*.jpg")).sort.first(MAX_PAGES).map { |page| jpeg(File.binread(page)) }
      end
    end

    def self.jpeg(data)
      Squishling::Image.new(data:, media_type: "image/jpeg")
    end

  end

end
