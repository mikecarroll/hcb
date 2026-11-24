# frozen_string_literal: true

# Coolhand (https://coolhandlabs.com) monitors our LLM calls and collects feedback on them.
# It patches Net::HTTP and captures requests to LLM hosts, so it is configured to capture nothing
# by default: only calls wrapped in `ReceiptMatch.capture` (flag-gated, see ReceiptMatch::FLAG) are
# sent, and other LLM calls, such as card grant pre-authorization, stay out of it.
api_key = Credentials.fetch(:COOLHAND, :API_KEY)

Coolhand.configure do |config|
  config.api_key = api_key
  config.enabled = api_key.present? # no key (development, test, fork CI): don't patch Net::HTTP at all
  config.capture = false
  config.environment = Rails.env.to_s
  config.silent = !Rails.env.development?
  # Receipt images go to the LLM as base64 data URIs and would exceed the default 1 MB cap, which
  # replaces the logged request with a placeholder instead of the prompt.
  config.max_captured_body_bytes = 4_000_000
end
