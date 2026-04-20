require "test_helper"

class TradeRepublic::SecurityResolverTest < ActiveSupport::TestCase
  setup do
    Holding.delete_all
    Security::Price.delete_all
    Trade.delete_all
    Security.delete_all
  end

  test "returns nil when ISIN is blank" do
    assert_nil TradeRepublic::SecurityResolver.new(nil).resolve
    assert_nil TradeRepublic::SecurityResolver.new("").resolve
  end

  test "prefers ticker+mic exact match over ISIN-in-name fallback" do
    winner = Security.create!(name: "Apple Inc.", ticker: "AAPL", exchange_operating_mic: "XNAS")
    # Decoy whose name contains the ISIN — should NOT win when a ticker/mic match is available
    Security.create!(name: "Decoy US0378331005 Token", ticker: "DECOY", exchange_operating_mic: "XDEC")

    resolver = TradeRepublic::SecurityResolver.new("US0378331005", ticker: "AAPL", mic: "XNAS")
    assert_equal winner, resolver.resolve
  end

  test "falls back to ISIN-in-name search when ticker/mic not provided" do
    security = Security.create!(name: "Apple Inc. US0378331005", ticker: "AAPL1", exchange_operating_mic: "XNAS")
    resolver = TradeRepublic::SecurityResolver.new("US0378331005")
    assert_equal security, resolver.resolve
  end

  test "creates new security when neither lookup matches" do
    resolver = TradeRepublic::SecurityResolver.new("US0000000001", name: "Test Security", ticker: "TEST1", mic: "XTST")
    security = resolver.resolve

    assert security.persisted?
    assert_equal "Test Security (US0000000001)", security.name
    assert_equal "TEST1", security.ticker
    assert_equal "XTST", security.exchange_operating_mic
  end

  test "returns existing security when ticker+mic unique index would be violated" do
    existing = Security.create!(name: "Existing", ticker: "DUPL1", exchange_operating_mic: "XDUP")
    resolver = TradeRepublic::SecurityResolver.new("US0000000002", name: "Other", ticker: "DUPL1", mic: "XDUP")
    assert_equal existing, resolver.resolve
  end

  test "ISIN-in-name lookup tolerates LIKE wildcards in input" do
    # Real ISINs are [A-Z0-9]; this guards against malformed input not blowing up
    # the SQL LIKE query with unescaped % or _ wildcards.
    resolver = TradeRepublic::SecurityResolver.new("US0378%33_005", ticker: "WILD1", mic: "XWLD")
    assert_nothing_raised { resolver.resolve }
  end
end
