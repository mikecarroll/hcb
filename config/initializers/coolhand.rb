# frozen_string_literal: true

# Coolhand records LLM calls and the feedback on them. Without an API key it
# isn't configured at all: Net::HTTP stays unpatched and nothing is captured or
# sent. With one, only calls made inside `Coolhand.with_capture` are captured
# (see ReceiptService::Extract), so every other LLM call stays out of it.
if (api_key = Credentials.fetch(:COOLHAND, :API_KEY)).present?
  Coolhand.configure do |config|
    config.api_key = api_key
    config.capture = false
    config.silent = !Rails.env.development?
  end
end
