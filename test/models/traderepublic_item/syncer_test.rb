require "test_helper"

class TraderepublicItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = TraderepublicItem.create!(
      family: @family,
      name: "Trade Republic",
      phone_number: "+491234567890",
      pin: "1234"
    )
    @sync = @item.syncs.create!
  end

  test "raises and marks requires_update when no session is configured" do
    assert_raises(RuntimeError) do
      TraderepublicItem::Syncer.new(@item).perform_sync(@sync)
    end

    assert_equal "requires_update", @item.reload.status
  end

  test "propagates auth errors and marks item requires_update" do
    @item.update!(session_token: "live")

    err = TraderepublicError.new("expired", :unauthorized)
    TraderepublicItem.any_instance.expects(:import_latest_traderepublic_data).raises(err)

    assert_raises(TraderepublicError) do
      TraderepublicItem::Syncer.new(@item).perform_sync(@sync)
    end

    assert_equal "requires_update", @item.reload.status
  end

  test "happy path: imports, processes, schedules balance syncs" do
    @item.update!(session_token: "live")
    TraderepublicItem.any_instance.expects(:import_latest_traderepublic_data).returns(true)

    TraderepublicItem::Syncer.new(@item).perform_sync(@sync)

    assert_equal "good", @item.reload.status
  end
end
