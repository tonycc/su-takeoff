require 'json'
require 'csv'
require 'singleton'

require_relative 'src/data_models'

# strategies 必须在 takeoff_policy / calculator / scanner / workbench_presenter 之前
require_relative 'src/strategies/base'
require_relative 'src/strategies/registry'
require_relative 'src/strategies/face_area'
require_relative 'src/strategies/face_linear'
require_relative 'src/strategies/instance_count'
require_relative 'src/strategies/solid_volume'
require_relative 'src/strategies/solid_linear'
require_relative 'src/strategies/solid_count'
require_relative 'src/strategies/skip'
require_relative 'src/strategies/builtin'

require_relative 'src/length_calculators/base'
require_relative 'src/length_calculators/baseline'
require_relative 'src/length_calculators/volume_based'
require_relative 'src/length_calculators/edge_based'
require_relative 'src/length_calculators/chained'

require_relative 'src/mapping'
require_relative 'src/component_mapping'
require_relative 'src/takeoff_policy'
require_relative 'src/calculator'
require_relative 'src/workbench_presenter'
require_relative 'src/scanner'

require_relative 'src/ui/dialog'
require_relative 'src/main'
