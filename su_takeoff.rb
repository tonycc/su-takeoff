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
    'src/strategies/builtin',
    'src/strategies/loader',

    'src/length_calculators/baseline',
    'src/length_calculators/volume_based',
    'src/length_calculators/edge_based',
    'src/length_calculators/chained',
    'src/length_calculators/path_sum',

    'src/component_sku_mapping',
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
    previous_verbose = $VERBOSE
    # 开发重载必然会重新赋值算法常量；这些是预期行为，不应把 Ruby 控制台
    # 淹没在 "already initialized constant" 警告中。语法错误和运行异常仍会抛出。
    $VERBOSE = nil
    # SOURCE_FILES 可能有增删：先作废旧清单快照，重读入口文件拿最新清单。
    # （清单常量有 unless const_defined? 保护，不先 remove_const 永远拿到的是首次加载的旧值；
    #   旧清单若仍包含已删除的文件，load 会抛 LoadError 并使整个重载中断。）
    SuTakeoff.send(:remove_const, :SOURCE_FILES) if SuTakeoff.const_defined?(:SOURCE_FILES, false)
    $su_takeoff_reloading_entry = true
    load File.join(ROOT_DIR, 'su_takeoff.rb')
    $su_takeoff_reloading_entry = false
    load_sources!(mode: :load)
    reset_plugin_state! if respond_to?(:reset_plugin_state!)
    puts '[SuTakeoff] reload_sources!: complete'
    true
  rescue => e
    puts "[SuTakeoff] reload_sources! failed: #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    false
  ensure
    $su_takeoff_reloading_entry = false
    $VERBOSE = previous_verbose
  end
end

SuTakeoff.load_sources! unless $su_takeoff_reloading_entry
