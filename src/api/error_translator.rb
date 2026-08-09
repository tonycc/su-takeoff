# src/api/error_translator.rb
module SuTakeoff
  module Api
    module ErrorTranslator
      CODE_MESSAGES = {
        'AUTH_INVALID' => '账号或密码错误，请重新输入',
        'INVALID_CREDENTIALS' => '账号或密码错误，请重新输入',
        'UNAUTHORIZED' => '账号或密码错误，请重新输入',
        'HTTP_401' => '账号或密码错误，请重新输入',
        'TENANT_SELECTION_REQUIRED' => '请选择租户后重新登录',
        'NETWORK_ERROR' => '网络连接失败，请检查网络连接后重试',
        'SESSION_EXPIRED' => '登录已过期，请重新登录',
        'INVALID_AUTH_RESPONSE' => '登录响应格式异常，请联系平台管理员',
        'WRONG_CLIENT' => '当前账号不是 SketchUp 插件客户端会话',
        'PERMISSION_DENIED' => '当前账号缺少算量推送权限',
        'PROJECT_BINDING_REQUIRED' => '请先在项目绑定页保存平台项目绑定',
        'PROJECT_NOT_FOUND' => '未找到对应的平台项目，请检查项目编号',
        'MODULE_DISABLED' => '当前租户未启用供应链模块',
        'VALIDATION_ERROR' => '账号或密码格式不正确，请检查后重试',
        'INVALID_JSON_RESPONSE' => '平台响应格式异常，请稍后重试',
        'HTTP_400' => '登录请求参数不正确，请检查账号密码',
        'HTTP_403' => '当前账号没有使用插件的权限',
        'HTTP_404' => '登录接口不存在，请检查 API 地址配置',
        'HTTP_429' => '登录请求过于频繁，请稍后重试',
        'HTTP_500' => '平台服务异常，请稍后重试',
        'HTTP_502' => '平台网关异常，请稍后重试',
        'HTTP_503' => '平台服务暂不可用，请稍后重试',
        'HTTP_504' => '平台响应超时，请稍后重试'
      }.freeze

      PATTERN_MESSAGES = [
        [/execution expired|Net::OpenTimeout|Net::ReadTimeout|Timeout|timed out/i, '请求超时，请检查网络连接后重试'],
        [/SocketError|getaddrinfo|nodename nor servname|Name or service not known/i, '无法解析 API 域名，请检查网络或 API 地址'],
        [/ECONNREFUSED|Connection refused/i, '无法连接 API 服务，请检查服务是否可用'],
        [/ECONNRESET|Connection reset|EOFError|end of file/i, '网络连接被中断，请稍后重试'],
        [/certificate|SSL|OpenSSL/i, 'HTTPS 证书校验失败，请检查系统时间或证书配置'],
        [/invalid credentials|invalid username|invalid password|bad credentials/i, '账号或密码错误，请重新输入'],
        [/401|unauthorized/i, '账号或密码错误，请重新输入'],
        [/403|forbidden/i, '当前账号没有使用插件的权限'],
        [/429|rate limit|too many requests/i, '登录请求过于频繁，请稍后重试'],
        [/500|502|503|504|server error|server down/i, '平台服务异常，请稍后重试']
      ].freeze

      module_function

      def login_message(error_or_message)
        code = extract_code(error_or_message)
        return CODE_MESSAGES[code] if code && CODE_MESSAGES.key?(code)

        status_code = extract_status_code(error_or_message)
        http_code = status_code && "HTTP_#{status_code}"
        return CODE_MESSAGES[http_code] if http_code && CODE_MESSAGES.key?(http_code)

        raw = extract_message(error_or_message)
        matched = PATTERN_MESSAGES.find { |pattern, _message| raw.match?(pattern) }
        return matched[1] if matched
        return raw if chinese?(raw)

        '登录失败，请稍后重试'
      end

      def extract_code(error_or_message)
        return nil unless error_or_message.respond_to?(:code)

        error_or_message.code.to_s
      end

      def extract_status_code(error_or_message)
        return nil unless error_or_message.respond_to?(:status)

        status = error_or_message.status
        status && status.to_i.positive? ? status.to_i : nil
      end

      def extract_message(error_or_message)
        message = if error_or_message.respond_to?(:message)
                    error_or_message.message
                  else
                    error_or_message
                  end
        message.to_s.strip
      end

      def chinese?(message)
        message.match?(/[\u4e00-\u9fff]/)
      end
    end
  end
end
