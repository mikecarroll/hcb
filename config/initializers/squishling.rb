# frozen_string_literal: true

Squishling.configure do |config|
  config.adapter = { type: :openai_compatible, api_key: -> { Credentials.fetch(:OPENAI, :RECEIPT_EXTRACTION) } }
  config.logger = Rails.logger
end
