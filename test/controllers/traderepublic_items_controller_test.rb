require "test_helper"

class TraderepublicItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "new renders without errors" do
    get new_traderepublic_item_url
    assert_response :success
  end

  test "create persists item without requiring sync_start_date or raw_payload" do
    # Regression for the NOT NULL crash on sync_start_date / raw_payload.
    # Stub the network call so we don't hit Trade Republic in tests.
    Provider::Traderepublic.any_instance.stubs(:initiate_login).returns({ "processId" => "abc-123" })
    Provider::Traderepublic.any_instance.stubs(:jsessionid).returns("JSESSIONID=xyz")

    assert_difference "TraderepublicItem.count", 1 do
      post traderepublic_items_url, params: {
        traderepublic_item: {
          name: "Trade Republic",
          phone_number: "+491234567890",
          pin: "1234"
        }
      }
    end

    item = TraderepublicItem.last
    assert_equal @user.family, item.family
    assert_equal "abc-123", item.process_id
    assert_equal [ "JSESSIONID=xyz" ], item.session_cookies
    assert_nil item.sync_start_date
    assert_nil item.raw_payload
    assert_response :redirect
  end

  test "create rejects invalid phone number format" do
    assert_no_difference "TraderepublicItem.count" do
      post traderepublic_items_url, params: {
        traderepublic_item: { name: "Trade Republic", phone_number: "0033123", pin: "1234" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "safe_return_to_path rejects absolute and protocol-relative URLs" do
    # Fail-safe: phishing vectors must not round-trip through ?return_to=
    get new_traderepublic_item_url(return_to: "https://evil.example.com/steal")
    assert_response :success
    assert_not_includes response.body, "https://evil.example.com"

    get new_traderepublic_item_url(return_to: "//evil.example.com")
    assert_response :success
    assert_not_includes response.body, "//evil.example.com"
  end

  test "sync enqueues TR sync" do
    item = TraderepublicItem.create!(
      family: @user.family,
      name: "Trade Republic",
      phone_number: "+491234567890",
      pin: "1234"
    )
    TraderepublicItem.any_instance.expects(:sync_later).once

    post sync_traderepublic_item_url(item)
    assert_response :redirect
  end
end
