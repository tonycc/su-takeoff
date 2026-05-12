# P3: 损耗率升级为表达式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** P1 的 derivation.formula 字段支持表达式求值，变量集合固定（area/perimeter/count/length/unit_area），支持基本运算和 ceil/floor/round/min/max/sum 函数，替代 P1 中 Calculator 的临时 `eval_formula` 方法。

**Architecture:** 新增 `src/formula.rb` 实现 `Formula.eval(expr, vars)` 极简解释器。白名单函数/变量，无 eval 安全风险。Calculator 调用 `Formula.eval` 替代临时方案。

**Tech Stack:** Ruby, Minitest

---

### Task 1: 编写 Formula 测试用例

**Files:**
- Create: `test/test_formula.rb`

- [ ] **Step 1: 创建 test_formula.rb**

```ruby
require 'test_helper'
require 'src/formula'

module SuTakeoff
  class TestFormula < Minitest::Test
    def test_simple_area
      assert_equal 10.0, Formula.eval('area', { area: 10.0 })
    end

    def test_area_multiply
      assert_equal 50.0, Formula.eval('area * 5', { area: 10.0 })
    end

    def test_area_divide
      assert_equal 2.0, Formula.eval('area / 5', { area: 10.0 })
    end

    def test_area_add
      assert_equal 15.0, Formula.eval('area + 5', { area: 10.0 })
    end

    def test_area_subtract
      assert_equal 5.0, Formula.eval('area - 5', { area: 10.0 })
    end

    def test_ceil_function
      assert_equal 16.0, Formula.eval('ceil(area / 0.64)', { area: 10.0 })
    end

    def test_floor_function
      assert_equal 15.0, Formula.eval('floor(area / 0.64)', { area: 10.0 })
    end

    def test_round_function
      assert_equal 15.6, Formula.eval('round(area / 0.64, 1)', { area: 10.0 })
    end

    def test_min_function
      assert_equal 5.0, Formula.eval('min(area, 5)', { area: 10.0 })
    end

    def test_max_function
      assert_equal 10.0, Formula.eval('max(area, 5)', { area: 10.0 })
    end

    def test_length_variable
      assert_equal 12.0, Formula.eval('length', { length: 12.0 })
    end

    def test_count_variable
      assert_equal 3.0, Formula.eval('count', { count: 3.0 })
    end

    def test_perimeter_variable
      assert_equal 20.0, Formula.eval('perimeter - 3', { perimeter: 23.0 })
    end

    def test_unit_area_variable
      assert_equal 16.0, Formula.eval('ceil(area / unit_area)', { area: 10.0, unit_area: 0.64 })
    end

    def test_complex_expression
      assert_equal 25.5, Formula.eval('area * 2.5 + 0.5', { area: 10.0 })
    end

    def test_undefined_variable_raises
      assert_raises(FormulaError) { Formula.eval('unknown_var', {}) }
    end

    def test_division_by_zero_raises
      assert_raises(FormulaError) { Formula.eval('area / 0', { area: 10.0 }) }
    end

    def test_invalid_expression_raises
      assert_raises(FormulaError) { Formula.eval('abc def', {}) }
    end
  end
end
```

- [ ] **Step 2: 运行测试验证它失败**

Run: `ruby -Itest test/test_formula.rb`
Expected: FAIL — Formula 类未定义

---

### Task 2: 实现 Formula 解释器

**Files:**
- Create: `src/formula.rb`
- Modify: `su_takeoff.rb`

- [ ] **Step 1: 创建 src/formula.rb**

自研极简解释器，只支持白名单运算和函数。不使用 eval，不引入外部 gem。

