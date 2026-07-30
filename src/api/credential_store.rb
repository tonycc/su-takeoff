# src/api/credential_store.rb
require 'rbconfig'
require 'open3'
require 'timeout'

module SuTakeoff
  module Api
    class CredentialStore
      class Unavailable < StandardError; end

      DEFAULT_NAMESPACE = 'su_takeoff_api'.freeze

      def self.default(namespace: DEFAULT_NAMESPACE)
        if RbConfig::CONFIG['host_os'].downcase.include?('darwin')
          MacOSKeychainStore.new(namespace: namespace)
        else
          UnavailableStore.new(namespace: namespace)
        end
      end

      def initialize(namespace: DEFAULT_NAMESPACE)
        @namespace = namespace
      end

      def read(_account)
        raise NotImplementedError
      end

      def write(_account, _secret)
        raise NotImplementedError
      end

      def delete(_account)
        raise NotImplementedError
      end

      def available?
        true
      end

      private

      def service_name(account)
        "#{@namespace}:#{account}"
      end
    end

    class UnavailableStore < CredentialStore
      def read(_account)
        nil
      end

      def write(_account, _secret)
        false
      end

      def delete(_account)
        true
      end

      def available?
        false
      end
    end

    class MemoryCredentialStore < CredentialStore
      def initialize(namespace: DEFAULT_NAMESPACE)
        super
        @secrets = {}
      end

      def read(account)
        @secrets[service_name(account)]
      end

      def write(account, secret)
        @secrets[service_name(account)] = secret
        true
      end

      def delete(account)
        @secrets.delete(service_name(account))
        true
      end
    end

    class MacOSKeychainStore < CredentialStore
      SECURITY_TIMEOUT_SECONDS = 5 unless const_defined?(:SECURITY_TIMEOUT_SECONDS)

      def read(account)
        stdout, _stderr, status = capture_security(
          'security', 'find-generic-password',
          '-a', account.to_s,
          '-s', service_name(account),
          '-w'
        )
        return nil unless status.success?

        stdout.to_s.chomp
      end

      def write(account, secret)
        _stdout, _stderr, status = capture_security(
          'security', 'add-generic-password',
          '-U',
          '-a', account.to_s,
          '-s', service_name(account),
          '-w', secret.to_s
        )
        status.success?
      end

      def delete(account)
        _stdout, _stderr, _status = capture_security(
          'security', 'delete-generic-password',
          '-a', account.to_s,
          '-s', service_name(account)
        )
        true
      end

      private

      def capture_security(*cmd)
        Timeout.timeout(SECURITY_TIMEOUT_SECONDS) { Open3.capture3(*cmd) }
      rescue Timeout::Error
        ['', 'security command timeout', failed_status]
      end

      def failed_status
        Struct.new(:success?).new(false)
      end
    end
  end
end
