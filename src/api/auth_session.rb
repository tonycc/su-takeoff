# src/api/auth_session.rb
require_relative 'api_client'
require_relative 'credential_store'
require 'thread'

module SuTakeoff
  module Api
    class AuthSession
      CLIENT_ID = ApiClient::CLIENT_ID
      REQUIRED_PERMISSION = 'quantity:ingest'.freeze
      TOKEN_SKEW_SECONDS = 60

      attr_reader :status, :subject, :identity, :account, :available_tenants, :last_error

      def initialize(api_client:, credential_store: CredentialStore.default, time_source: -> { Time.now },
                     token_skew: TOKEN_SKEW_SECONDS)
        @api_client = api_client
        @credential_store = credential_store
        @time_source = time_source
        @token_skew = token_skew
        @refresh_mutex = Mutex.new
        reset_memory!
      end

      def signed_in?
        @status == :signed_in
      end

      def can_push?
        signed_in? && permissions.include?(REQUIRED_PERMISSION)
      end

      def login(username:, password:, tenant_id: nil)
        @status = :authenticating
        @account = username.to_s.strip
        response = @api_client.login(username: @account, password: password, tenant_id: tenant_id)
        accept_token_response(response)
        validate_identity!
        write_refresh_token
        @status = :signed_in
        state
      rescue ApiError => e
        if e.code == 'TENANT_SELECTION_REQUIRED'
          @available_tenants = tenant_options_from(e.body)
          @status = :tenant_selection_required
          @last_error = e
          return state
        end
        @status = :error
        @last_error = e
        clear_memory_tokens!
        raise
      end

      def restore(username:)
        @account = username.to_s.strip
        refresh_token = @credential_store.read(credential_account)
        return state unless refresh_token

        refresh!(refresh_token: refresh_token)
      end

      def access_token
        refresh! if token_expiring?
        @access_token
      end

      def refresh!(refresh_token: nil)
        @refresh_mutex.synchronize do
          @status = :refreshing
          token = refresh_token || @refresh_token || @credential_store.read(credential_account)
          unless token
            @status = :expired
            raise ApiError.new('登录已过期，请重新登录', code: 'SESSION_EXPIRED', retryable: false)
          end

          response = @api_client.refresh(refresh_token: token)
          accept_token_response(response)
          validate_identity!
          write_refresh_token
          @status = :signed_in
          state
        rescue ApiError => e
          @status = :expired
          @last_error = e
          clear_tokens!
          raise
        end
      end

      def logout
        begin
          @api_client.logout(access_token: @access_token) if @access_token
        rescue ApiError => e
          @last_error = e
        ensure
          clear_tokens!
          @status = :signed_out
        end
        state
      end

      def with_access_token_retry
        retried = false
        begin
          yield(access_token)
        rescue ApiError => e
          raise if retried || e.status.to_i != 401

          retried = true
          refresh!
          retry
        end
      end

      def state
        {
          status: @status,
          account: @account,
          subject: @subject,
          identity: @identity,
          can_push: can_push?,
          available_tenants: @available_tenants,
          persistent_session: persistent_session?
        }
      end

      private

      def reset_memory!
        @status = :signed_out
        @access_token = nil
        @refresh_token = nil
        @expires_at = nil
        @subject = nil
        @identity = nil
        @account = nil
        @available_tenants = []
        @last_error = nil
      end

      def accept_token_response(response)
        @access_token = response.fetch('access_token')
        @refresh_token = response.fetch('refresh_token')
        @expires_at = now + response.fetch('expires_in', 0).to_i
        @subject = response['subject'] || {}
      rescue KeyError => e
        raise ApiError.new('登录响应缺少必要字段', code: 'INVALID_AUTH_RESPONSE', details: e.message, retryable: false)
      end

      def validate_identity!
        @status = :validating
        @identity = @api_client.me(access_token: @access_token) || {}
        @last_error = nil
        client_id = value_from_identity('client_id')
        unless client_id == CLIENT_ID
          raise ApiError.new('当前账号不是 SketchUp 插件客户端会话', status: 403, code: 'WRONG_CLIENT', retryable: false)
        end
        unless permissions.include?(REQUIRED_PERMISSION)
          @last_error = ApiError.new('当前账号缺少算量推送权限', status: 403, code: 'PERMISSION_DENIED', retryable: false)
        end
      end

      def permissions
        Array(value_from_identity('permissions'))
      end

      def value_from_identity(key)
        return @identity[key] if @identity.is_a?(Hash) && @identity.key?(key)
        return @identity.dig('subject', key) if @identity.is_a?(Hash) && @identity['subject'].is_a?(Hash)
        return @subject[key] if @subject.is_a?(Hash) && @subject.key?(key)

        nil
      end

      def write_refresh_token
        return false unless @account && @credential_store.available?

        @credential_store.write(credential_account, @refresh_token)
      end

      def clear_tokens!
        @credential_store.delete(credential_account) if @account && @credential_store.available?
        clear_memory_tokens!
      end

      def clear_memory_tokens!
        @access_token = nil
        @refresh_token = nil
        @expires_at = nil
      end

      def token_expiring?
        return true unless @access_token && @expires_at

        @expires_at <= now + @token_skew
      end

      def credential_account
        @account.to_s
      end

      def persistent_session?
        @credential_store.available?
      end

      def tenant_options_from(body)
        return [] unless body.is_a?(Hash)
        # 兼容 FastAPI 信封 {"detail": {"available_tenants": [...]}} 和顶层 {"available_tenants": [...]}
        source = body['detail'].is_a?(Hash) ? body['detail'] : body
        Array(source['available_tenants'])
      end

      def now
        @time_source.call
      end
    end
  end
end
