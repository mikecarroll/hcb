# frozen_string_literal: true

require "squishling/testing"
require "squishling/rspec"

# Specs never reach a model or Coolhand: provider calls are forbidden unless a spec scripts one with
# `fake_squishling`, and apprentice shadow runs happen inline so a spec sees their result.
Squishling.configure do |config|
  config.observer = false
  config.apprentice_runner = :inline
end

RSpec.configure do |config|
  config.include Squishling::Testing::RSpec

  config.before(:each) do
    forbid_provider_calls!
  end
end
