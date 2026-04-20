class TraderepublicItem::Syncer
  attr_reader :traderepublic_item

  def initialize(traderepublic_item)
    @traderepublic_item = traderepublic_item
  end

  def perform_sync(sync)
    unless traderepublic_item.session_configured?
      traderepublic_item.update!(status: :requires_update)
      sync.update!(status_text: "Login required") if sync.respond_to?(:status_text)
      raise "Trade Republic session is not configured — please log in again"
    end

    sync.update!(status_text: "Importing portfolio from Trade Republic...") if sync.respond_to?(:status_text)

    begin
      traderepublic_item.import_latest_traderepublic_data(sync: sync)
    rescue TraderepublicError => e
      if [ :unauthorized, :auth_failed ].include?(e.error_code)
        traderepublic_item.update!(status: :requires_update)
        sync.update!(status_text: "Authentication failed — login required") if sync.respond_to?(:status_text)
      end
      raise
    end

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = traderepublic_item.traderepublic_accounts.count
    linked_accounts = traderepublic_item.traderepublic_accounts.joins(:linked_account).merge(Account.visible)
    unlinked_accounts = traderepublic_item.traderepublic_accounts.includes(:linked_account).where(accounts: { id: nil })

    if unlinked_accounts.any?
      traderepublic_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      traderepublic_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      traderepublic_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      traderepublic_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: {
        total_accounts: total_accounts,
        linked_accounts: linked_accounts.count,
        unlinked_accounts: unlinked_accounts.count
      })
    end

    linked_accounts.each do |traderepublic_account|
      account = traderepublic_account.linked_account
      next unless account

      Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    end
  end

  def perform_post_sync
  end
end
