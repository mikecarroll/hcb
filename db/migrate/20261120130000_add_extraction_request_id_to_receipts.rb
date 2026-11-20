# frozen_string_literal: true

class AddExtractionRequestIdToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :extraction_request_id, :string
  end

end
