# frozen_string_literal: true

module ReceiptService
  # Compares the merchant on a receipt with the merchant on a card charge.
  # Card networks report descriptors such as "SQ *BLUE BOTTLE COFFEE #12" or
  # "AMZN Mktp US*2K4RT1QZ0", so both sides are normalized before comparing.
  module MerchantName
    SIMILAR = 0.5

    # Payment facilitators put their own prefix before the merchant's name
    # ("SQ *", "TST* "). Any other prefix before a "*" is the merchant itself
    # ("UBER *TRIP"), so the part after it is dropped instead.
    FACILITATOR_PREFIXES = %w[sq tst paypal pp sp py dd ckc sumup fs wpy google paddle paddle.net].freeze
    LEGAL_SUFFIXES = %w[inc incorporated llc ltd limited co corp corporation company gmbh plc pbc].freeze
    AMAZON = /\A(amzn|amazon)(\s*mktp|\s*mktplace|\s*marketplace|\.com|\s+digital|\s+prime)?\b/

    # 0 when the names match after normalizing, 0.5 when they're similar, 1
    # when they differ, and nil when either side has nothing to compare.
    def self.distance(receipt_name:, receipt_url:, card_name:, card_url: nil)
      receipt_forms = [normalize(receipt_name), domain_label(receipt_url)].compact_blank.uniq
      card_forms = [normalize(card_name), domain_label(card_url)].compact_blank.uniq
      return nil if receipt_forms.empty? || card_forms.empty?

      pairs = receipt_forms.product(card_forms)
      return 0 if pairs.any? { |receipt_form, card_form| same?(receipt_form, card_form) }
      return 0.5 if pairs.any? { |receipt_form, card_form| similarity(receipt_form, card_form) >= SIMILAR }

      1
    end

    def self.normalize(name)
      name = name.to_s.downcase.strip
      return "amazon" if name.match?(AMAZON)

      prefix, rest = name.split("*", 2)
      name = FACILITATOR_PREFIXES.include?(prefix.strip) ? rest : prefix if rest

      name = name.gsub(/\b(?:[a-z0-9-]+\.)*([a-z0-9-]+)\.(?:com|net|org|io|co|app|dev|us|ca|uk)\b/, '\1')
      words = name.gsub(/[^a-z0-9& ]/, " ").split
      words = words.reject { |word| word.match?(/\d/) || word == "store" }
      words.shift if words.first == "the"
      words.pop while words.any? && LEGAL_SUFFIXES.include?(words.last)

      words.join(" ").presence
    end

    def self.domain_label(url)
      host = URI.parse(url.to_s.strip.then { |u| u.include?("://") ? u : "https://#{u}" }).host
      return nil if host.blank?

      labels = host.downcase.delete_prefix("www.").split(".")
      return nil if labels.size < 2

      second_level = labels[-2]
      label = %w[co com org net ac gov].include?(second_level) && labels.size >= 3 ? labels[-3] : second_level
      normalize(label)
    rescue URI::InvalidURIError
      nil
    end

    # Exact, or one name is the other plus extra words ("blue bottle" and
    # "blue bottle coffee oakland"), or one starts with the other once spaces
    # are dropped ("sticker mule" and "stickermule", "digi key" and "digikey
    # electronics").
    def self.same?(a, b)
      compact_a = a.delete(" ")
      compact_b = b.delete(" ")
      shorter, longer = [compact_a, compact_b].sort_by(&:length)

      " #{a} ".include?(" #{b} ") || " #{b} ".include?(" #{a} ") ||
        compact_a == compact_b ||
        (shorter.length >= 4 && longer.start_with?(shorter))
    end

    # Abbreviated descriptors ("wholefds mkt") share most letter pairs with the
    # full name once spaces are dropped.
    def self.similarity(a, b)
      [WhiteSimilarity.similarity(a, b), WhiteSimilarity.similarity(a.delete(" "), b.delete(" "))].max
    end
  end
end
