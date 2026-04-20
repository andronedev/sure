class TraderepublicItem::Importer
  include TraderepublicSessionConfigurable

  attr_reader :traderepublic_item, :provider

  def initialize(traderepublic_item, traderepublic_provider: nil)
    @traderepublic_item = traderepublic_item
    @provider = traderepublic_provider || traderepublic_item.traderepublic_provider
  end

  def import
    raise "Provider not configured" unless provider
    ensure_session_configured!

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Starting import"

    import_portfolio
    import_transactions

    traderepublic_item.update!(status: :good)

    Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Import completed"
    true
  rescue TraderepublicError => e
    Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Import failed - #{e.message}"

    if [ :unauthorized, :auth_failed ].include?(e.error_code)
      traderepublic_item.update!(status: :requires_update)
      raise
    end

    false
  rescue => e
    Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Import failed - #{e.class}: #{e.message}"
    false
  end

  private

    def find_or_create_security_from_tr(position_or_txn)
      isin = position_or_txn["isin"]&.strip&.upcase.presence
      ticker = position_or_txn["ticker"]&.strip.presence || position_or_txn["symbol"]&.strip.presence
      mic = position_or_txn["exchange_operating_mic"]&.strip.presence || position_or_txn["mic"]&.strip.presence
      name = position_or_txn["name"]&.strip.presence

      TradeRepublic::SecurityResolver.new(isin, name: name, ticker: ticker, mic: mic).resolve
    end

    def import_portfolio
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Fetching portfolio data"

      batch = provider.get_portfolio_and_cash_batch
      portfolio_data = normalize_json(batch[:portfolio]) || {}
      cash_data = normalize_json(batch[:cash])

      account = find_or_create_main_account(portfolio_data)
      update_account_with_portfolio(account, portfolio_data, cash_data)
      import_holdings(account, portfolio_data)
    rescue JSON::ParserError => e
      Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Failed to parse portfolio data - #{e.message}"
    end

    def import_transactions
      Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Fetching transactions"

      account = traderepublic_item.traderepublic_accounts.first
      return unless account

      since_date = account.last_transaction_date
      if account.linked_account.nil? || !account.linked_account.transactions.exists?
        since_date = nil
      end

      transactions_data = provider.get_timeline_transactions(since: since_date)
      return unless transactions_data

      parsed = normalize_json(transactions_data) || {}
      items = extract_items(parsed)

      if items.is_a?(Array) && items.any?
        enrich_items_in_batches(items)
        Rails.logger.info "TraderepublicItem #{traderepublic_item.id}: Snapshot has #{items.size} items"
      end

      account.upsert_traderepublic_transactions_snapshot!(parsed)
    rescue JSON::ParserError => e
      Rails.logger.error "TraderepublicItem #{traderepublic_item.id}: Failed to parse transactions - #{e.message}"
    end

    # Collect ISINs + txn ids up front and fetch them in two batched WebSocket
    # sessions, then merge results back onto the items. Avoids opening N*2
    # connections (one per enrichment call) for large imports.
    def enrich_items_in_batches(items)
      isins = items.map { |t| extract_isin(t) }.compact.uniq
      txn_ids = items.map { |t| t["id"] }.compact.uniq

      instrument_details = isins.any? ? provider.batch_fetch_instrument_details(isins) : {}

      trade_details = {}
      if txn_ids.any?
        provider.batch_websocket_calls do |batch|
          txn_ids.each { |id| trade_details[id] = batch.get_timeline_detail(id) }
        end
      end

      items.each do |txn|
        isin = extract_isin(txn)
        txn["instrument_details"] = instrument_details[isin] if isin && instrument_details[isin]
        txn["trade_details"] = trade_details[txn["id"]] if trade_details[txn["id"]]
      end
    end

    def extract_items(parsed)
      case parsed
      when Hash then parsed["items"]
      when Array
        pair = parsed.find { |p| p[0] == "items" }
        pair ? pair[1] : nil
      end
    end

    def extract_isin(txn)
      isin = txn["isin"] || txn.dig("instrument", "isin") || extract_isin_from_icon(txn["icon"])
      return nil unless isin.is_a?(String)
      isin.match?(/^[A-Z]{2}[A-Z0-9]{10}$/) ? isin : nil
    end

    def extract_isin_from_icon(icon)
      return nil unless icon.is_a?(String)
      match = icon.match(%r{logos/([A-Z]{2}[A-Z0-9]{9}\d)/})
      match ? match[1] : nil
    end

    def normalize_json(value)
      return nil if value.nil?
      value.is_a?(String) ? JSON.parse(value) : value
    end

    def find_or_create_main_account(portfolio_data)
      account = traderepublic_item.traderepublic_accounts.first_or_initialize(
        account_id: "main",
        name: "Trade Republic",
        currency: "EUR"
      )

      account.save! if account.new_record?
      account
    end

    def update_account_with_portfolio(account, portfolio_data, cash_data = nil)
      cash_value = extract_cash_value(portfolio_data, cash_data)

      account.upsert_traderepublic_snapshot!({
        id: "main",
        name: "Trade Republic",
        currency: "EUR",
        balance: cash_value,
        status: "active",
        type: "investment",
        raw: portfolio_data
      })
    end

    def extract_cash_value(portfolio_data, cash_data = nil)
      if cash_data.is_a?(Array) && cash_data.first.is_a?(Hash)
        return cash_data.first["amount"]
      end

      return 0 unless portfolio_data.is_a?(Hash)

      portfolio_data.dig("cash", "value") ||
        portfolio_data.dig("availableCash") ||
        portfolio_data.dig("balance") ||
        0
    end

    def import_holdings(account, portfolio_data)
      positions = extract_positions(portfolio_data)
      return if positions.empty?

      linked_account = account.linked_account
      return unless linked_account

      positions.each do |position|
        security = find_or_create_security_from_tr(position)
        holding_date = position["date"] || Date.current
        next unless holding_date && security

        holding = Holding.find_or_initialize_by(
          account: linked_account,
          security: security,
          date: holding_date,
          currency: position["currency"]
        )
        holding.qty = position["quantity"]
        holding.price = position["price"]
        holding.save!
      end
    end

    def extract_positions(portfolio_data)
      return [] unless portfolio_data.is_a?(Hash)

      categories = portfolio_data["categories"] || []
      categories.flat_map { |category| Array(category["positions"]) }
    end
end
