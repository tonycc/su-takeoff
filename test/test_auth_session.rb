require_relative 'test_helper'

class TestAuthSession < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(login_response: nil, refresh_response: nil, me_response: nil, logout_error: nil)
      @login_response = login_response
      @refresh_response = refresh_response
      @me_response = me_response
      @logout_error = logout_error
      @calls = []
    end

    def login(username:, password:, tenant_id: nil)
      @calls << [:login, username, password, tenant_id]
      raise @login_response if @login_response.is_a?(Exception)

      @login_response
    end

    def refresh(refresh_token:)
      @calls << [:refresh, refresh_token]
      raise @refresh_response if @refresh_response.is_a?(Exception)

      @refresh_response
    end

    def me(access_token:)
      @calls << [:me, access_token]
      @me_response
    end

    def logout(access_token:)
      @calls << [:logout, access_token]
      raise @logout_error if @logout_error

      nil
    end
  end

  def auth_response(access: 'access-1', refresh: 'refresh-1', permissions: ['quantity:ingest'])
    {
      'access_token' => access,
      'refresh_token' => refresh,
      'expires_in' => 3600,
      'subject' => {
        'client_id' => 'su-plugin',
        'permissions' => permissions,
        'tenant_id' => 'tenant-1'
      }
    }
  end

  def test_login_validates_identity_and_stores_refresh_token
    store = SuTakeoff::Api::MemoryCredentialStore.new
    client = FakeClient.new(
      login_response: auth_response,
      me_response: {
        'client_id' => 'su-plugin',
        'permissions' => ['quantity:ingest'],
        'tenant_id' => 'tenant-1'
      }
    )
    session = SuTakeoff::Api::AuthSession.new(api_client: client, credential_store: store)

    state = session.login(username: ' user@example.com ', password: 'secret')

    assert_equal(:signed_in, state[:status])
    assert state[:can_push]
    assert_equal('refresh-1', store.read('user@example.com'))
    assert_equal([:login, 'user@example.com', 'secret', nil], client.calls.first)
    assert_equal([:me, 'access-1'], client.calls.last)
  end

  def test_login_keeps_identity_when_permission_is_missing
    store = SuTakeoff::Api::MemoryCredentialStore.new
    client = FakeClient.new(
      login_response: auth_response(permissions: []),
      me_response: {
        'client_id' => 'su-plugin',
        'permissions' => []
      }
    )
    session = SuTakeoff::Api::AuthSession.new(api_client: client, credential_store: store)

    state = session.login(username: 'user@example.com', password: 'secret')

    assert_equal(:signed_in, state[:status])
    refute state[:can_push]
    assert_equal('PERMISSION_DENIED', session.last_error.code)
  end

  def test_tenant_selection_required_sets_state_without_raising
    error = SuTakeoff::Api::ApiError.new(
      '请选择租户',
      status: 400,
      code: 'TENANT_SELECTION_REQUIRED',
      body: {
        'detail' => {
          'code' => 'TENANT_SELECTION_REQUIRED',
          'message' => 'Please select a tenant',
          'available_tenants' => [
            { 'tenant_id' => 't1', 'tenant_name' => '租户 1' }
          ]
        }
      }
    )
    client = FakeClient.new(login_response: error)
    session = SuTakeoff::Api::AuthSession.new(
      api_client: client,
      credential_store: SuTakeoff::Api::MemoryCredentialStore.new
    )

    state = session.login(username: 'user@example.com', password: 'secret')

    assert_equal(:tenant_selection_required, state[:status])
    assert_equal([{ 'tenant_id' => 't1', 'tenant_name' => '租户 1' }], state[:available_tenants])
  end

  def test_refresh_rotates_token_and_updates_store
    store = SuTakeoff::Api::MemoryCredentialStore.new
    store.write('user@example.com', 'old-refresh')
    client = FakeClient.new(
      refresh_response: auth_response(access: 'access-2', refresh: 'refresh-2'),
      me_response: {
        'client_id' => 'su-plugin',
        'permissions' => ['quantity:ingest']
      }
    )
    session = SuTakeoff::Api::AuthSession.new(api_client: client, credential_store: store)

    state = session.restore(username: 'user@example.com')

    assert_equal(:signed_in, state[:status])
    assert_equal('refresh-2', store.read('user@example.com'))
    assert_equal([:refresh, 'old-refresh'], client.calls.first)
  end

  def test_with_access_token_retry_refreshes_once_on_401
    store = SuTakeoff::Api::MemoryCredentialStore.new
    client = FakeClient.new(
      login_response: auth_response(access: 'access-1', refresh: 'refresh-1'),
      refresh_response: auth_response(access: 'access-2', refresh: 'refresh-2'),
      me_response: {
        'client_id' => 'su-plugin',
        'permissions' => ['quantity:ingest']
      }
    )
    session = SuTakeoff::Api::AuthSession.new(api_client: client, credential_store: store)
    session.login(username: 'user@example.com', password: 'secret')
    attempts = []

    result = session.with_access_token_retry do |token|
      attempts << token
      raise SuTakeoff::Api::ApiError.new('unauthorized', status: 401, code: 'AUTH_INVALID') if attempts.length == 1

      'ok'
    end

    assert_equal('ok', result)
    assert_equal(['access-1', 'access-2'], attempts)
  end

  def test_logout_clears_tokens_even_when_remote_logout_fails
    store = SuTakeoff::Api::MemoryCredentialStore.new
    client = FakeClient.new(
      login_response: auth_response,
      me_response: {
        'client_id' => 'su-plugin',
        'permissions' => ['quantity:ingest']
      },
      logout_error: SuTakeoff::Api::ApiError.new('server down', status: 500, code: 'HTTP_500')
    )
    session = SuTakeoff::Api::AuthSession.new(api_client: client, credential_store: store)
    session.login(username: 'user@example.com', password: 'secret')

    state = session.logout

    assert_equal(:signed_out, state[:status])
    assert_nil store.read('user@example.com')
  end
end
