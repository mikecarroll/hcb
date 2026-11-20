# frozen_string_literal: true

namespace :receipt_matching do
  desc "Score receipt matching on past receipt-bin uploads. Needs RECEIPT_MATCHING_POINTS, a JSON object of points per outcome " \
       "(see ReceiptService::MatchingReplay::OUTCOMES), e.g. rake 'receipt_matching:replay[2026-07-01,2026-08-31,tmp/replay.csv]'"
  task :replay, [:from, :to, :csv_path] => :environment do |_task, args|
    points = JSON.parse(ENV.fetch("RECEIPT_MATCHING_POINTS"))
    report = ReceiptService::MatchingReplay.new(from: Date.parse(args.fetch(:from)), to: Date.parse(args.fetch(:to)), points:,
                                                tiebreak: ENV["RECEIPT_MATCHING_TIEBREAK"] == "true").run
    rows = report.delete(:rows)

    if args[:csv_path].present?
      CSV.open(args[:csv_path], "w") do |csv|
        csv << rows.first.keys if rows.any?
        rows.each { |row| csv << row.values }
      end
    end

    puts JSON.pretty_generate(report)
  end
end
