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
    # 但用自定义的 name 和 match_rules（通过公开的 keyword 构造注入）。
    module Loader
      def self.load_from_file!(path)
        return unless File.exist?(path)
        data = JSON.parse(File.read(path))
        unless data.is_a?(Hash)
          warn "[SuTakeoff::Strategies::Loader] root must be an object for #{path}"
          return
        end
        data.each do |name, spec|
          unless spec.is_a?(Hash)
            warn "[SuTakeoff::Strategies::Loader] skipped #{name.inspect}: spec must be an object"
            next
          end
          base = Registry.get(spec['base_strategy']&.to_sym)
          next unless base  # 静默跳过无效引用
          raw_rules = spec['match_rules'] || {}
          unless raw_rules.is_a?(Hash)
            warn "[SuTakeoff::Strategies::Loader] skipped #{name.inspect}: match_rules must be an object"
            next
          end
          begin
            rules = symbolize_keys(raw_rules)
            variant = build_variant(base, name.to_s.to_sym, rules)
            Registry.register(variant)
          rescue RegexpError, ArgumentError => e
            warn "[SuTakeoff::Strategies::Loader] skipped #{name.inspect}: #{e.message}"
          end
        end
      rescue JSON::ParserError => e
        warn "[SuTakeoff::Strategies::Loader] JSON parse failed for #{path}: #{e.message}"
      end

      def self.build_variant(base, new_name, new_rules)
        base.class.new(name: new_name, match_rules: new_rules)
      end

      def self.symbolize_keys(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k.to_sym] = v
        end
      end
    end
  end
end
