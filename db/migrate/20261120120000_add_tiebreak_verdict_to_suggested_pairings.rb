# frozen_string_literal: true

class AddTiebreakVerdictToSuggestedPairings < ActiveRecord::Migration[8.1]
  def change
    add_column :suggested_pairings, :tiebreak_verdict, :string
  end

end
