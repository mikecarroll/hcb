# frozen_string_literal: true

# One row per LLM shadow run of ReceiptService::Match (Squishling apprentice mode).
# call_id is the id given to Squishling.with_call_id and request_id the request
# whose output was accepted, so both can be used as Coolhand client_unique_ids.
class CreateReceiptMatchRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_match_runs do |t|
      t.references :receipt, null: false, foreign_key: { on_delete: :cascade }
      t.string :call_id, null: false
      t.string :request_id
      t.string :model
      t.string :ruby_hcb_code_hashid
      t.float :ruby_confidence
      t.string :llm_hcb_code_hashid
      t.float :llm_confidence
      t.boolean :agreed
      t.string :error_class
      t.float :ruby_seconds
      t.float :llm_seconds
      t.integer :candidate_count
      t.boolean :candidates_truncated, null: false, default: false
      t.datetime :reported_at

      t.timestamps
    end

    add_index :receipt_match_runs, :call_id, unique: true
  end

end
