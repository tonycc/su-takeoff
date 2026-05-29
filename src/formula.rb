module SuTakeoff
  class FormulaError < StandardError; end

  class Formula
    ALLOWED_VARS = %w[area perimeter count length volume unit_area].freeze

    def self.eval(expr, vars)
      raise FormulaError, "Empty expression" if expr.nil? || expr.strip.empty?

      vars = vars.transform_keys(&:to_s)
      normalized = expr.strip.dup

      # Substitute allowed variables with their numeric values
      ALLOWED_VARS.each do |v|
        if vars.key?(v)
          normalized = normalized.gsub(/\b#{v}\b/, vars[v].to_s)
        elsif normalized =~ /\b#{v}\b/
          raise FormulaError, "Undefined variable: #{v}"
        end
      end

      # Resolve function calls: ceil, floor, round, min, max
      normalized = resolve_functions(normalized)

      # Validate: only digits, operators, parentheses, decimal points, whitespace
      unless normalized =~ /^[\d\s+\-*\/().]+$/
        raise FormulaError, "Invalid expression: #{expr}"
      end

      # Safe arithmetic evaluation via recursive descent parser
      parse_arithmetic(normalized)
    end

    private

    def self.resolve_functions(expr)
      result = expr

      # round(x, n) — two-arg form (resolve first to avoid conflict with single-arg)
      while match = result.match(/round\(([^,]+),\s*(\d+)\)/)
        val = safe_eval(match[1])
        n = match[2].to_i
        result = result.sub(match[0], val.round(n).to_s)
      end

      # Single-arg: ceil, floor, round
      %w[ceil floor round].each do |fn|
        while match = result.match(/#{fn}\(([^()]+)\)/)
          val = safe_eval(match[1])
          result = result.sub(match[0], val.send(fn).to_f.to_s)
        end
      end

      # Two-arg: min, max
      %w[min max].each do |fn|
        while match = result.match(/#{fn}\(([^,]+),\s*([^()]+)\)/)
          a = safe_eval(match[1])
          b = safe_eval(match[2])
          result = result.sub(match[0], [a, b].send(fn).to_f.to_s)
        end
      end

      result
    end

    def self.safe_eval(expr)
      parse_arithmetic(expr)
    end

    # Recursive descent parser for arithmetic: + - * / () and numeric literals
    def self.parse_arithmetic(expr)
      @pos = 0
      @expr = expr.strip
      result = parse_expr
      skip_spaces
      raise FormulaError, "Unexpected character at position #{@pos}" if @pos < @expr.length
      result
    end

    def self.parse_expr
      left = parse_term
      skip_spaces
      while @pos < @expr.length && (@expr[@pos] == '+' || @expr[@pos] == '-')
        op = @expr[@pos]
        @pos += 1
        skip_spaces
        right = parse_term
        skip_spaces
        left = op == '+' ? left + right : left - right
      end
      left
    end

    def self.parse_term
      left = parse_factor
      skip_spaces
      while @pos < @expr.length && (@expr[@pos] == '*' || @expr[@pos] == '/')
        op = @expr[@pos]
        @pos += 1
        skip_spaces
        right = parse_factor
        skip_spaces
        if op == '/'
          raise FormulaError, "Division by zero" if right == 0
          left = left / right
        else
          left = left * right
        end
      end
      left
    end

    def self.parse_factor
      skip_spaces
      if @pos < @expr.length && @expr[@pos] == '('
        @pos += 1
        skip_spaces
        result = parse_expr
        skip_spaces
        raise FormulaError, "Missing closing parenthesis" if @pos >= @expr.length || @expr[@pos] != ')'
        @pos += 1
        skip_spaces
        result
      elsif @pos < @expr.length && @expr[@pos] == '-'
        @pos += 1
        skip_spaces
        -parse_factor
      else
        parse_number
      end
    end

    def self.parse_number
      skip_spaces
      start = @pos
      while @pos < @expr.length && (@expr[@pos] =~ /[\d.]/)
        @pos += 1
      end
      raise FormulaError, "Expected number at position #{@pos}" if @pos == start
      @expr[start..@pos - 1].to_f
    end

    def self.skip_spaces
      while @pos < @expr.length && @expr[@pos] == ' '
        @pos += 1
      end
    end
  end
end