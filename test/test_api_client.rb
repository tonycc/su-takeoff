require_relative 'test_helper'

class TestApiClient < Minitest::Test
  FakeResponse = Struct.new(:code, :body) do
    def each_header
      yield 'content-type', 'application/json'
    end
  end

  class Transport
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def call(uri, request, open_timeout:, read_timeout:)
      @calls << {
        uri: uri,
        request: request,
        open_timeout: open_timeout,
        read_timeout: read_timeout
      }
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  def test_login_posts_json_with_client_id_and_trimmed_username
    transport = Transport.new(FakeResponse.new('200', '{"ok":true}'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    result = client.login(username: ' user@example.com ', password: 'secret')

    assert_equal({ 'ok' => true }, result)
    call = transport.calls.first
    assert_equal('/api/v1/auth/login', call[:uri].path)
    assert_equal('application/json', call[:request]['Content-Type'])
    assert_equal('application/json', call[:request]['Accept'])
    body = JSON.parse(call[:request].body)
    assert_equal('user@example.com', body['username'])
    assert_equal('secret', body['password'])
    assert_equal('su-plugin', body['client_id'])
  end

  def test_authorization_header_and_quantity_timeout
    transport = Transport.new(FakeResponse.new('200', '{"sheet_id":"s1"}'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    client.push_quantities(payload: { protocol_version: 2, components: [] }, access_token: 'token-value')

    call = transport.calls.first
    assert_equal('/api/v1/su/quantities', call[:uri].path)
    assert_equal('Bearer token-value', call[:request]['Authorization'])
    assert_equal(120, call[:read_timeout])
  end

  def test_empty_success_body_returns_nil
    transport = Transport.new(FakeResponse.new('204', ''))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    assert_nil client.logout(access_token: 'token-value')
  end

  def test_error_response_becomes_api_error_without_leaking_request_body
    transport = Transport.new(FakeResponse.new('403', '{"detail":{"code":"PERMISSION_DENIED","message":"缺少权限","details":{"role":"viewer"}}}'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    error = assert_raises(SuTakeoff::Api::ApiError) do
      client.push_quantities(payload: { password: 'secret', token: 'abc' }, access_token: 'token-value')
    end

    assert_equal(403, error.status)
    assert_equal('PERMISSION_DENIED', error.code)
    assert_equal('缺少权限', error.message)
    assert_equal({ 'role' => 'viewer' }, error.details)
    refute error.retryable?
    refute_includes(error.message, 'secret')
    refute_includes(error.message, 'token-value')
    # body 保留原始响应（含 detail 信封）
    assert_equal({ 'detail' => { 'code' => 'PERMISSION_DENIED', 'message' => '缺少权限', 'details' => { 'role' => 'viewer' } } }, error.body)
  end

  def test_fastapi_validation_error_array_becomes_validation_error
    transport = Transport.new(FakeResponse.new('422', '{"detail":[{"type":"string_too_short","loc":["body","username"],"msg":"String should have at least 1 character"},{"type":"string_too_short","loc":["body","password"],"msg":"String should have at least 1 character"}]}'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    error = assert_raises(SuTakeoff::Api::ApiError) do
      client.login(username: '', password: '')
    end

    assert_equal(422, error.status)
    assert_equal('VALIDATION_ERROR', error.code)
    assert_includes(error.message, 'String should have at least 1 character')
    refute error.retryable?
  end

  def test_error_response_without_detail_envelope_still_works
    transport = Transport.new(FakeResponse.new('500', '{"code":"INTERNAL","message":"内部错误"}'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    error = assert_raises(SuTakeoff::Api::ApiError) { client.me(access_token: 'token-value') }

    assert_equal(500, error.status)
    assert_equal('INTERNAL', error.code)
    assert_equal('内部错误', error.message)
    assert error.retryable?
  end

  def test_invalid_json_success_response_is_error
    transport = Transport.new(FakeResponse.new('200', 'not-json'))
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    error = assert_raises(SuTakeoff::Api::ApiError) { client.me(access_token: 'token-value') }

    assert_equal(200, error.status)
    assert_equal('INVALID_JSON_RESPONSE', error.code)
  end

  def test_network_error_is_retryable
    transport = Transport.new(Errno::ECONNREFUSED.new)
    client = SuTakeoff::Api::ApiClient.new(
      base_url: 'https://api.example.com',
      transport: transport
    )

    error = assert_raises(SuTakeoff::Api::ApiError) { client.me(access_token: 'token-value') }

    assert_equal('NETWORK_ERROR', error.code)
    assert error.retryable?
  end

  def test_production_base_url_requires_https
    assert_raises(ArgumentError) do
      SuTakeoff::Api::ApiClient.new(base_url: 'http://api.example.com')
    end
  end

  def test_development_base_url_allows_http
    client = SuTakeoff::Api::ApiClient.new(base_url: 'http://127.0.0.1:8000', environment: 'development')

    assert_equal('http://127.0.0.1:8000', client.base_url)
  end

  def test_materials_builds_query_and_parses_items
    transport = Transport.new(FakeResponse.new(
      '200', '{"total":1,"page":2,"page_size":5,"items":[{"sku_id":"s1","code":"SKU-1","name":"白橡木 18mm"}]}'
    ))
    client = SuTakeoff::Api::ApiClient.new(base_url: 'https://api.example.com', transport: transport)

    result = client.materials(access_token: 'tok', keyword: '橡木', page: 2, page_size: 5)

    assert_equal(1, result['total'])
    assert_equal('SKU-1', result['items'].first['code'])
    call = transport.calls.first
    assert_equal('/api/v1/su/materials', call[:uri].path)
    assert_equal('Bearer tok', call[:request]['Authorization'])
    query = URI.decode_www_form(call[:uri].query).to_h
    assert_equal('橡木', query['keyword'])
    assert_equal('2', query['page'])
    assert_equal('5', query['page_size'])
    assert_equal('active', query['status'])
    refute(query.key?('category_id'), 'nil 参数不应出现在 query')
  end

  def test_materials_error_becomes_api_error
    transport = Transport.new(FakeResponse.new(
      '403', '{"detail":{"code":"MODULE_DISABLED","message":"租户未启用供应链模块"}}'
    ))
    client = SuTakeoff::Api::ApiClient.new(base_url: 'https://api.example.com', transport: transport)

    err = assert_raises(SuTakeoff::Api::ApiError) { client.materials(access_token: 'tok') }
    assert_equal('MODULE_DISABLED', err.code)
  end

  def test_materials_default_query_values
    transport = Transport.new(FakeResponse.new('200', '{"total":0,"items":[]}'))
    client = SuTakeoff::Api::ApiClient.new(base_url: 'https://api.example.com', transport: transport)

    client.materials(access_token: 'tok')

    query = URI.decode_www_form(transport.calls.first[:uri].query).to_h
    assert_equal '1', query['page']
    assert_equal '20', query['page_size']
    assert_equal 'active', query['status']
    refute query.key?('keyword')
  end
end
