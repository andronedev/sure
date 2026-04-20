class TradeRepublic::SecurityResolver
  def initialize(isin, name: nil, ticker: nil, mic: nil)
    @isin = isin&.strip&.upcase.presence
    @name = name
    @ticker = ticker&.strip.presence
    @mic = mic&.strip.presence
  end

  def resolve
    return nil unless @isin

    find_by_ticker_and_mic || find_by_isin_in_name || create_new
  end

  private

    def find_by_ticker_and_mic
      return nil unless @ticker

      Security.where("UPPER(ticker) = ?", @ticker.upcase)
              .where("UPPER(COALESCE(exchange_operating_mic, '')) = ?", (@mic || "").upcase)
              .first
    end

    def find_by_isin_in_name
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@isin)}%"
      Security.where("name LIKE ?", pattern).first
    end

    def create_new
      display_name = @name.present? ? @name : "Security #{@isin}"
      display_name = "#{display_name} (#{@isin})" unless display_name.include?(@isin)

      Security.create!(name: display_name, ticker: @ticker, exchange_operating_mic: @mic)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.message.include?("Ticker has already been taken") && @ticker

      find_by_ticker_and_mic
    end
end
