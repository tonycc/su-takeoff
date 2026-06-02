$LOAD_PATH.unshift File.expand_path('..', __dir__)
require 'minitest/autorun'
require 'src/data_models'
require 'src/strategies/base'
require 'src/strategies/registry'
require 'src/strategies/face_area'
require 'src/strategies/face_linear'
require 'src/strategies/instance_count'
require 'src/strategies/solid_volume'
require 'src/strategies/solid_linear'
require 'src/strategies/solid_count'
require 'src/strategies/skip'
require 'src/strategies/builtin'
require 'src/strategies/loader'

SuTakeoff::Strategies::Builtin.register_all!
strategies_json = File.join(File.expand_path('..', __dir__), 'data', 'strategies.json')
SuTakeoff::Strategies::Loader.load_from_file!(strategies_json)
