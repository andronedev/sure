class AddProcessIdToTraderepublicItems < ActiveRecord::Migration[7.2]
  def change
    add_column :traderepublic_items, :process_id, :text
    add_column :traderepublic_items, :session_token, :text
    add_column :traderepublic_items, :refresh_token, :text
    add_column :traderepublic_items, :session_cookies, :jsonb
  end
end
