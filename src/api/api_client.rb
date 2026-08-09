# src/api/api_client.rb
require 'json'
require 'net/http'
require 'uri'
require 'securerandom'
require_relative 'api_error'
require_relative 'http_response'

module SuTakeoff
  module Api
    class ApiClient
      CLIENT_ID = 'su-plugin'

      AUTH_LOGIN_PATH = '/api/v1/auth/login'
      AUTH_REFRESH_PATH = '/api/v1/auth/refresh'
      AUTH_LOGOUT_PATH = '/api/v1/auth/logout'
      IDENTITY_ME_PATH = '/api/v1/identity/me'
      QUANTITIES_PATH = '/api/v1/su/quantities'
      MATERIALS_PATH = '/api/v1/su/materials'
      PROJECTS_PATH = '/api/v1/supply/projects'

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 30
      QUANTITY_READ_TIMEOUT = 120

      attr_reader :base_url, :environment

      def initialize(base_url:, environment: 'production', open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT, quantity_read_timeout: QUANTITY_READ_TIMEOUT,
                     transport: nil)
        @base_uri = normalize_base_url(base_url, environment)
        @base_url = @base_uri.to_s.sub(%r{/\z}, '')
        @environment = environment.to_s
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @quantity_read_timeout = quantity_read_timeout
        @transport = transport
      end

      def login(username:, password:, tenant_id: nil)
        body = {
          username: username.to_s.strip,
          password: password,
          client_id: CLIENT_ID
        }
        body[:tenant_id] = tenant_id if tenant_id && !tenant_id.to_s.empty?

        post(AUTH_LOGIN_PATH, body: body)
      end

      def refresh(refresh_token:)
        post(AUTH_REFRESH_PATH, body: { refresh_token: refresh_token })
      end

      def logout(access_token:)
        post(AUTH_LOGOUT_PATH, access_token: access_token)
      end

      def me(access_token:)
        get(IDENTITY_ME_PATH, access_token: access_token)
      end

      def push_quantities(payload:, access_token:)
        post(QUANTITIES_PATH, body: payload, access_token: access_token, read_timeout: @quantity_read_timeout)
      end

      def materials(access_token:, keyword: nil, category_id: nil, brand_id: nil,
                    status: 'active', page: 1, page_size: 20)
        params = {
          'keyword' => keyword,
          'category_id' => category_id,
          'brand_id' => brand_id,
          'status' => status,
          'page' => page,
          'page_size' => page_size
        }
        get(MATERIALS_PATH, access_token: access_token, params: params)
      end

      def projects(access_token:, keyword: nil)
        get(PROJECTS_PATH, access_token: access_token, params: { 'keyword' => keyword })
      end

      def project_products(access_token:, project_id:, keyword: nil, page: 1, page_size: 100)
        id = project_id.to_s.strip
        raise ArgumentError, 'project_id 不能为空' if id.empty?
        raise ArgumentError, 'project_id 格式无效' unless id.match?(/\A[A-Za-z0-9._-]+\z/)

        get("#{PROJECTS_PATH}/#{id}/products",
            access_token: access_token,
            params: { 'keyword' => keyword, 'page' => page, 'page_size' => page_size })
      end

      def get(path, access_token: nil, params: nil, read_timeout: @read_timeout)
        request('GET', path, access_token: access_token, params: params, read_timeout: read_timeout)
      end

      def post(path, body: nil, access_token: nil, read_timeout: @read_timeout)
        request('POST', path, body: body, access_token: access_token, read_timeout: read_timeout)
      end

      def request(method, path, body: nil, access_token: nil, params: nil, read_timeout: @read_timeout)
        uri = build_uri(path, params)
        req = request_class(method).new(uri)
        req['Accept'] = 'application/json'
        req['X-Request-Id'] = request_id
        if access_token && !access_token.to_s.empty?
          req['Authorization'] = "Bearer #{access_token}"
        end
        unless body.nil?
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end

        response = perform_http(uri, req, read_timeout)
        parsed = parse_body(response.body, response.code.to_i)
        http_response = HttpResponse.new(status: response.code.to_i, body: parsed, headers: response_headers(response))
        return http_response.body if http_response.success?

        raise_error_from_response(http_response)
      rescue JSON::GeneratorError => e
        raise ApiError.new('请求 JSON 序列化失败', code: 'JSON_ENCODE_ERROR', details: e.message, retryable: false)
      rescue ApiError
        raise
      rescue Timeout::Error, SocketError, EOFError, IOError, SystemCallError => e
        raise ApiError.new('网络连接失败，请稍后重试', code: 'NETWORK_ERROR', details: e.class.name, retryable: true)
      end

      private

      def normalize_base_url(base_url, environment)
        uri = URI.parse(base_url.to_s)
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError, 'API Base URL 必须使用 http 或 https'
        end
        if uri.hostname.to_s.strip.empty?
          raise ArgumentError, 'API Base URL 必须包含主机名'
        end
        if environment.to_s == 'production' && uri.scheme != 'https'
          raise ArgumentError, '生产 API Base URL 必须使用 HTTPS'
        end
        if uri.user || uri.password || uri.query || uri.fragment
          raise ArgumentError, 'API Base URL 不能包含账号、query 或 fragment'
        end
        uri.path = uri.path.to_s.sub(%r{/\z}, '')
        uri.path = '' if uri.path == '/'
        uri
      rescue URI::InvalidURIError
        raise ArgumentError, 'API Base URL 格式无效'
      end

      def build_uri(path, params = nil)
        clean_path = path.to_s.start_with?('/') ? path.to_s : "/#{path}"
        uri = @base_uri.dup
        uri.path = "#{@base_uri.path}#{clean_path}"
        uri.query = URI.encode_www_form(params.reject { |_, v| v.nil? }) if params && !params.empty?
        uri
      end

      def request_class(method)
        case method.to_s.upcase
        when 'GET' then Net::HTTP::Get
        when 'POST' then Net::HTTP::Post
        else
          raise ArgumentError, "不支持的 HTTP 方法: #{method}"
        end
      end

      def perform_http(uri, req, read_timeout)
        if @transport
          return @transport.call(uri, req, open_timeout: @open_timeout, read_timeout: read_timeout)
        end

        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == 'https',
          open_timeout: @open_timeout,
          read_timeout: read_timeout
        ) do |http|
          http.request(req)
        end
      end

      def parse_body(raw_body, status)
        return nil if raw_body.nil? || raw_body.empty?

        JSON.parse(raw_body)
      rescue JSON::ParserError
        raise ApiError.new(
          '平台响应不是合法 JSON',
          status: status,
          code: 'INVALID_JSON_RESPONSE',
          retryable: status >= 500
        )
      end

      def response_headers(response)
        headers = {}
        if response.respond_to?(:each_header)
          response.each_header { |k, v| headers[k] = v }
        end
        headers
      end

      def raise_error_from_response(response)
        body = response.body.is_a?(Hash) ? response.body : {}
        # FastAPI 错误信封: {"detail": {"code": ..., "message": ...}}
        # 或 422 校验: {"detail": [{"type": ..., "msg": ...}]}
        error_body = unwrap_detail(body)
        code = error_body['code'] || http_code(response.status)
        message = error_body['message'] || default_message(response.status)
        details = error_body['details']
        raise ApiError.new(
          message,
          status: response.status,
          code: code,
          details: details,
          retryable: retryable_status?(response.status),
          body: response.body
        )
      end

      def unwrap_detail(body)
        return body unless body.is_a?(Hash) && body.key?('detail')

        detail = body['detail']
        if detail.is_a?(Hash)
          detail
        elsif detail.is_a?(Array)
          msgs = detail.select { |d| d.is_a?(Hash) }.map { |d| d['msg'] }.compact
          { 'code' => 'VALIDATION_ERROR', 'message' => msgs.join('; ') }
        else
          body
        end
      end

      def http_code(status)
        status ? "HTTP_#{status}" : 'NETWORK_ERROR'
      end

      def default_message(status)
        status ? "平台请求失败，HTTP #{status}" : '网络连接失败，请稍后重试'
      end

      def retryable_status?(status)
        status.to_i == 429 || status.to_i >= 500
      end

      def request_id
        "su-#{SecureRandom.hex(8)}"
      end
    end
  end
end
