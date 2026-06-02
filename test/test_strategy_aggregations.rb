require_relative 'test_helper'
require 'src/strategies/base'
require 'src/strategies/face_linear'
require 'src/strategies/instance_count'
require 'src/strategies/solid_volume'
require 'src/strategies/solid_linear'
require 'src/strategies/solid_count'
require 'src/strategies/skip'

module SuTakeoff
  class TestStrategyAggregations < Minitest::Test
    def test_face_linear_sums_qty_length_with_fallback
      a = ScanItem.face(face_id: 1, su_material: 'sk', area: 1.0,
                        normal: [0,1,0], width: 0.1, height: 8.0,
                        layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      # qty_length 为 nil → fallback 到 height
      assert_in_delta 8.0, Strategies::FaceLinear.new.aggregate([a], {}), 0.001
    end

    def test_instance_count_sums_qty
      a = ScanItem.instance(face_id: 10, su_material: 'lamp',
                            layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      assert_equal 2.0, Strategies::InstanceCount.new.aggregate([a, a], {})
    end

    def test_solid_volume_sums_qty_volume
      a = ScanItem.solid(face_id: 1, su_material: 'brick', volume: 1.5,
                         width: 1, height: 1, depth: 1.5,
                         layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      b = ScanItem.solid(face_id: 2, su_material: 'brick', volume: 2.0,
                         width: 1, height: 2, depth: 1.0,
                         layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      assert_in_delta 3.5, Strategies::SolidVolume.new.aggregate([a, b], {}), 0.001
    end

    def test_solid_linear_sums_qty_length
      a = ScanItem.linear_solid(face_id: 1, su_material: 'sk', length: 5.0,
                                layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      b = ScanItem.linear_solid(face_id: 2, su_material: 'sk', length: 3.5,
                                layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      assert_in_delta 8.5, Strategies::SolidLinear.new.aggregate([a, b], {}), 0.001
    end

    def test_solid_count_sums_qty_count
      a = ScanItem.count_solid(face_id: 1, su_material: 'handle',
                               layer_name: 'L0', component_path: ['R'], component_path_ids: [1])
      assert_equal 2.0, Strategies::SolidCount.new.aggregate([a, a], {})
    end

    def test_skip_aggregate_returns_zero
      assert_equal 0, Strategies::Skip.new.aggregate([Object.new], {})
    end

    def test_all_strategies_expose_correct_method
      assert_equal :length, Strategies::FaceLinear.new.method
      assert_equal :count,  Strategies::InstanceCount.new.method
      assert_equal :volume, Strategies::SolidVolume.new.method
      assert_equal :length, Strategies::SolidLinear.new.method
      assert_equal :count,  Strategies::SolidCount.new.method
      assert_equal :skip,   Strategies::Skip.new.method
    end
  end
end
