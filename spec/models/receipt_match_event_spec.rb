# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReceiptMatchEvent do
  let(:user) { create(:user) }
  let(:picked) { create_card_charge(user:) } # the transaction the model picked
  let(:other) { create_card_charge(user:, amount_cents: -55_00) }
  let(:receipt) { create_bin_receipt(user:) }
  let!(:run) { create_match_run(receipt:, llm: picked) }

  before { Flipper.enable(ReceiptMatch::FLAG) }

  def feedback_for(kind, hcb_code: nil, **payload)
    described_class.record!(receipt:, kind:, hcb_code:, **payload)&.feedback
  end

  describe ".record!" do
    it "records the event against the receipt's latest answered run" do
      event = described_class.record!(receipt:, kind: "suggestion_accepted", hcb_code: picked)

      expect(event).to have_attributes(receipt:, receipt_match_run: run, kind: "suggestion_accepted", hcb_code_id: picked.id, human: true)
    end

    it "does nothing unless the experiment is on for the receipt's owner" do
      Flipper.disable(ReceiptMatch::FLAG)

      expect(described_class.record!(receipt:, kind: "suggestion_accepted", hcb_code: picked)).to be_nil
    end

    it "does nothing for a receipt the model never read" do
      other_receipt = create_bin_receipt(user:)

      expect(described_class.record!(receipt: other_receipt, kind: "suggestion_accepted", hcb_code: picked)).to be_nil
    end

    it "never fails what the person was doing" do
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid)

      expect(described_class.record!(receipt:, kind: "suggestion_accepted", hcb_code: picked)).to be_nil
    end

    it "sends the feedback in the background" do
      expect { described_class.record!(receipt:, kind: "suggestion_accepted", hcb_code: picked) }
        .to have_enqueued_job(Receipt::SendMatchFeedbackJob)
    end

    it "sends nothing for what the system did" do
      expect { described_class.record!(receipt:, kind: "auto_attached", hcb_code: picked, human: false) }
        .not_to have_enqueued_job(Receipt::SendMatchFeedbackJob)
    end
  end

  describe "#feedback on the model's answer" do
    it "likes it when the person chose what the model picked" do
      %w[suggestion_accepted manually_linked].each do |kind|
        expect(feedback_for(kind, hcb_code: picked)).to include(client_unique_id: run.request_id, sentiment: "like", creator_type: "human",
                                                                creator_unique_id: "hcb-user:#{user.hashid}")
      end
    end

    it "dislikes it, with the person's choice as the revised output, when they chose another transaction" do
      feedback = feedback_for("manually_linked", hcb_code: other)

      expect(feedback).to include(client_unique_id: run.request_id, sentiment: "dislike")
      expect(JSON.parse(feedback[:revised_output])).to include("hcb_code_id" => other.hashid)
    end

    it "is neutral about a model that picked none when the person attached it themselves" do
      run.update!(llm_hcb_code_hashid: nil)

      expect(feedback_for("manually_linked", hcb_code: other)).to include(sentiment: "neutral", revised_output: a_string_including(other.hashid))
    end

    it "dislikes it when the person ignored or reversed the transaction it picked" do
      expect(feedback_for("suggestion_ignored", hcb_code: picked)).to include(sentiment: "dislike")
      expect(feedback_for("reversed", hcb_code: picked)).to include(sentiment: "dislike")
    end

    it "says nothing when the person ignored or reversed a transaction the model didn't pick" do
      expect(feedback_for("suggestion_ignored", hcb_code: other)).to be_nil
      expect(feedback_for("reversed", hcb_code: other)).to be_nil
    end

    it "is neutral about a deleted receipt the model picked nothing for, and dislikes it otherwise" do
      expect(feedback_for("receipt_deleted")).to include(sentiment: "dislike")

      run.update!(llm_hcb_code_hashid: nil)
      expect(feedback_for("receipt_deleted")).to include(sentiment: "neutral")
    end
  end

  describe "#feedback on the suggested memo" do
    let(:receipt) { create_bin_receipt(user:, suggested_memo: "🏷️ Event stickers") }

    it "likes a memo that was kept, on the extraction request" do
      expect(feedback_for("memo_accepted", hcb_code: picked))
        .to include(client_unique_id: "receipt-extract:#{receipt.id}", sentiment: "like")
    end

    it "dislikes a memo that was edited, with the user's memo as the revised output" do
      expect(feedback_for("memo_edited", hcb_code: picked, memo: "Stickers for the hackathon"))
        .to include(client_unique_id: "receipt-extract:#{receipt.id}", sentiment: "dislike", revised_output: "Stickers for the hackathon")
    end

    it "is recorded even for a receipt no match was run for" do
      run.destroy!

      expect(described_class.record!(receipt:, kind: "memo_accepted", hcb_code: picked)).to be_present
    end
  end

  describe ".record_memo!" do
    let(:receipt) { create_bin_receipt(user:, suggested_memo: "🏷️ Event stickers") }

    before { receipt.update!(receiptable: picked.ledger_item) }

    it "records accepting the suggestion when the memo is kept as it was" do
      described_class.record_memo!(hcb_code: picked, previous_memo: nil, memo: "🏷️ Event stickers")

      expect(described_class.last).to have_attributes(kind: "memo_accepted")
    end

    it "records editing it when the memo is something else" do
      described_class.record_memo!(hcb_code: picked, previous_memo: nil, memo: "Stickers")

      expect(described_class.last).to have_attributes(kind: "memo_edited", payload: { "memo" => "Stickers" })
    end

    it "records nothing when the transaction already had a memo of its own, or the memo was cleared" do
      described_class.record_memo!(hcb_code: picked, previous_memo: "Mine", memo: "Stickers")
      described_class.record_memo!(hcb_code: picked, previous_memo: nil, memo: nil)

      expect(described_class.count).to eq(0)
    end
  end
end
