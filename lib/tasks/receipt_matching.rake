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

  desc "Compare the text and vision receipt extractors on receipts attached to card charges. Calls the provider: " \
       "limit (receipts) and max_tokens (all requests together) are required, e.g. " \
       "rake 'receipt_matching:extraction_eval[2026-07-01,2026-08-31,50,500000]'"
  task :extraction_eval, [:from, :to, :limit, :max_tokens] => :environment do |_task, args|
    report = ReceiptService::ExtractionEval.new(from: Date.parse(args.fetch(:from)), to: Date.parse(args.fetch(:to)),
                                                limit: Integer(args.fetch(:limit)), max_tokens: Integer(args.fetch(:max_tokens))).run
    report.delete(:rows)

    puts JSON.pretty_generate(report)
  end
end
