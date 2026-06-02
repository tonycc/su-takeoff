require 'json'

module SuTakeoff
  module Strategies
    # 从 data/strategies.json 加载用户自定义策略变体。
    #
    # 每个 entry 形如：
    #   { "<name>": {
    #       "base_strategy": "solid_linear",
    #       "match_rules": { ... }
    #     }
    #   }
    #
    # 复用 base_strategy 的 aggregate / emit_from_container 实现（同 class），
    # 但用自定义的 name 和 match_rules（通过 instance_variable_set 注入，
    # 避免改 7 个内置策略的 initialize 签名）。
    module Loader
      def self.load_from_file!(path)
        return unless File.exist?(path)
        data = JSON.parse(File.read(path))
        data.each do |name, spec|
          base = Registry.get(spec['base_strategy']&.to_sym)
          next unless base  # 静默跳过无效引用
          rules = symbolize_keys(spec['match_rules'] || {})
          variant = build_variant(base, name.to_sym, rules)
          Registry.register(variant)
        end
      rescue JSON::ParserError => e
        warn "[SuTakeoff::Strategies::Loader] JSON parse failed for #{path}: #{e.message}"
      end

      def self.build_variant(base, new_name, new_rules)
        variant = base.class.new
        variant.instance_variable_set(:@name, new_name)
        variant.instance_variable_set(:@match_rules, new_rules)
        variant
      end

      def self.symbolize_keys(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k.to_sym] = v
        end
      end
    end
  end
end
