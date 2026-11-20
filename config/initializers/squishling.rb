# frozen_string_literal: true

# Squishling classes (see ReceiptService::TieBreak) reach OpenAI through one
# adapter per process. The key is read on every request, so the app boots
# without it; a call made without one fails with Squishling::ConfigurationError.
Squishling.configure do |config|
  config.adapter = {
    type: :openai_compatible,
    api_key: -> { Credentials.fetch(:OPENAI, :RECEIPT_MATCHING) },
  }
  config.logger = Rails.logger
end
