require_relative 'test_helper'
require 'tempfile'
require 'src/process_library'

module SuTakeoff
  class TestProcessLibrary < Minitest::Test
    def setup
      @lib = ProcessLibrary.new
      @lib.add_process('瓷砖', '密缝铺贴', 0.05)
      @lib.add_process('瓷砖', '留缝铺贴', 0.05)
      @lib.add_process('瓷砖', '斜铺', 0.15)
    end

    def test_get_processes_for_category
      ps = @lib.processes_for('瓷砖')
      assert_equal 3, ps.size
      assert_equal '密缝铺贴', ps[0].name
    end

    def test_get_default_waste_rate
      rate = @lib.default_waste_rate('瓷砖')
      assert_equal 0.05, rate
    end

    def test_process_for_nonexistent_category
      ps = @lib.processes_for('木材')
      assert_empty ps
    end

    def test_save_and_load_json
      file = Tempfile.new(['processes', '.json'])
      @lib.save_json(file.path)
      lib2 = ProcessLibrary.new
      lib2.load_json(file.path)
      assert_equal 3, lib2.processes_for('瓷砖').size
    end
  end
end
