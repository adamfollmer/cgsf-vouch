# frozen_string_literal: true

class CreateCgsfVouches < ActiveRecord::Migration[7.2]
  def change
    create_table :cgsf_vouches do |t|
      t.integer :requester_id, null: false
      t.integer :receiver_id, null: false
      t.datetime :confirmed_at # set = the edge exists (mutual)
      t.datetime :cooldown_until # set = closed unanswered; row only holds the re-offer cooldown
      t.timestamps
    end
    add_index :cgsf_vouches, %i[requester_id receiver_id]
    add_index :cgsf_vouches, :receiver_id
  end
end
