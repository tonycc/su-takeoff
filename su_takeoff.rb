require 'json'
require 'csv'
require 'singleton'

module SuTakeoff
  ROOT_DIR = __dir__ unless const_defined?(:ROOT_DIR)

  SOURCE_FILES = [
    'src/data_models',

    # strategies 必须在 takeoff_policy / calculator / scanner / workbench_presenter 之前
    'src/strategies/base',
    'src/strategies/registry',
    'src/strategies/face_area',
    'src/strategies/face_linear',
    'src/strategies/instance_count',
    'src/strategies/solid_volume',
    'src/strategies/solid_linear',
    'src/strategies/solid_count',
    'src/strategies/skip',
    'src/length_calculators/base',
    'src/length_calculators/segmented_path',
    'src/strategies/skirting_linear',
    'src/strategies/wire_path',
    'src/strategies/builtin',
    'src/strategies/loader',

    'src/length_calculators/baseline',
    'src/length_calculators/volume_based',
    'src/length_calculators/edge_based',
    'src/length_calculators/chained',
    'src/length_calculators/path_sum',

    'src/mapping',
    'src/component_mapping',
    'src/api/api_error',
    'src/api/error_translator',
    'src/api/http_response',
    'src/api/api_client',
    'src/api/credential_store',
    'src/api/auth_session',
    'src/api/project_binding',
    'src/api/quantity_payload_builder',
    'src/api/sync_outbox',
    'src/api/quantity_sync_service',
    'src/takeoff_policy',
    'src/calculator',
    'src/workbench_presenter',
    'src/scanner',

    'src/ui/dialog',
    'src/main'
  ].freeze unless const_defined?(:SOURCE_FILES)

  def self.dev_mode?
    !!$su_takeoff_dev_mode
  end

  def self.source_path(relative)
    File.join(ROOT_DIR, "#{relative}.rb")
  end

  def self.load_sources!(mode: nil)
    mode ||= dev_mode? ? :load : :require
    SOURCE_FILES.each do |relative|
      path = source_path(relative)
      mode == :load ? load(path) : require(path)
    end
  end

  def self.reload_sources!
    load_sources!(mode: :load)
    reset_plugin_state! if respond_to?(:reset_plugin_state!)
    true
  end
end

SuTakeoff.load_sources!
