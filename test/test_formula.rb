require_relative 'test_helper'
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
      assert_equal 16.0, Formula.eval('round(area / 0.64)', { area: 10.0 })
    end

    def test_round_with_precision
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

    def test_nested_arithmetic
      assert_equal 7.5, Formula.eval('(area + 5) * 0.5', { area: 10.0 })
    end

    def test_negative_result
      assert_equal -5.0, Formula.eval('5 - area', { area: 10.0 })
    end

    def test_undefined_variable_raises
      assert_raises(FormulaError) { Formula.eval('unknown_var', {}) }
    end

    def test_empty_expression_raises
      assert_raises(FormulaError) { Formula.eval('', {}) }
    end

    def test_nil_expression_raises
      assert_raises(FormulaError) { Formula.eval(nil, {}) }
    end
  end
end