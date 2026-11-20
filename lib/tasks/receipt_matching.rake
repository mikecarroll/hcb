# frozen_string_literal: true

namespace :receipt_matching do
  desc "Score receipt matching on past receipt-bin uploads. Needs RECEIPT_MATCHING_POINTS, a JSON object of points per outcome " \
       "(see ReceiptService::MatchingReplay::OUTCOMES), e.g. rake 'receipt_matching:replay[2026-07-01,2026-08-31,tmp/replay.csv]'"
  task :replay, [:from, :to, :csv_path] => :environment do |_task, args|
    points = JSON.parse(ENV.fetch("RECEIPT_MATCHING_POINTS"))
    report = ReceiptService::MatchingReplay.new(from: Date.parse(args.fetch(:from)), to: Date.parse(args.fetch(:to)), points:).run
    rows = report.delete(:rows)

    if args[:csv_path].present?
      CSV.open(args[:csv_path], "w") do |csv|
        csv << rows.first.keys if rows.any?
        rows.each { |row| csv << row.values }
      end
    end

    puts JSON.pretty_generate(report)
  end

  desc "Fit matching weights on past receipt-bin uploads and pick thresholds by minimum precision (0-1), " \
       "e.g. rake 'receipt_matching:fit_weights[2026-07-01,2026-08-31,0.9,0.7,tmp/candidates.csv]' (suggestion precision and CSV optional)"
  task :fit_weights, [:from, :to, :min_precision, :suggest_min_precision, :csv_path] => :environment do |_task, args|
    fit = ReceiptService::FitMatchingWeights.new(
      from: Date.parse(args.fetch(:from)),
      to: Date.parse(args.fetch(:to)),
      min_precision: Float(args.fetch(:min_precision)),
      suggest_min_precision: args[:suggest_min_precision].presence && Float(args[:suggest_min_precision])
    )
    report = fit.run

    if args[:csv_path].present?
      CSV.open(args[:csv_path], "w") do |csv|
        csv << [:receipt_id, :hcb_code_id, :label, *ReceiptService::FitMatchingWeights::FEATURE_NAMES]
        fit.rows.each { |row| csv << [row[:receipt_id], row[:hcb_code_id], row[:label], *row[:features].values_at(*ReceiptService::FitMatchingWeights::FEATURE_NAMES)] }
      end
    end

    puts JSON.pretty_generate(report)
  end
end
