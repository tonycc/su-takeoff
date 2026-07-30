# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../src/api/api_error'
require_relative '../src/api/error_translator'

class TestErrorTranslator < Minitest::Test
  def test_auth_error_code_is_translated
    error = SuTakeoff::Api::ApiError.new('unauthorized', status: 401, code: 'AUTH_INVALID')

    assert_equal('账号或密码错误，请重新输入', SuTakeoff::Api::ErrorTranslator.login_message(error))
  end

  def test_network_timeout_message_is_translated
    assert_equal(
      '请求超时，请检查网络连接后重试',
      SuTakeoff::Api::ErrorTranslator.login_message('Net::ReadTimeout with #<TCPSocket>')
    )
  end

  def test_invalid_credentials_message_is_translated
    assert_equal(
      '账号或密码错误，请重新输入',
      SuTakeoff::Api::ErrorTranslator.login_message('Invalid credentials')
    )
  end

  def test_prefixed_invalid_credentials_message_is_translated
    assert_equal(
      '账号或密码错误，请重新输入',
      SuTakeoff::Api::ErrorTranslator.login_message('登录状态校验失败：Invalid credentials')
    )
  end

  def test_socket_error_message_is_translated
    assert_equal(
      '无法解析 API 域名，请检查网络或 API 地址',
      SuTakeoff::Api::ErrorTranslator.login_message('SocketError: getaddrinfo: nodename nor servname provided')
    )
  end

  def test_validation_error_code_is_translated
    error = SuTakeoff::Api::ApiError.new(
      'String should have at least 1 character',
      status: 422,
      code: 'VALIDATION_ERROR'
    )

    assert_equal('账号或密码格式不正确，请检查后重试', SuTakeoff::Api::ErrorTranslator.login_message(error))
  end

  def test_existing_chinese_message_is_preserved
    assert_equal('请输入密码', SuTakeoff::Api::ErrorTranslator.login_message('请输入密码'))
  end
end