```ruby
module SuTakeoff
  class FormulaError < StandardError; end

  class Formula
    ALLOWED_VARS = %w[area perimeter count length unit_area].freeze
    ALLOWED_FUNCS = %w[ceil floor round min max sum].freeze

    def self.eval(expr, vars)
      raise FormulaError, "Empty expression" if expr.nil? || expr.strip.empty?

      # Substitute variables
      normalized = expr.strip
      ALLOWED_VARS.each do |v|
        if vars.key?(v)
          normalized = normalized.gsub(/\b#{v}\b/, vars[v].to_s)
        elsif normalized =~ /\b#{v}\b/
          raise FormulaError, "Undefined variable: #{v}"
        end
      end

      # Handle functions: ceil(x), floor(x), round(x), round(x,n), min(a,b), max(a,b)
      # Replace function calls with Ruby-safe equivalents
      result = parse_functions(normalized)

      # Validate: only numbers, operators, parentheses, decimal points allowed
      raise FormulaError, "Invalid expression: #{expr}" unless result =~ /^[\d\s+\-*/().]+$/

      # Safe arithmetic evaluation using simple parser
      safe_eval_arithmetic(result)
    end

    private

    def self.parse_functions(expr)
      # Process function calls from innermost to outermost
      result = expr

      # round(x, n) - special two-arg form
      while match = result.match(/round\(([^,]+),\s*(\d+)\)/)
        val = safe_eval_arithmetic(validate_arithmetic(match[1]))
        n = match[2].to_i
        result = result.sub(match[0], val.round(n).to_s)
      end

      # Single-arg functions: ceil, floor, round
      %w[ceil floor round].each do |fn|
        while match = result.match(/#{fn}\(([^()]+)\)/)
          val = safe_eval_arithmetic(validate_arithmetic(match[1]))
          result = result.sub(match[0], fn == 'round' ? val.round.to_s : val.send(fn).to_s)
        end
      end

      # Two-arg functions: min, max
      %w[min max].each do |fn|
        while match = result.match(/#{fn}\(([^,]+),\s*([^()]+)\)/)
          a = safe_eval_arithmetic(validate_arithmetic(match[1]))
          b = safe_eval_arithmetic(validate_arithmetic(match[2]))
          result = result.sub(match[0], [a, b].send(fn).to_s)
        end
      end

      result
    end

    def self.validate_arithmetic(expr)
      stripped = expr.strip
      raise FormulaError, "Invalid arithmetic: #{expr}" unless stripped =~ /^[\d\s+\-*/().]+$/
      stripped
    end

    def self.safe_eval_arithmetic(expr)
      # Simple recursive descent parser for arithmetic expressions
      # Supports: + - * / () and numeric literals
      @pos = 0
      @expr = expr.strip
      result = parse_expression
      raise FormulaError, "Unexpected character at position #{@pos}" if @pos < @expr.length
      result.to_f
    end

    def self.parse_expression
      left = parse_term
      while @pos < @expr.length && (@expr[@pos] == '+' || @expr[@pos] == '-')
        op = @expr[@pos]
        @pos += 1
        right = parse_term
        left = op == '+' ? left + right : left - right
      end
      left
    end

    def self.parse_term
      left = parse_factor
      while @pos < @expr.length && (@expr[@pos] == '*' || @expr[@pos] == '/')
        op = @expr[@pos]
        @pos += 1
        right = parse_factor
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
      if @pos < @expr.length && @expr[@pos] == '('
        @pos += 1  # skip '('
        result = parse_expression
        raise FormulaError, "Missing closing parenthesis" if @pos >= @expr.length || @expr[@pos] != ')'
        @pos += 1  # skip ')'
        result
      elsif @pos < @expr.length && @expr[@pos] == '-'
        @pos += 1
        -parse_factor
      else
        parse_number
      end
    end

    def self.parse_number
      start = @pos
      while @pos < @expr.length && (@expr[@pos] =~ /[\d.]/)
        @pos += 1
      end
      raise FormulaError, "Expected number at position #{@pos}" if @pos == start
      @expr[start..@pos-1].to_f
    end
  end
end
```

- [ ] **Step 2: 在 su_takeoff.rb 中添加 require**

在 require 链中（su_takeoff.rb），在 `require_relative 'src/data_models'` 之后添加：
```ruby
require_relative 'src/formula'
```

- [ ] **Step 3: 运行测试验证 Formula**

Run: `ruby -Itest test/test_formula.rb`
Expected: 全部 PASS

- [ ] **Step 4: 提交 Formula 解释器**

```bash
git add src/formula.rb test/test_formula.rb su_takeoff.rb
git commit -m "feat: add Formula expression evaluator with safe arithmetic parser"
```

---

### Task 3: Calculator 替换临时 eval_formula 为 Formula.eval

**Files:**
- Modify: `src/calculator.rb`
- Modify: `test/test_calculator.rb`

- [ ] **Step 1: 替换 Calculator 中的 eval_formula**

在 calculator.rb 中删除 Task P1/Step 4 中添加的临时 `eval_formula` 方法，改为调用 `Formula.eval`：

```ruby
# 替换临时方法
def eval_formula(formula, area)
  Formula.eval(formula, { area: area })
end
```

更完整的版本（支持更多变量）：
```ruby
def eval_formula(formula, net_area, item = nil)
  vars = { area: net_area }
  if item
    vars[:length] = item.qty if item.kind == :edge
    vars[:count] = item.qty if item.kind == :instance
    vars[:perimeter] = 0  # TODO: 从空间轮廓计算，P2 后续迭代
  end
  Formula.eval(formula, vars)
end
```

- [ ] **Step 2: 添加 Formula 相关的 Calculator 测试**

```ruby
def test_formula_based_derivation_qty
  item = ScanItem.new(1, 'tile_302', 10.0, 'm2', :face, [0,1,0], 3.0, 3.0, '墙面', ['客厅'], 0.0)
  lib = ProcessLibrary.new
  lib.add_process('瓷砖', '密缝铺贴', [
    Derivation.new(layer: '瓷砖粘结剂', unit: 'kg', formula: 'area * 5', waste_rate: 0.05, category: '辅材'),
    Derivation.new(layer: '瓷砖', unit: 'm2', formula: 'area', waste_rate: 0.05, category: '主材')
  ])
  calc = Calculator.new(@mapping, lib)
  usages = calc.compute([item], [], {})
  glue = usages.find { |u| u.layer == '瓷砖粘结剂' }
  assert_equal 50.0, glue.net_area  # 10 * 5 via Formula.eval
end
```

- [ ] **Step 3: 运行全部测试**

Run: `ruby -Itest test/test_calculator.rb && ruby -Itest test/test_formula.rb`
Expected: 全部 PASS

- [ ] **Step 4: 提交**

```bash
git add src/calculator.rb test/test_calculator.rb
git commit -m "feat: calculator uses Formula.eval for derivation quantity computation"
```