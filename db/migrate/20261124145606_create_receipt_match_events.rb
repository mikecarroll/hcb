# frozen_string_literal: true

# What people did with a receipt-matching suggestion. Append-only: it is the
# outbox for feedback sent to Coolhand and the ground truth for evaluating matches.
class CreateReceiptMatchEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_match_events do |t|
      t.references :receipt, null: false, foreign_key: { on_delete: :cascade }
      t.references :receipt_match_run, foreign_key: { on_delete: :nullify } # memo events have no run
      t.string :kind, null: false
      t.bigint :hcb_code_id
      t.boolean :human, null: false, default: true
      t.jsonb :payload, null: false, default: {}
      t.datetime :feedback_sent_at

      t.timestamps
    end
  end

end
