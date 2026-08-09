require_relative 'test_helper'
require 'src/component_sku_mapping'
require 'src/takeoff_policy'

class TestDevelopmentReload < Minitest::Test
  RELOADABLE_VALUE_OBJECTS = {
    SuTakeoff::ScanItem => 'src/data_models.rb',
    SuTakeoff::Opening => 'src/data_models.rb',
    SuTakeoff::ComponentSkuRecord => 'src/component_sku_mapping.rb',
    SuTakeoff::TakeoffPolicy::ResolveResult => 'src/takeoff_policy.rb',
    SuTakeoff::Api::QuantityPayloadBuilder::BuildResult => 'src/api/quantity_payload_builder.rb',
    SuTakeoff::Api::QuantitySyncService::SyncResult => 'src/api/quantity_sync_service.rb'
  }.freeze

  def test_reload_preserves_core_value_object_class_identity
    original_verbose = $VERBOSE
    $VERBOSE = true
    _stdout, stderr = capture_io do
      RELOADABLE_VALUE_OBJECTS.values.uniq.each do |relative_path|
        load File.expand_path("../#{relative_path}", __dir__)
      end
    end

    RELOADABLE_VALUE_OBJECTS.each_key do |klass|
      resolved = klass.name.split('::').reject(&:empty?).reduce(Object) { |scope, name| scope.const_get(name) }
      assert_same klass, resolved
      refute_match(/already initialized constant .*#{Regexp.escape(klass.name.split('::').last)}/, stderr)
    end
  ensure
    $VERBOSE = original_verbose
  end
end
