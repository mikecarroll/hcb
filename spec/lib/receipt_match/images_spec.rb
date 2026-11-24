# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptMatch::Images do
  let(:user) { create(:user) }

  def receipt_with(io:, filename:, content_type:)
    receipt = Receipt.new(user:, upload_method: :receipt_center)
    receipt.file.attach(io:, filename:, content_type:)
    receipt.save!
    receipt
  end

  # A bare-bones PDF of blank pages (poppler rebuilds the cross-reference table it lacks).
  def pdf_with_pages(count)
    objects = ["<< /Type /Catalog /Pages 2 0 R >>",
               "<< /Type /Pages /Kids [#{(1..count).map { |i| "#{2 + i} 0 R" }.join(' ')}] /Count #{count} >>"]
    count.times { objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>" }
    body = objects.each_with_index.map { |object, index| "#{index + 1} 0 obj\n#{object}\nendobj\n" }.join
    "%PDF-1.4\n#{body}trailer\n<< /Root 1 0 R /Size #{objects.size + 1} >>\n%%EOF\n"
  end

  def jpeg?(image)
    image.data.start_with?("\xFF\xD8".b)
  end

  it "downscales a photo to a JPEG" do
    receipt = receipt_with(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")

    images = described_class.for(receipt)

    expect(images.size).to eq(1)
    expect(jpeg?(images.first)).to be(true)
    expect(images.first.media_type).to eq("image/jpeg")
  end

  it "renders the pages of a PDF, up to a limit" do
    pages = described_class::MAX_PAGES + 1
    receipt = receipt_with(io: StringIO.new(pdf_with_pages(pages)), filename: "receipt.pdf", content_type: "application/pdf")

    images = described_class.for(receipt)

    expect(images.size).to eq(described_class::MAX_PAGES)
    expect(images).to all(satisfy { |image| jpeg?(image) })
  end

  it "has nothing for a file a model can't read, such as a spreadsheet" do
    receipt = receipt_with(io: StringIO.new("date,total\n2026-11-01,12.34\n"), filename: "receipt.csv", content_type: "text/csv")

    expect(described_class.for(receipt)).to eq([])
  end

  it "has nothing, rather than failing, for an image that can't be processed" do
    receipt = receipt_with(io: File.open(file_fixture("receipt.png")), filename: "receipt.png", content_type: "image/png")
    allow(ImageProcessing::MiniMagick).to receive(:source).and_raise(MiniMagick::Error)

    expect(described_class.for(receipt)).to eq([])
  end
end
