require "test_helper"

class TraderepublicItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def build_item(**overrides)
    TraderepublicItem.create!({
      family: @family,
      name: "Trade Republic",
      phone_number: "+491234567890",
      pin: "1234"
    }.merge(overrides))
  end

  test "Syncable#perform_sync delegates to TraderepublicItem::Syncer" do
    # Regression guard: the model previously shadowed Syncable#perform_sync
    # with its own override, which made TraderepublicItem::Syncer unreachable.
    item = build_item
    sync = item.syncs.create!

    TraderepublicItem::Syncer.any_instance.expects(:perform_sync).with(sync).once
    item.perform_sync(sync)
  end

  test "#syncer returns a fresh TraderepublicItem::Syncer every call" do
    item = build_item
    assert_kind_of TraderepublicItem::Syncer, item.syncer
    refute_equal item.syncer.object_id, item.syncer.object_id
  end

  test "complete_login! nulls out the PIN on success" do
    item = build_item(process_id: "abc", session_cookies: [ "JSESSIONID=xyz" ])

    provider = mock
    provider.expects(:process_id=).with("abc")
    provider.expects(:jsessionid=)
    provider.expects(:raw_cookies=).at_least(0)
    provider.expects(:verify_device_pin).with("9999")
    provider.stubs(:session_token).returns("sess-token")
    provider.stubs(:refresh_token).returns("refresh-token")
    provider.stubs(:raw_cookies).returns([ "tr_session=sess-token", "tr_refresh=refresh-token" ])
    Provider::Traderepublic.expects(:new).returns(provider)

    assert item.complete_login!("9999")
    item.reload

    assert_nil item.pin
    assert_equal "sess-token", item.session_token
    assert_nil item.process_id
  end

  test "traderepublic_provider works with session tokens after PIN is cleared" do
    # After complete_login! the PIN is nil — but the session is live, so the
    # provider should still be constructible for API calls.
    item = build_item
    item.update_columns(pin: nil, session_token: "sess-token", session_cookies: [])
    assert_not_nil item.reload.traderepublic_provider
  end

  test "session_cookies stored as Hash still yield a usable Array" do
    # Legacy records may carry the old Hash shape — reading should not crash.
    item = build_item(session_cookies: { "jsessionid" => "JSESSIONID=xyz" })
    provider = item.traderepublic_provider
    assert_kind_of Array, provider.raw_cookies
  end
end
