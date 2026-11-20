# frozen_string_literal: true

module ReceiptService
  # Fits a logistic regression on past receipt-bin uploads that ended up on a
  # card charge: one row per candidate charge, labeled 1 for the charge the
  # receipt ended up on. Trains on the earlier uploads and evaluates on the
  # later ones, then picks probability thresholds whose Wilson lower bound on
  # precision clears the minimum given.
  class FitMatchingWeights
    SCORED_FEATURES = %i[amount_cents card_last_four date merchant_zip_code merchant_name].freeze
    UNKNOWABLE_FEATURES = %i[card_last_four date merchant_zip_code merchant_name].freeze
    FEATURE_NAMES = [
      *SCORED_FEATURES,
      *UNKNOWABLE_FEATURES.map { |name| :"#{name}_unknown" },
      :date_delta,
      :same_amount_candidates,
    ].freeze
    # Derived features are scaled to 0..1 at these caps.
    MAX_DATE_DELTA_DAYS = 30
    MAX_SAME_AMOUNT_CANDIDATES = 10
    CURVE_THRESHOLDS = (1..9).map { |tenth| tenth / 10.0 }.freeze

    def self.wilson_lower_bound(successes, trials, z:)
      return 0.0 if trials.zero?

      phat = successes.to_f / trials
      denominator = 1 + (z**2 / trials)
      center = phat + (z**2 / (2 * trials))
      margin = z * Math.sqrt((phat * (1 - phat) / trials) + (z**2 / (4 * trials**2)))
      (center - margin) / denominator
    end

    # Orders receipts by upload time and puts the last test_fraction of them,
    # with all their candidate rows, in the test set.
    def self.time_split(rows, test_fraction:)
      receipt_ids = rows.group_by { |row| row[:receipt_id] }
                        .sort_by { |receipt_id, receipt_rows| [receipt_rows.first[:uploaded_at], receipt_id] }
                        .map(&:first)
      train_ids = receipt_ids.first((receipt_ids.size * (1 - test_fraction)).floor).to_set

      rows.partition { |row| train_ids.include?(row[:receipt_id]) }
    end

    # decisions: one { probability:, correct: } per receipt, for its most likely
    # candidate. Returns the lowest threshold whose acted-on decisions have a
    # Wilson lower bound on precision of at least min_precision.
    def self.lowest_threshold(decisions, min_precision:, z:, total:)
      acted = 0
      correct = 0
      best = nil

      decisions.group_by { |decision| decision[:probability] }.sort_by { |probability, _| -probability }.each do |probability, group|
        acted += group.size
        correct += group.count { |decision| decision[:correct] }
        lower = wilson_lower_bound(correct, acted, z:)
        next if lower < min_precision

        best = { threshold: probability, acted:, coverage: acted.to_f / total, precision: correct.to_f / acted, wilson_lower: lower }
      end

      best
    end

    def initialize(from:, to:, min_precision:, suggest_min_precision: nil, test_fraction: 0.2, l2: 1.0, z: 1.96,
                   upload_methods: MatchingHistory::RECEIPT_BIN_UPLOAD_METHODS)
      [min_precision, suggest_min_precision].compact.each do |precision|
        raise ArgumentError, "precision must be between 0 and 1" unless precision.between?(0, 1)
      end

      @history = MatchingHistory.new(from:, to:, upload_methods:)
      @min_precision = min_precision
      @suggest_min_precision = suggest_min_precision
      @test_fraction = test_fraction
      @l2 = l2
      @z = z
    end

    def rows
      @rows ||= @history.receipts.find_each.flat_map { |receipt| rows_for(receipt) }
    end

    def run
      train, test = self.class.time_split(rows, test_fraction: @test_fraction)
      raise ArgumentError, "not enough receipts to split into training and test sets" if train.empty? || test.empty?

      model = LogisticRegression.fit(train.map { |row| vector(row) }, train.pluck(:label), l2: @l2)
      test.each { |row| row[:probability] = model.probability(vector(row)) }
      decisions = decisions_for(test)

      {
        receipts: { train: train.pluck(:receipt_id).uniq.size, test: decisions.size },
        rows: { train: train.size, test: test.size },
        receipts_without_their_charge_as_a_candidate: rows.group_by { |row| row[:receipt_id] }.count { |_, group| group.none? { |row| row[:label] == 1 } },
        iterations: model.iterations,
        coefficients: { intercept: model.intercept }.merge(FEATURE_NAMES.zip(model.weights).to_h),
        calibration: calibration(test),
        auto_attach: threshold_report(decisions, @min_precision),
        suggest: @suggest_min_precision && threshold_report(decisions, @suggest_min_precision),
        curve: curve(decisions),
      }
    end

    def rows_for(receipt)
      truth = receipt.hcb_code
      return [] if truth.nil? || !receipt.data_extracted?

      suggest = Suggest.new(receipt:)
      ranked = suggest.rank(suggest.candidates(@history.candidates_at(receipt), extracted: receipt), extracted: receipt)
      amounts = ranked.map { |pairing| suggest.charged_amount_cents(pairing[:hcb_code]) }
      amount_counts = amounts.tally
      receipt_date = receipt.extracted_date&.to_date

      ranked.each_with_index.map do |pairing, index|
        values = pairing[:features].transform_values { |feature| feature[:value] }
        date_delta = receipt_date && (suggest.charge_date(pairing[:hcb_code]) - receipt_date).to_i.abs

        features = SCORED_FEATURES.index_with { |name| values[name].to_f }
        UNKNOWABLE_FEATURES.each { |name| features[:"#{name}_unknown"] = values[name].nil? ? 1.0 : 0.0 }
        features[:date_delta] = date_delta ? [date_delta, MAX_DATE_DELTA_DAYS].min.to_f / MAX_DATE_DELTA_DAYS : 0.0
        features[:same_amount_candidates] = [amount_counts[amounts[index]] - 1, MAX_SAME_AMOUNT_CANDIDATES].min.to_f / MAX_SAME_AMOUNT_CANDIDATES

        {
          receipt_id: receipt.id,
          hcb_code_id: pairing[:hcb_code].id,
          uploaded_at: receipt.created_at,
          label: pairing[:hcb_code].id == truth.id ? 1 : 0,
          features:,
        }
      end
    end

    private

    def vector(row)
      FEATURE_NAMES.map { |name| row[:features].fetch(name) }
    end

    # The most likely candidate per test receipt. A tie for most likely is never
    # acted on, so it counts as no decision.
    def decisions_for(test)
      test.group_by { |row| row[:receipt_id] }.map do |_, candidates|
        best, runner_up = candidates.max_by(2) { |row| row[:probability] }
        tied = runner_up && runner_up[:probability] == best[:probability]
        { probability: tied ? 0.0 : best[:probability], correct: !tied && best[:label] == 1 }
      end
    end

    def threshold_report(decisions, min_precision)
      { min_precision:, **(self.class.lowest_threshold(decisions, min_precision:, z: @z, total: decisions.size) || { threshold: nil }) }
    end

    def calibration(test)
      test.group_by { |row| [(row[:probability] * 10).floor, 9].min }.sort.map do |bucket, rows|
        {
          bucket: "#{bucket / 10.0}-#{(bucket + 1) / 10.0}",
          rows: rows.size,
          mean_predicted: (rows.sum { |row| row[:probability] } / rows.size).round(4),
          actual_rate: (rows.count { |row| row[:label] == 1 }.to_f / rows.size).round(4),
        }
      end
    end

    def curve(decisions)
      CURVE_THRESHOLDS.map do |threshold|
        acted = decisions.select { |decision| decision[:probability] >= threshold }
        correct = acted.count { |decision| decision[:correct] }
        {
          threshold:,
          coverage: decisions.empty? ? 0.0 : (acted.size.to_f / decisions.size).round(4),
          precision: acted.empty? ? nil : (correct.to_f / acted.size).round(4),
          wilson_lower: self.class.wilson_lower_bound(correct, acted.size, z: @z).round(4),
        }
      end
    end

  end
end
