class TraderepublicItem < ApplicationRecord
  include Syncable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good, prefix: true

  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  if encryption_ready?
    encrypts :phone_number, deterministic: true
    encrypts :pin, deterministic: true
    encrypts :session_token
    encrypts :refresh_token
  end

  validates :name, presence: true
  validates :phone_number, presence: true, on: :create
  validates :phone_number, format: { with: /\A\+\d{10,15}\z/, message: "must be in international format (e.g., +491234567890)" }, on: :create, if: :phone_number_changed?
  validates :pin, presence: { message: I18n.t("traderepublic_items.errors.pin_required", default: "PIN is required") }, on: :create

  belongs_to :family
  has_one_attached :logo

  has_many :traderepublic_accounts, dependent: :destroy
  has_many :accounts, through: :traderepublic_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_traderepublic_data(skip_token_refresh: false, sync: nil)
    provider = traderepublic_provider
    unless provider
      Rails.logger.error "TraderepublicItem #{id} - Cannot import: provider not configured (no session or credentials)"
      raise StandardError.new(I18n.t("traderepublic_items.errors.provider_not_configured", default: "TradeRepublic provider is not configured"))
    end

    TraderepublicItem::Importer.new(self, traderepublic_provider: provider).import
  rescue TraderepublicError => e
    if [ :unauthorized, :auth_failed ].include?(e.error_code) && !skip_token_refresh && credentials_configured?
      Rails.logger.warn "TraderepublicItem #{id} - Authentication failed, attempting automatic re-authentication"

      if auto_reauthenticate
        import_latest_traderepublic_data(skip_token_refresh: true)
      else
        update!(status: :requires_update)
        raise StandardError.new("Session expired and automatic re-authentication failed. Please log in again manually.")
      end
    else
      Rails.logger.error "TraderepublicItem #{id} - Failed to import data: #{e.message}"
      raise
    end
  rescue => e
    Rails.logger.error "TraderepublicItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def credentials_configured?
    phone_number.present? && pin.present?
  end

  def session_configured?
    session_token.present?
  end

  def traderepublic_provider
    return nil unless session_configured? || credentials_configured?

    Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin,
      session_token: session_token,
      refresh_token: refresh_token,
      raw_cookies: stored_raw_cookies
    )
  end

  def initiate_login!
    provider = Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin
    )

    result = provider.initiate_login
    update!(
      process_id: result["processId"],
      session_cookies: [ provider.jsessionid ].compact
    )
    result
  end

  def complete_login!(device_pin)
    raise I18n.t("traderepublic_items.errors.no_process_id", default: "No processId found") unless process_id

    provider = Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin,
      raw_cookies: stored_raw_cookies
    )
    provider.process_id = process_id
    provider.jsessionid = stored_raw_cookies.find { |c| c.to_s.start_with?("JSESSIONID=") }

    provider.verify_device_pin(device_pin)

    # Session tokens obtained — clear the PIN: TR requires SMS for any future
    # re-auth, so keeping the PIN provides no automation benefit, only risk.
    update!(
      session_token: provider.session_token,
      refresh_token: provider.refresh_token,
      session_cookies: provider.raw_cookies,
      process_id: nil,
      pin: nil,
      status: :good
    )

    true
  rescue => e
    Rails.logger.error "TraderepublicItem #{id}: Login failed - #{e.message}"
    update!(status: :requires_update)
    false
  end

  def pending_login?
    process_id.present? && session_token.blank?
  end

  # Trade Republic does not support silent refresh — any re-auth requires SMS.
  # This method can only initiate login; completion is driven by the user.
  def auto_reauthenticate
    return false unless credentials_configured?

    initiate_login!
    update!(status: :requires_update)
    false
  rescue => e
    Rails.logger.error "TraderepublicItem #{id}: Automatic re-authentication failed - #{e.message}"
    false
  end

  def syncer
    TraderepublicItem::Syncer.new(self)
  end

  def process_accounts
    traderepublic_accounts.includes(:linked_account).each do |tr_account|
      next unless tr_account.linked_account

      TraderepublicAccount::Processor.new(tr_account).process
    end
  end

  def schedule_account_syncs(parent_sync:, window_start_date: nil, window_end_date: nil)
    traderepublic_accounts.joins(:account).merge(Account.visible).each do |tr_account|
      tr_account.linked_account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  private

    def stored_raw_cookies
      case session_cookies
      when Array then session_cookies
      when Hash then session_cookies.values.compact
      else []
      end
    end
end
