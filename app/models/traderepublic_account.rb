class TraderepublicAccount < ApplicationRecord
  belongs_to :traderepublic_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  def upsert_traderepublic_snapshot!(account_snapshot)
    self.raw_payload = account_snapshot
    save!
  end

  def upsert_traderepublic_transactions_snapshot!(transactions_snapshot)
    Rails.logger.debug "TraderepublicAccount #{id}: upsert transactions snapshot (#{transactions_snapshot.class})"

    if transactions_snapshot.nil? || (transactions_snapshot.respond_to?(:empty?) && transactions_snapshot.empty?)
      return
    end

    if raw_transactions_payload.nil? || (raw_transactions_payload.respond_to?(:empty?) && raw_transactions_payload.empty?)
      self.raw_transactions_payload = transactions_snapshot
      save!
      return
    end

    existing = raw_transactions_payload
    new_data = transactions_snapshot

    existing_items = if existing.is_a?(Hash) && existing["items"].is_a?(Array)
      existing["items"]
    elsif existing.is_a?(Array)
      existing
    else
      []
    end

    new_items = if new_data.is_a?(Hash) && new_data["items"].is_a?(Array)
      new_data["items"]
    elsif new_data.is_a?(Array)
      new_data
    else
      []
    end

    existing_ids = existing_items.map { |i| i["id"] }.compact
    items_to_add = new_items.reject { |i| i["id"] && existing_ids.include?(i["id"]) }

    merged_items = existing_items + items_to_add

    merged_payload = if existing.is_a?(Hash)
      existing.merge("items" => merged_items)
    else
      merged_items
    end

    self.raw_transactions_payload = merged_payload
    save!
  end

  def last_transaction_date
    return nil unless linked_account && linked_account.transactions.any?
    linked_account.transactions.order(date: :desc).limit(1).pick(:date)
  end
end
