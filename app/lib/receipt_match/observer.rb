# frozen_string_literal: true

module ReceiptMatch
  # Squishling's Coolhand observer, with Coolhand capture switched on around each
  # request. Capture is off by default (see config/initializers/coolhand.rb), and
  # Squishling's observer declares the workload but doesn't switch capture on.
  # Shadow runs only happen when ReceiptMatch.enabled_for? the receipt's owner,
  # so every request that reaches this observer is one we mean to capture.
  class Observer
    def initialize
      @coolhand = Squishling::Observers::Coolhand.new
    end

    def around(call, &)
      ::Coolhand.with_capture { @coolhand.around(call, &) }
    end

    delegate :apprentice, to: :@coolhand

  end

end
