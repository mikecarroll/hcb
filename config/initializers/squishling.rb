# frozen_string_literal: true

# Squishling (https://github.com/Coolhand-Labs/squishling) puts an LLM behind a Ruby method. We use it in
# apprentice mode for receipt matching (see ReceiptService::Match): the Ruby matcher answers every call and
# the LLM runs alongside it on the same inputs, so the model can be measured before it serves anything.
Squishling.configure do |config|
  # The OpenAI-compatible adapter needs no extra gem (RubyLLM would pull in Faraday 2; we pin Faraday 1).
  config.adapter = {
    type: :openai_compatible,
    base_url: "https://api.openai.com/v1",
    api_key: -> { Credentials.fetch(:OPENAI, :RECEIPT_EXTRACTION) },
    default_model: "gpt-5.6-terra"
  }

  # Run the LLM on Squishling's built-in thread pool (2 threads, at most 100 pending runs) after the Ruby
  # result is ready, so the LLM's latency never delays the caller. Some callers matter here: the receipt
  # bin's email mailbox must reply once the Ruby match is known, and a web request (quick expense uploads)
  # must not wait on a model.
  #
  # We chose this over running the shadow in a Sidekiq job (`apprentice_runner = :inline` inside a job) to keep
  # the call sites unchanged and add no job. The tradeoffs: a pending run is lost if the process is killed
  # (deploys give pending runs 5 seconds to finish), and each worker thread can hold a database connection
  # (it runs in the Rails executor), so keep the pool sized for it. That's acceptable because a shadow run is
  # a measurement: a lost run costs a data point, never a user-visible result. Revisit if runs are being dropped.
  config.apprentice_runner = :thread

  config.logger = Rails.logger
end

# Referencing app code in an initializer isn't allowed, so the observer is set once the app has loaded.
Rails.application.config.to_prepare do
  Squishling.configure { |config| config.observer = ReceiptMatch::Observer.new }
end
