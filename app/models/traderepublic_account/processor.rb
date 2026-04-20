class TraderepublicAccount::Processor
  attr_reader :traderepublic_account

  def initialize(traderepublic_account)
    @traderepublic_account = traderepublic_account
  end

  def process
    account = traderepublic_account.linked_account
    return unless account

    Rails.logger.info "TraderepublicAccount::Processor - Processing account #{account.id}"

    process_transactions(account)

    begin
      Holding::Materializer.new(account, strategy: :forward).materialize_holdings
    rescue => e
      Rails.logger.error "TraderepublicAccount::Processor - Error materializing holdings: #{e.message}"
    end

    begin
      Balance::Materializer.new(account, strategy: :forward).materialize_balances
    rescue => e
      Rails.logger.error "TraderepublicAccount::Processor - Error materializing balances: #{e.message}"
    end
  end

  private

    def process_transactions(account)
      transactions_data = traderepublic_account.raw_transactions_payload
      return unless transactions_data

      items = if transactions_data.is_a?(Hash)
        transactions_data["items"]
      elsif transactions_data.is_a?(Array)
        transactions_data.find { |pair| pair[0] == "items" }&.last
      end

      return unless items.is_a?(Array)

      Rails.logger.info "TraderepublicAccount::Processor - Processing #{items.size} transactions"
      items.each { |txn| process_single_transaction(account, txn) }
    end

    def process_single_transaction(account, txn)
      return if txn["deleted"] || txn["hidden"]
      return unless txn["status"] == "EXECUTED"

      traderepublic_id = txn["id"]
      title = txn["title"]
      subtitle = txn["subtitle"]
      amount_data = txn["amount"] || {}
      amount = amount_data["value"]
      currency = amount_data["currency"] || "EUR"
      timestamp = txn["timestamp"]

      return unless traderepublic_id && timestamp && amount

      # Trade Republic sends negative for expenses (Buys) and positive for income (Sells).
      # Sure expects the inverse, so invert the sign.
      amount = -amount.to_f

      date = begin
        Time.parse(timestamp).to_date
      rescue StandardError => e
        Rails.logger.warn "TraderepublicAccount::Processor - Failed to parse timestamp #{timestamp.inspect} (#{e.message}); falling back to today"
        Date.today
      end

      if trade?(subtitle)
        process_trade(traderepublic_id, title, subtitle, amount, currency, date, txn)
      else
        import_adapter.import_transaction(
          external_id: traderepublic_id,
          amount: amount,
          currency: currency,
          date: date,
          name: title,
          source: "traderepublic",
          notes: subtitle
        )
      end
    rescue => e
      Rails.logger.error "TraderepublicAccount::Processor - Error processing transaction #{txn['id']}: #{e.message}"
    end

    TRADE_SUBTITLE_REGEX = /ordre d'achat|ordre de vente|buy order|sell order|kauforder|verkaufsorder|plan d'épargne exécuté|savings plan executed|sparplan ausgeführt/i

    def trade?(text)
      return false unless text
      TRADE_SUBTITLE_REGEX.match?(text)
    end

    def process_trade(external_id, title, subtitle, amount, currency, date, txn)
      isin = extract_isin(txn["icon"])
      trade_details = txn["trade_details"] || {}

      quantity_str, price_str, nested_isin = extract_trade_values(trade_details)
      quantity_str ||= txn["quantity"] || txn["qty"]
      price_str ||= txn["price"] || txn["price_per_unit"]
      isin = nested_isin if nested_isin.present?

      effective_subtitle = subtitle.presence || txn["subtitle"]
      op_type =
        if effective_subtitle.to_s.match?(/sell|vente|verkauf/i)
          "sell"
        elsif effective_subtitle.to_s.match?(/buy|achat|kauf/i)
          "buy"
        end

      quantity = parse_quantity(quantity_str) if quantity_str
      quantity = -quantity if quantity && op_type == "sell"
      price = parse_price(price_str) if price_str

      instrument_data = txn["instrument_details"]
      ticker, mic = nil, nil
      if instrument_data.present?
        ticker_mic_pairs = extract_ticker_and_mic(instrument_data, isin)
        ticker, mic = ticker_mic_pairs.first if ticker_mic_pairs.any?
      end

      if isin && quantity.nil? && amount && amount != 0
        Rails.logger.warn "TraderepublicAccount::Processor - Trade #{external_id}: missing quantity/price; importing as cash transaction"
        import_adapter.import_transaction(
          external_id: external_id,
          amount: amount,
          currency: currency,
          date: date,
          name: title,
          source: "traderepublic",
          notes: subtitle
        )
        return
      end

      if isin && quantity && price
        security = find_or_create_security(isin, title, ticker, mic)
        if security
          import_adapter.import_trade(
            external_id: external_id,
            security: security,
            quantity: quantity,
            price: price,
            amount: amount,
            currency: currency,
            date: date,
            name: "#{title} - #{subtitle}",
            source: "traderepublic",
            trade_type: op_type
          )
          return
        end
        Rails.logger.error "TraderepublicAccount::Processor - Could not resolve security for ISIN #{isin}"
      end

      Rails.logger.warn "TraderepublicAccount::Processor - Falling back to cash transaction for #{external_id}"
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: title,
        source: "traderepublic",
        notes: subtitle
      )
    end

    def extract_trade_values(trade_details)
      quantity_str = nil
      price_str = nil
      nested_isin = nil

      return [ nil, nil, nil ] unless trade_details.is_a?(Hash) && trade_details["sections"].is_a?(Array)

      trade_details["sections"].each do |section|
        next unless section["type"] == "table" && section["data"].is_a?(Array)

        section["data"].each do |row|
          case row["title"]
          when "Titres", "Actions", "Shares", "Aktien"
            quantity_str ||= row.dig("detail", "text")
          when "Cours du titre", "Prix du titre", "Share price", "Aktienkurs"
            price_str ||= row.dig("detail", "text")
          end

          nested = row.dig("detail", "action", "payload", "sections")
          next unless nested.is_a?(Array)

          nested.each do |sub_section|
            next unless sub_section["type"] == "table" && sub_section["data"].is_a?(Array)

            sub_section["data"].each do |sub_row|
              case sub_row["title"]
              when "Actions", "Titres", "Shares", "Aktien"
                quantity_str ||= sub_row.dig("detail", "text")
              when "Prix du titre", "Cours du titre", "Share price", "Aktienkurs"
                price_str ||= sub_row.dig("detail", "text")
              end
            end
          end
        end

        if section["data"].is_a?(Hash) && section["data"]["icon"]
          nested_isin ||= extract_isin(section["data"]["icon"])
        end
      end

      [ quantity_str, price_str, nested_isin ]
    end

    def parse_quantity(quantity_str)
      return nil unless quantity_str

      quantity_token = quantity_str.to_s.split.first
      cleaned = quantity_token.to_s.gsub(/[^0-9.,\-+]/, "")
      return nil if cleaned.blank?

      Float(cleaned.tr(",", ".")).abs
    rescue ArgumentError, TypeError
      nil
    end

    def parse_price(price_str)
      return nil unless price_str

      match = price_str.to_s.match(/[+\-]?\d+(?:[.,]\d+)*/)
      return nil unless match

      Float(match[0].tr(",", "."))
    rescue ArgumentError, TypeError
      nil
    end

    def extract_isin(isin_or_icon)
      return nil unless isin_or_icon

      return isin_or_icon if isin_or_icon.match?(/^[A-Z]{2}[A-Z0-9]{9}\d$/)

      match = isin_or_icon.match(%r{logos/([A-Z]{2}[A-Z0-9]{9}\d)/})
      match ? match[1] : nil
    end

    def find_or_create_security(isin, fallback_name = nil, ticker = nil, mic = nil)
      TradeRepublic::SecurityResolver.new(
        isin.to_s.upcase,
        name: fallback_name,
        ticker: ticker&.to_s&.upcase,
        mic: mic&.to_s&.upcase
      ).resolve
    end

    def extract_ticker_and_mic(instrument_data, isin)
      return [ [ isin, nil ] ] unless instrument_data.is_a?(Hash)

      exchanges = instrument_data["exchanges"]
      return [ [ isin, nil ] ] unless exchanges.is_a?(Array) && exchanges.any?

      ordered = exchanges.partition { |ex| ex["active"] == true }.flatten

      ordered.map do |ex|
        ticker = ex["symbolAtExchange"] || ex["symbol"]
        mic = ex["slug"] || ex["mic"] || ex["mic_code"]
        ticker = isin if ticker.blank?
        [ clean_ticker(ticker), mic ]
      end.uniq
    end

    def clean_ticker(ticker)
      return ticker unless ticker

      cleaned = ticker.strip
      return cleaned if cleaned.include?("/")

      cleaned.include?(".") ? cleaned.split(".").first : cleaned
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(traderepublic_account.linked_account)
    end
end
