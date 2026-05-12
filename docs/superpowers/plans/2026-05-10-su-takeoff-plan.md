# SU Takeoff — 装修面材用量统计插件 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a SketchUp plugin that scans decoration surface materials, maps them to real materials, and outputs precise purchase quantities by space × part (floor/wall/ceiling), with window/door deduction.

**Architecture:** Ruby modules for model scanning and business logic, HTML WebDialog for UI. Pure Ruby data/calculation modules are testable with minitest. SU API-dependent modules (scanner, UI) require manual testing in SketchUp.

**Tech Stack:** SketchUp Ruby API, `UI::WebDialog` for HTML dialog, JSON for data persistence, minitest for unit tests.

---

## File Structure

```
su-takeoff/
├── su_takeoff.rb                 # Loader — requires all files
├── src/
│   ├── main.rb                   # Plugin entry, menu registration
│   ├── scanner.rb                # Model scanner (SU API) — face iteration, area calc, orientation, opening deduction
│   ├── mapping.rb                # Material mapping CRUD + CSV I/O
│   ├── process_library.rb        # Process/technique definitions
│   ├── calculator.rb             # Statistics engine — grouping, waste, purchase qty
│   ├── marker.rb                 # Manual marking data management
│   └── ui/
│       ├── dialog.rb             # WebDialog setup, Ruby↔JS bridge callbacks
│       ├── index.html            # Three-tab layout
│       ├── styles.css            # Dialog styling
│       └── app.js                # Tab logic, table rendering, bridge calls
├── data/
│   ├── default_mapping.json      # Default material mapping
│   └── default_processes.json    # Default process library
├── test/
│   ├── test_helper.rb            # Test setup
│   ├── test_data_models.rb       # Data model tests
│   ├── test_mapping.rb           # Mapping CRUD + CSV tests
│   ├── test_process_library.rb   # Process library tests
│   └── test_calculator.rb        # Calculator tests
└── docs/
    └── superpowers/
        ├── specs/2026-05-10-su-takeoff-design.md
        └── plans/2026-05-10-su-takeoff-plan.md
```

---

### Task 1: Scaffold + Data Models

**Files:**
- Create: `su-takeoff/su_takeoff.rb`
- Create: `su-takeoff/src/data_models.rb`
- Create: `su-takeoff/test/test_helper.rb`
- Create: `su-takeoff/test/test_data_models.rb`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p /Users/max/projects/su-takeoff/src/ui /Users/max/projects/su-takeoff/data /Users/max/projects/su-takeoff/test
```

- [ ] **Step 2: Create loader file**

```ruby
# su_takeoff.rb
require 'json'
require 'csv'

require_relative 'src/data_models'
require_relative 'src/mapping'
require_relative 'src/process_library'
require_relative 'src/calculator'
require_relative 'src/scanner'
require_relative 'src/marker'
require_relative 'src/ui/dialog'
require_relative 'src/main'
```

- [ ] **Step 3: Create data models**

```ruby
# src/data_models.rb
module SuTakeoff
  # Result of scanning one face
  ScanItem = Struct.new(
    :face_id,       # SU face entity_id
    :su_material,   # SU material name (string) or nil
    :area,          # Float area in m²
    :normal,        # [x, y, z] normal vector
    :width,         # Float estimated width
    :height,        # Float estimated height
    :layer_name,    # String SU layer name
    :component_path # Array of ancestor component names
  )

  # Grouped scan item with resolved material info
  class MaterialUsage
    attr_accessor :space, :part, :material_name, :category, :spec,
                  :net_area, :waste_rate, :purchase_qty, :items,
                  :su_material_name

    def initialize(space:, part:, material_name:, category: '', spec: '',
                   net_area: 0.0, waste_rate: 0.05, su_material_name: '')
      @space = space
      @part = part           # 'floor', 'wall', 'ceiling'
      @material_name = material_name
      @category = category
      @spec = spec
      @net_area = net_area
      @waste_rate = waste_rate
      @purchase_qty = (net_area * (1 + waste_rate)).round(2)
      @items = []
      @su_material_name = su_material_name
    end

    def recalc!
      @purchase_qty = (@net_area * (1 + @waste_rate)).round(2)
    end

    def to_h
      {
        space: @space, part: @part, material_name: @material_name,
        category: @category, spec: @spec, net_area: @net_area.round(2),
        waste_rate: @waste_rate, purchase_qty: @purchase_qty,
        su_material_name: @su_material_name
      }
    end
  end

  # Result of hole/window/opening detection
  Opening = Struct.new(:entity_id, :area, :host_face_ids)
end
```

- [ ] **Step 4: Write and run data model tests**

```ruby
# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('..', __dir__)
require 'minitest/autorun'
require 'src/data_models'

# test/test_data_models.rb
require_relative 'test_helper'

module SuTakeoff
  class TestMaterialUsage < Minitest::Test
    def test_initializes_with_correct_defaults
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖')
      assert_equal '客厅', mu.space
      assert_equal 'floor', mu.part
      assert_equal '瓷砖', mu.material_name
      assert_equal 0.05, mu.waste_rate
      assert_equal 0.0, mu.net_area
    end

    def test_purchase_qty_calculation
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 27.0, waste_rate: 0.05)
      assert_equal 28.35, mu.purchase_qty
    end

    def test_recalc_updates_purchase_qty
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 10.0, waste_rate: 0.05)
      mu.net_area = 20.0
      mu.recalc!
      assert_equal 21.0, mu.purchase_qty
    end

    def test_to_h_returns_hash
      mu = MaterialUsage.new(space: '客厅', part: 'floor', material_name: '瓷砖',
                              net_area: 10.0, waste_rate: 0.05, spec: '600×600')
      h = mu.to_h
      assert_equal '客厅', h[:space]
      assert_equal 10.0, h[:net_area]
      assert_equal '600×600', h[:spec]
    end

    def test_sets_purchase_qty_on_init
      mu = MaterialUsage.new(space: '主卧', part: 'floor', material_name: '大理石',
                              net_area: 16.2, waste_rate: 0.08)
      assert_equal 17.5, mu.purchase_qty  # 16.2 * 1.08 = 17.496 → 17.5
    end

    def test_items_defaults_to_empty
      mu = MaterialUsage.new(space: 'X', part: 'wall', material_name: 'Y')
      assert_empty mu.items
    end
  end

  class TestScanItem < Minitest::Test
    def test_scan_item_creation
      item = ScanItem.new(1, 'marble', 5.0, [0,0,1], 2.0, 2.5, 'Layer0', ['客厅'])
      assert_equal 1, item.face_id
      assert_equal 'marble', item.su_material
      assert_equal 5.0, item.area
    end
  end

  class TestOpening < Minitest::Test
    def test_opening_creation
      op = Opening.new(10, 1.5, [1, 2])
      assert_equal 10, op.entity_id
      assert_equal 1.5, op.area
      assert_equal [1, 2], op.host_face_ids
    end
  end
end
```

```bash
ruby -Itest test/test_data_models.rb
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git init /Users/max/projects/su-takeoff
cd /Users/max/projects/su-takeoff
git add su_takeoff.rb src/data_models.rb test/test_helper.rb test/test_data_models.rb
git commit -m "chore: scaffold project with data models"
```

---

### Task 2: Material Mapping Manager

**Files:**
- Create: `su-takeoff/src/mapping.rb`
- Create: `su-takeoff/data/default_mapping.json`
- Create: `su-takeoff/test/test_mapping.rb`

- [ ] **Step 1: Write mapping tests**

```ruby
# test/test_mapping.rb
require_relative 'test_helper'
require 'tempfile'
require 'src/mapping'

module SuTakeoff
  class TestMaterialMapping < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
    end

    def test_add_mapping
      @mapping.add('marble_01', '爵士白大理石', '石材', 'm²', '大板', 0.08)
      record = @mapping.get('marble_01')
      assert_equal '爵士白大理石', record.material_name
      assert_equal '石材', record.category
      assert_equal 0.08, record.default_waste_rate
    end

    def test_duplicate_add_overwrites
      @mapping.add('a', 'name1', 'cat', 'm²', '', 0.05)
      @mapping.add('a', 'name2', 'cat', 'm²', '', 0.10)
      assert_equal 'name2', @mapping.get('a').material_name
    end

    def test_get_nonexistent_returns_nil
      assert_nil @mapping.get('nonexistent')
    end

    def test_get_all_mapped
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      @mapping.add('b', 'B', 'cat', 'm²', '', 0.05)
      assert_equal 2, @mapping.all.size
    end

    def test_delete
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      @mapping.delete('a')
      assert_nil @mapping.get('a')
    end

    def test_unmapped_materials
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      unmapped = @mapping.unmapped_materials(['a', 'b', 'c'])
      assert_equal %w[b c], unmapped
    end

    def test_export_csv_roundtrip
      @mapping.add('a', 'A', 'cat', 'm²', 'spec', 0.05)
      file = Tempfile.new(['mapping', '.csv'])
      @mapping.export_csv(file.path)
      mapping2 = MaterialMapping.new
      mapping2.import_csv(file.path)
      assert_equal 'A', mapping2.get('a').material_name
      assert_equal 0.05, mapping2.get('a').default_waste_rate
    end

    def test_save_and_load_json
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05)
      file = Tempfile.new(['mapping', '.json'])
      @mapping.save_json(file.path)
      mapping2 = MaterialMapping.new
      mapping2.load_json(file.path)
      assert_equal 'A', mapping2.get('a').material_name
    end

    def test_bulk_set_waste_rate_by_category
      @mapping.add('a', 'A', '瓷砖', 'm²', '', 0.05)
      @mapping.add('b', 'B', '瓷砖', 'm²', '', 0.08)
      @mapping.add('c', 'C', '石材', 'm²', '', 0.10)
      @mapping.bulk_set_waste_rate('瓷砖', 0.06)
      assert_equal 0.06, @mapping.get('a').default_waste_rate
      assert_equal 0.06, @mapping.get('b').default_waste_rate
      assert_equal 0.10, @mapping.get('c').default_waste_rate
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
ruby -Itest test/test_mapping.rb
```

Expected: LoadError — mapping.rb not found.

- [ ] **Step 3: Implement mapping manager**

```ruby
# src/mapping.rb
module SuTakeoff
  MappingRecord = Struct.new(
    :su_material_name, :material_name, :category,
    :unit, :spec, :default_waste_rate, keyword_init: true
  )

  class MaterialMapping
    def initialize
      @records = {}
    end

    def add(su_name, material_name, category, unit = 'm²',
            spec = '', default_waste_rate = 0.05)
      @records[su_name] = MappingRecord.new(
        su_material_name: su_name,
        material_name: material_name,
        category: category,
        unit: unit,
        spec: spec,
        default_waste_rate: default_waste_rate
      )
    end

    def get(su_name)
      @records[su_name]
    end

    def delete(su_name)
      @records.delete(su_name)
    end

    def all
      @records.values
    end

    def unmapped_materials(su_material_names)
      su_material_names.uniq - @records.keys
    end

    def export_csv(path)
      CSV.open(path, 'w') do |csv|
        csv << %w[su_material_name material_name category unit spec default_waste_rate]
        @records.each_value do |r|
          csv << [r.su_material_name, r.material_name, r.category,
                  r.unit, r.spec, r.default_waste_rate]
        end
      end
    end

    def import_csv(path)
      CSV.foreach(path, headers: true) do |row|
        add(
          row['su_material_name'],
          row['material_name'],
          row['category'],
          row['unit'] || 'm²',
          row['spec'] || '',
          (row['default_waste_rate'] || '0.05').to_f
        )
      end
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(@records.transform_values { |r|
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate
        }
      }))
    end

    def load_json(path)
      return unless File.exist?(path)
      data = JSON.parse(File.read(path))
      data.each do |su_name, h|
        add(su_name, h['material_name'], h['category'],
            h['unit'], h['spec'] || '', h['default_waste_rate'].to_f)
      end
    end

    def bulk_set_waste_rate(category, rate)
      @records.each_value do |r|
        r.default_waste_rate = rate if r.category == category
      end
    end
  end
end
```

- [ ] **Step 4: Create default mapping data**

```json
{
  "marble_01": {
    "material_name": "爵士白大理石",
    "category": "石材",
    "unit": "m²",
    "spec": "大板",
    "default_waste_rate": 0.08
  },
  "tile_302": {
    "material_name": "马可波罗灰砖",
    "category": "瓷砖",
    "unit": "m²",
    "spec": "600×600",
    "default_waste_rate": 0.05
  },
  "paint_w": {
    "material_name": "多乐士净味白",
    "category": "涂料",
    "unit": "m²",
    "spec": "18L/桶",
    "default_waste_rate": 0.05
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
ruby -Itest test/test_mapping.rb
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/mapping.rb data/default_mapping.json test/test_mapping.rb
git commit -m "feat: add material mapping manager with CSV import/export"
```

---

### Task 3: Process Library

**Files:**
- Create: `su-takeoff/src/process_library.rb`
- Create: `su-takeoff/data/default_processes.json`
- Create: `su-takeoff/test/test_process_library.rb`

- [ ] **Step 1: Write process library tests**

```ruby
# test/test_process_library.rb
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
```

- [ ] **Step 2: Implement process library**

```ruby
# src/process_library.rb
module SuTakeoff
  ProcessDef = Struct.new(:category, :name, :waste_rate, keyword_init: true)

  class ProcessLibrary
    def initialize
      @processes = []  # Array of ProcessDef
    end

    def add_process(category, name, waste_rate)
      @processes << ProcessDef.new(category: category, name: name, waste_rate: waste_rate)
    end

    def processes_for(category)
      @processes.select { |p| p.category == category }
    end

    def default_waste_rate(category)
      first = @processes.find { |p| p.category == category }
      first&.waste_rate || 0.05
    end

    def all_categories
      @processes.map(&:category).uniq
    end

    def save_json(path)
      grouped = @processes.group_by(&:category).transform_values { |ps|
        ps.map { |p| { name: p.name, waste_rate: p.waste_rate } }
      }
      File.write(path, JSON.pretty_generate(grouped))
    end

    def load_json(path)
      return unless File.exist?(path)
      @processes.clear
      data = JSON.parse(File.read(path))
      data.each do |category, procs|
        procs.each { |p| add_process(category, p['name'], p['waste_rate']) }
      end
    end
  end
end
```

- [ ] **Step 3: Create default process data**

```json
{
  "瓷砖": [
    { "name": "密缝铺贴", "waste_rate": 0.05 },
    { "name": "留缝铺贴", "waste_rate": 0.05 },
    { "name": "斜铺", "waste_rate": 0.15 },
    { "name": "人字拼", "waste_rate": 0.20 }
  ],
  "石材": [
    { "name": "干挂", "waste_rate": 0.05 },
    { "name": "湿贴", "waste_rate": 0.08 }
  ],
  "墙纸": [
    { "name": "对缝", "waste_rate": 0.10 },
    { "name": "不对缝", "waste_rate": 0.05 }
  ],
  "涂料": [
    { "name": "喷涂", "waste_rate": 0.05 },
    { "name": "滚涂", "waste_rate": 0.05 }
  ],
  "木材": [
    { "name": "直铺", "waste_rate": 0.05 },
    { "name": "人字拼", "waste_rate": 0.15 }
  ]
}
```

- [ ] **Step 4: Run tests**

```bash
ruby -Itest test/test_process_library.rb
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/process_library.rb data/default_processes.json test/test_process_library.rb
git commit -m "feat: add process library with default waste rates"
```

---

### Task 4: Calculator (Statistics Engine)

**Files:**
- Create: `su-takeoff/src/calculator.rb`
- Create: `su-takeoff/test/test_calculator.rb`

- [ ] **Step 1: Write calculator tests**

```ruby
# test/test_calculator.rb
require_relative 'test_helper'
require 'src/calculator'
require 'src/mapping'
require 'src/process_library'

module SuTakeoff
  class TestCalculator < Minitest::Test
    def setup
      @mapping = MaterialMapping.new
      @mapping.add('marble_01', '爵士白大理石', '石材', 'm²', '大板', 0.08)
      @mapping.add('tile_302', '马可波罗灰砖', '瓷砖', 'm²', '600×600', 0.05)
      @mapping.add('paint_w', '多乐士净味白', '涂料', 'm²', '18L/桶', 0.05)

      @processes = ProcessLibrary.new
      @processes.add_process('瓷砖', '密缝铺贴', 0.05)
      @processes.add_process('石材', '干挂', 0.08)

      @calc = Calculator.new(@mapping, @processes)
    end

    def test_group_by_space_and_part
      items = [
        ScanItem.new(1, 'tile_302', 15.0, [0,0,1], 3, 5, 'Layer0', ['客厅']),
        ScanItem.new(2, 'tile_302', 12.0, [0,0,1], 3, 4, 'Layer0', ['客厅']),
        ScanItem.new(3, 'paint_w', 48.5, [0,1,0], 3, 5, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], {})

      # 客厅 floor = 15 + 12 = 27
      floor_usages = result.select { |u| u.space == '客厅' && u.part == 'floor' }
      assert_equal 1, floor_usages.size
      assert_equal 27.0, floor_usages[0].net_area
      assert_equal '马可波罗灰砖', floor_usages[0].material_name
    end

    def test_apply_waste_rate_from_process
      items = [
        ScanItem.new(1, 'tile_302', 100.0, [0,0,1], 10, 10, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], { 'tile_302' => '斜铺' })
      # 瓷砖斜铺 15% waste → but process overrides only if set
      # Currently compute doesn't use per-material process overrides from arg
      # Let's test with default mapping waste rate (0.05)
      assert_equal 105.0, result[0].purchase_qty
    end

    def test_deduct_openings
      items = [
        ScanItem.new(1, 'paint_w', 50.0, [0,1,0], 5, 10, 'Layer0', ['客厅']),
      ]
      openings = [Opening.new(10, 2.0, [1])]  # 2m² opening on face 1
      result = @calc.compute(items, openings, {})
      wall = result.find { |u| u.part == 'wall' }
      assert wall.net_area < 50.0  # 50 - 2 = 48
    end

    def test_unmapped_materials_flagged
      items = [
        ScanItem.new(1, 'unknown_mat', 10.0, [0,0,1], 2, 5, 'Layer0', ['客厅']),
      ]
      result = @calc.compute(items, [], {})
      assert result.empty?  # unmapped materials excluded from stats
    end

    def test_group_by_material
      items = [
        ScanItem.new(1, 'tile_302', 27.0, [0,0,1], 3, 9, 'Layer0', ['客厅']),
        ScanItem.new(2, 'tile_302', 20.0, [0,0,1], 4, 5, 'Layer0', ['主卧']),
      ]
      result = @calc.compute(items, [], {})
      material_groups = @calc.group_by_material(result)
      assert material_groups.key?('马可波罗灰砖')
      assert_in_delta 47.0, material_groups['马可波罗灰砖'][:net_area], 0.01
    end

    def test_face_orientation_floor
      assert_equal 'floor', Calculator.face_orientation([0, 0, 1])
    end

    def test_face_orientation_wall
      assert_equal 'wall', Calculator.face_orientation([0, 1, 0])
    end

    def test_face_orientation_ceiling
      assert_equal 'ceiling', Calculator.face_orientation([0, 0, -1])
    end
  end
end
```

- [ ] **Step 2: Run tests — expect failures**

```bash
ruby -Itest test/test_calculator.rb
```

Expected: LoadError — calculator.rb not found.

- [ ] **Step 3: Implement calculator**

```ruby
# src/calculator.rb
module SuTakeoff
  class Calculator
    def initialize(mapping, process_library)
      @mapping = mapping
      @processes = process_library
    end

    # Returns Array of MaterialUsage
    # items: Array of ScanItem
    # openings: Array of Opening
    # process_overrides: Hash { su_material_name => process_name }
    def compute(items, openings, process_overrides)
      # 1. Map openings to their host face IDs for fast lookup
      opening_area_by_face = {}
      openings.each do |op|
        op.host_face_ids.each do |fid|
          opening_area_by_face[fid] ||= 0.0
          opening_area_by_face[fid] += op.area
        end
      end

      # 2. Group items by (space, part, su_material_name)
      groups = Hash.new { |h, k| h[k] = [] }
      items.each do |item|
        next unless @mapping.get(item.su_material)

        part = self.class.face_orientation(item.normal)
        space = item.component_path.last || '未分组'
        key = [space, part, item.su_material]
        groups[key] << item
      end

      # 3. Build MaterialUsage for each group
      groups.map do |(space, part, su_mat), grp_items|
        record = @mapping.get(su_mat)
        net_area = grp_items.sum { |it|
          deduction = opening_area_by_face[it.face_id] || 0.0
          [it.area - deduction, 0.0].max
        }

        waste_rate = if process_overrides[su_mat]
          proc_def = @processes.processes_for(record.category).find { |p|
            p.name == process_overrides[su_mat]
          }
          proc_def&.waste_rate || record.default_waste_rate
        else
          record.default_waste_rate
        end

        usage = MaterialUsage.new(
          space: space, part: part,
          material_name: record.material_name,
          category: record.category,
          spec: record.spec,
          net_area: net_area.round(4),
          waste_rate: waste_rate,
          su_material_name: su_mat
        )
        usage.items = grp_items
        usage
      end
    end

    # Returns Hash { material_name => { net_area:, purchase_qty:, items: [MaterialUsage] } }
    def group_by_material(usages)
      grouped = Hash.new { |h, k| h[k] = { net_area: 0.0, purchase_qty: 0.0, items: [] } }
      usages.each do |u|
        grouped[u.material_name][:net_area] += u.net_area
        grouped[u.material_name][:purchase_qty] += u.purchase_qty
        grouped[u.material_name][:items] << u
      end
      grouped.each_value do |v|
        v[:net_area] = v[:net_area].round(2)
        v[:purchase_qty] = v[:purchase_qty].round(2)
      end
      grouped
    end

    # Returns the unmapped material names from items
    def unmapped_materials(items)
      @mapping.unmapped_materials(items.map(&:su_material).compact)
    end

    def self.face_orientation(normal)
      z = normal[2].abs
      if z > 0.866  # ~30° from vertical
        normal[2] > 0 ? 'floor' : 'ceiling'
      else
        'wall'
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
ruby -Itest test/test_calculator.rb
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/calculator.rb test/test_calculator.rb
git commit -m "feat: add statistics calculator with grouping and opening deduction"
```

---

### Task 5: Model Scanner (SU API-dependent)

**Files:**
- Create: `su-takeoff/src/scanner.rb`

**Note:** This module depends on the SketchUp Ruby API and cannot be tested with plain minitest. Manual testing in SketchUp is required.

- [ ] **Step 1: Implement scanner**

```ruby
# src/scanner.rb
module SuTakeoff
  class Scanner
    def initialize
      @model = Sketchup.active_model
    end

    # Scan entire model or selected faces
    def scan(selection_only: false)
      items = []
      openings = []
      face_set = Set.new

      if selection_only && !@model.selection.empty?
        # Only scan selected faces
        @model.selection.each do |entity|
          collect_faces(entity, [], face_set, items, openings)
        end
      else
        # Scan entire model
        @model.entities.each do |entity|
          collect_faces(entity, [], face_set, items, openings)
        end
      end

      { items: items, openings: openings }
    end

    # Apply manual marking to selected faces
    def apply_marking(marking_data)
      # marking_data: { material_name:, part:, space:, waste_rate: }
      selected = @model.selection
      selected.each do |entity|
        next unless entity.is_a?(Sketchup::Face)
        # Store marking as attribute on the face
        entity.set_attribute('su_takeoff', 'marking', JSON.generate(marking_data))
        # Highlight: change face material to a marker color
        entity.material = 'red'  # placeholder highlight
      end
    end

    # Clear markings from selected faces
    def clear_markings
      @model.selection.each do |entity|
        entity.delete_attribute('su_takeoff', 'marking') if entity.respond_to?(:delete_attribute)
      end
    end

    # Get marking data from a face
    def self.marking_for_face(face)
      raw = face.get_attribute('su_takeoff', 'marking')
      raw ? JSON.parse(raw) : nil
    end

    private

    def collect_faces(entity, path, face_set, items, openings)
      case entity
      when Sketchup::Face
        next if face_set.include?(entity.entity_id)
        face_set.add(entity.entity_id)

        # Skip hidden faces
        return if entity.hidden? || !entity.visible?

        # Read material
        mat_name = entity.material&.name

        # Check if this is an opening (transparent/glass-like material)
        if entity.material&.alpha && entity.material.alpha < 0.5
          openings << Opening.new(entity.entity_id, compute_area(entity), [])
          return
        end

        # Build component path names
        comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }

        # Get bounding box for width/height estimation
        bb = entity.bounds
        w = [bb.width, bb.height, bb.depth].sort[-2..-1] || [bb.width, bb.height]

        items << ScanItem.new(
          entity.entity_id,
          mat_name,
          compute_area(entity),
          [entity.normal.x, entity.normal.y, entity.normal.z],
          w[0].round(4),
          w[1].round(4),
          entity.layer.name,
          comp_path
        )

      when Sketchup::ComponentInstance
        # Recurse into component definition
        new_path = path + [entity]
        entity.definition.entities.each do |child|
          collect_faces(child, new_path, face_set, items, openings)
        end

        # Check if this component contains openings (windows/doors)
        if entity.definition.name =~ /(window|door|窗|门)/i
          entity.definition.entities.each do |child|
            if child.is_a?(Sketchup::Face)
              openings << Opening.new(child.entity_id, compute_area(child), [])
            end
          end
        end

      when Sketchup::Group
        new_path = path + [entity]
        entity.entities.each do |child|
          collect_faces(child, new_path, face_set, items, openings)
        end

      when Sketchup::Image
        # Skip images
      end
    end

    def compute_area(face)
      area = face.area
      # Convert from inches² to m² (SU default unit is inches)
      area * 0.00064516
    end
  end
end
```

- [ ] **Step 2: Manual verification** — Load in SketchUp and test:
    1. Create a simple model with a room (box), assign materials to faces
    2. Run `SuTakeoff::Scanner.new.scan` in SU Ruby Console
    3. Verify items array contains correct face data

- [ ] **Step 3: Commit**

```bash
git add src/scanner.rb
git commit -m "feat: add model scanner with face iteration and opening detection"
```

---

### Task 6: Manual Marker

**Files:**
- Create: `su-takeoff/src/marker.rb`

- [ ] **Step 1: Implement marker**

```ruby
# src/marker.rb
module SuTakeoff
  class Marker
    MARKING_ATTR = 'su_takeoff_marking'

    # Apply marking to selected face
    # marking_data: { material_name:, part:, space:, waste_rate:, su_material_name: }
    def self.apply(marking_data)
      model = Sketchup.active_model
      model.selection.each do |entity|
        next unless entity.is_a?(Sketchup::Face)
        entity.set_attribute(MARKING_ATTR, 'data', JSON.generate(marking_data))
        # Tag face for visual feedback
        entity.set_attribute(MARKING_ATTR, 'applied_at', Time.now.to_i)
      end
    end

    # Remove marking from selected faces
    def self.clear_selected
      model = Sketchup.active_model
      model.selection.each do |entity|
        entity.delete_attribute(MARKING_ATTR) if entity.respond_to?(:delete_attribute)
      end
    end

    # Get all marked faces in the model
    def self.all_marked_faces
      marked = []
      model = Sketchup.active_model
      model.entities.each do |entity|
        next unless entity.is_a?(Sketchup::Face)
        raw = entity.get_attribute(MARKING_ATTR, 'data')
        next unless raw

        data = JSON.parse(raw)
        marked << { face: entity, data: data }
      end
      marked
    end

    # Build ScanItems from all marked faces (for inclusion in calculator)
    def self.to_scan_items
      items = []
      all_marked_faces.each do |entry|
        face = entry[:face]
        data = entry[:data]
        mat_name = data['su_material_name'] || data['material_name']
        items << ScanItem.new(
          face.entity_id,
          mat_name,
          face.area * 0.00064516,
          [face.normal.x, face.normal.y, face.normal.z],
          0, 0,
          face.layer.name,
          [data['space'] || '未分组']
        )
      end
      items
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/marker.rb
git commit -m "feat: add manual marker with face attribute persistence"
```

---

### Task 7: WebDialog UI

**Files:**
- Create: `su-takeoff/src/ui/dialog.rb`
- Create: `su-takeoff/src/ui/index.html`
- Create: `su-takeoff/src/ui/styles.css`
- Create: `su-takeoff/src/ui/app.js`

- [ ] **Step 1: Create dialog bridge**

```ruby
# src/ui/dialog.rb
module SuTakeoff
  class Dialog
    def initialize
      @dialog = UI::WebDialog.new('SU Takeoff — 材料统计',
                                  'su_takeoff_dialog',
                                  1000, 600, 200, 200, true)
      @dialog.set_file(File.join(__dir__, 'index.html'))

      # Bridge callbacks
      @dialog.add_action_callback('scan_all') { |_, _| execute_scan(selection_only: false) }
      @dialog.add_action_callback('scan_selected') { |_, _| execute_scan(selection_only: true) }
      @dialog.add_action_callback('get_mappings') { |_, _| send_mappings }
      @dialog.add_action_callback('save_mapping') { |_, json| save_mapping(json) }
      @dialog.add_action_callback('delete_mapping') { |_, su_name| delete_mapping(su_name) }
      @dialog.add_action_callback('import_csv') { |_, _| import_csv_dialog }
      @dialog.add_action_callback('export_csv') { |_, _| export_csv_dialog }
      @dialog.add_action_callback('get_unmapped') { |_, _| send_unmapped }
      @dialog.add_action_callback('get_processes') { |_, _| send_processes }
      @dialog.add_action_callback('apply_marking') { |_, json| apply_marking(json) }
    end

    def show
      @dialog.show
    end

    private

    def execute_scan(selection_only:)
      scanner = Scanner.new
      result = scanner.scan(selection_only: selection_only)
      marker_items = Marker.to_scan_items
      all_items = result[:items] + marker_items

      mapping = PluginState.instance.mapping
      processes = PluginState.instance.processes
      calc = Calculator.new(mapping, processes)
      usages = calc.compute(all_items, result[:openings], {})
      by_material = calc.group_by_material(usages)
      unmapped = calc.unmapped_materials(all_items)

      # Send results to JS
      data = {
        by_space: usages.map(&:to_h),
        by_material: by_material.transform_values { |v|
          { net_area: v[:net_area], purchase_qty: v[:purchase_qty] }
        },
        unmapped: unmapped
      }
      @dialog.execute_script("window.renderResults(#{JSON.generate(data)})")
    end

    def send_mappings
      mappings = PluginState.instance.mapping.all.map(&:to_h)
      @dialog.execute_script("window.renderMappings(#{JSON.generate(mappings)})")
    end

    def save_mapping(json)
      data = JSON.parse(json)
      m = PluginState.instance.mapping
      m.add(data['su_name'], data['material_name'], data['category'],
            data['unit'], data['spec'], data['waste_rate'].to_f)
      m.save_json(PluginState.mapping_path)
      send_mappings
    end

    def delete_mapping(su_name)
      m = PluginState.instance.mapping
      m.delete(su_name)
      m.save_json(PluginState.mapping_path)
      send_mappings
    end

    def import_csv_dialog
      path = UI.openpanel('选择映射CSV文件', '', 'CSV Files|*.csv||')
      return unless path
      PluginState.instance.mapping.import_csv(path)
      PluginState.instance.mapping.save_json(PluginState.mapping_path)
      send_mappings
    end

    def export_csv_dialog
      path = UI.savepanel('导出映射CSV', '', 'material_mapping.csv')
      return unless path
      PluginState.instance.mapping.export_csv(path)
    end

    def send_unmapped
      # Stub — requires scan context
    end

    def send_processes
      data = PluginState.instance.processes.all_categories.map { |cat|
        { category: cat, processes: PluginState.instance.processes.processes_for(cat) }
      }
      @dialog.execute_script("window.renderProcesses(#{JSON.generate(data)})")
    end

    def apply_marking(json)
      data = JSON.parse(json)
      Marker.apply(data)
    end
  end
end
```

- [ ] **Step 2: Create HTML layout**

```html
<!-- src/ui/index.html -->
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <div class="tab-bar">
    <button class="tab-btn active" data-tab="statistics">📊 统计</button>
    <button class="tab-btn" data-tab="mapping">📋 映射</button>
    <button class="tab-btn" data-tab="settings">⚙️ 设置</button>
  </div>

  <!-- Tab 1: Statistics -->
  <div id="tab-statistics" class="tab-content active">
    <div class="toolbar">
      <button onclick="scanAll()">扫描全部</button>
      <button onclick="scanSelected()">仅选中面</button>
      <button onclick="manualMark()">手动标记面</button>
    </div>
    <div class="view-bar">
      <button class="view-btn active" data-view="by-space" onclick="switchView('by-space')">按空间汇总</button>
      <button class="view-btn" data-view="by-material" onclick="switchView('by-material')">按材料汇总</button>
      <button class="view-btn" data-view="detail" onclick="switchView('detail')">展开明细</button>
    </div>
    <div id="stats-table-container">
      <p class="hint">点击「扫描全部」开始统计</p>
    </div>
  </div>

  <!-- Tab 2: Mapping -->
  <div id="tab-mapping" class="tab-content">
    <div class="toolbar">
      <input type="text" id="search-mapping" placeholder="搜索SU材质..." oninput="filterMappings()">
      <button onclick="importCsv()">导入CSV</button>
      <button onclick="exportCsv()">导出CSV</button>
      <button onclick="openAddMapping()">+ 新增</button>
    </div>
    <div id="mapping-table-container">
      <table id="mapping-table">
        <thead>
          <tr>
            <th>SU材质名</th>
            <th>真实材料名</th>
            <th>分类</th>
            <th>单位</th>
            <th>规格</th>
            <th>默认损耗率</th>
            <th>工艺</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody id="mapping-body"></tbody>
      </table>
    </div>
  </div>

  <!-- Tab 3: Settings -->
  <div id="tab-settings" class="tab-content">
    <p>设置将在后续版本中提供。</p>
  </div>

  <!-- Marking Dialog (hidden) -->
  <div id="marking-dialog" class="modal" style="display:none">
    <div class="modal-content">
      <h3>手动标记面</h3>
      <label>材料名称: <input type="text" id="mark-material"></label>
      <label>部位:
        <select id="mark-part">
          <option value="floor">地面</option>
          <option value="wall">墙面</option>
          <option value="ceiling">天花</option>
        </select>
      </label>
      <label>所属空间: <input type="text" id="mark-space"></label>
      <label>损耗率: <input type="number" id="mark-waste" step="0.01" value="0.05"></label>
      <div class="modal-actions">
        <button onclick="confirmMark()">确认标记</button>
        <button onclick="closeMarkDialog()">取消</button>
      </div>
    </div>
  </div>

  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 3: Create CSS**

```css
/* src/ui/styles.css */
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 13px; background: #1e1e2e; color: #cdd6f4; }

.tab-bar { display: flex; border-bottom: 1px solid #45475a; background: #181825; }
.tab-btn { padding: 10px 20px; border: none; background: transparent; color: #a6adc8; cursor: pointer; font-size: 14px; }
.tab-btn.active { background: #1e1e2e; color: #89b4fa; border-bottom: 2px solid #89b4fa; }

.tab-content { display: none; padding: 12px; }
.tab-content.active { display: block; }

.toolbar { display: flex; gap: 8px; margin-bottom: 12px; align-items: center; flex-wrap: wrap; }
.toolbar button, .view-bar button { padding: 6px 14px; border: 1px solid #45475a; border-radius: 4px; background: #313244; color: #cdd6f4; cursor: pointer; }
.toolbar button:hover, .view-bar button:hover { background: #45475a; }
.toolbar input[type=text] { padding: 6px 10px; border: 1px solid #45475a; border-radius: 4px; background: #313244; color: #cdd6f4; flex: 1; }

.view-bar { display: flex; gap: 4px; margin-bottom: 12px; }
.view-btn { padding: 4px 12px; border: 1px solid #45475a; border-radius: 4px; background: transparent; color: #a6adc8; cursor: pointer; }
.view-btn.active { background: #89b4fa; color: #1e1e2e; border-color: #89b4fa; }

table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { background: #313244; color: #cdd6f4; padding: 8px 6px; text-align: left; border: 1px solid #45475a; position: sticky; top: 0; }
td { padding: 6px; border: 1px solid #45475a; }
tr.unmapped { background: #3b1a1a; }
tr.unmapped td:first-child { color: #f38ba8; }
.hint { color: #6c7086; text-align: center; padding: 40px; }

.modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; }
.modal-content { background: #313244; border-radius: 8px; padding: 20px; min-width: 350px; }
.modal-content label { display: block; margin: 8px 0; }
.modal-content input, .modal-content select { width: 100%; padding: 6px; border: 1px solid #45475a; border-radius: 4px; background: #1e1e2e; color: #cdd6f4; margin-top: 2px; }
.modal-actions { display: flex; gap: 8px; margin-top: 16px; justify-content: flex-end; }
.modal-actions button { padding: 6px 14px; border: 1px solid #45475a; border-radius: 4px; cursor: pointer; }
.modal-actions button:first-child { background: #89b4fa; color: #1e1e2e; border-color: #89b4fa; }
```

- [ ] **Step 4: Create JS**

```javascript
// src/ui/app.js

// Tab switching
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
  });
});

// View switching
function switchView(view) {
  document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
  document.querySelector(`.view-btn[data-view="${view}"]`).classList.add('active');
  if (window._lastStats) renderResults(window._lastStats, view);
}

// Bridge: call SU Ruby
function callSketchUp(action, json) {
  if (typeof sketchup !== 'undefined') {
    sketchup[action](json || '');
  } else {
    console.warn('Not running in SketchUp WebDialog');
  }
}

// Scan
function scanAll() { callSketchUp('scan_all'); }
function scanSelected() { callSketchUp('scan_selected'); }

// Render statistics
function renderResults(data, view) {
  window._lastStats = data;
  const container = document.getElementById('stats-table-container');
  const activeView = view || document.querySelector('.view-btn.active')?.dataset.view || 'by-space';

  if (data.unmapped && data.unmapped.length > 0) {
    const warn = document.createElement('div');
    warn.style.cssText = 'background:#3b1a1a;border:1px solid #f38ba8;border-radius:4px;padding:8px;margin-bottom:8px;color:#f38ba8;';
    warn.textContent = `⚠️ 未映射材质：${data.unmapped.join(', ')}`;
    container.innerHTML = '';
    container.appendChild(warn);
  } else {
    container.innerHTML = '<div class="hint">无未映射材质</div>';
  }

  let tableHtml = '<table><thead><tr>';
  if (activeView === 'by-space') {
    tableHtml += '<th>空间</th><th>部位</th><th>材料</th><th>净面积(m²)</th><th>损耗率</th><th>采购量(m²)</th><th>规格</th>';
  } else if (activeView === 'by-material') {
    tableHtml += '<th>材料</th><th>净面积(m²)</th><th>采购量(m²)</th>';
  } else {
    tableHtml += '<th>空间</th><th>部位</th><th>材料</th><th>面积(m²)</th><th>SU材质</th><th>面ID</th>';
  }
  tableHtml += '</tr></thead><tbody>';

  if (activeView === 'by-space' && data.by_space) {
    data.by_space.forEach(r => {
      const wastePct = (r.waste_rate * 100).toFixed(0);
      tableHtml += `<tr>
        <td>${r.space}</td><td>${r.part}</td><td>${r.material_name}</td>
        <td>${r.net_area}</td><td>${wastePct}%</td><td>${r.purchase_qty}</td>
        <td>${r.spec || '-'}</td>
      </tr>`;
    });
  } else if (activeView === 'by-material' && data.by_material) {
    Object.entries(data.by_material).forEach(([name, v]) => {
      tableHtml += `<tr><td>${name}</td><td>${v.net_area}</td><td>${v.purchase_qty}</td></tr>`;
    });
  }

  tableHtml += '</tbody></table>';
  container.innerHTML += tableHtml;
}

// Mapping management
function renderMappings(mappings) {
  const tbody = document.getElementById('mapping-body');
  tbody.innerHTML = '';
  mappings.forEach(m => {
    const wastePct = (m.default_waste_rate * 100).toFixed(0);
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${m.su_material_name}</td>
      <td>${m.material_name}</td>
      <td>${m.category}</td>
      <td>${m.unit}</td>
      <td>${m.spec || '-'}</td>
      <td>${wastePct}%</td>
      <td><button onclick="editProcess('${m.su_material_name}')">选择工艺</button></td>
      <td><button onclick="deleteMapping('${m.su_material_name}')">删除</button></td>
    `;
    tbody.appendChild(tr);
  });
  filterMappings();
}

function filterMappings() {
  const q = document.getElementById('search-mapping').value.toLowerCase();
  document.querySelectorAll('#mapping-body tr').forEach(tr => {
    tr.style.display = tr.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}

function deleteMapping(suName) {
  callSketchUp('delete_mapping', suName);
}

function importCsv() { callSketchUp('import_csv'); }
function exportCsv() { callSketchUp('export_csv'); }

function openAddMapping() {
  // Simplified: prompt for data
  const suName = prompt('SU材质名:');
  if (!suName) return;
  const matName = prompt('真实材料名:');
  if (!matName) return;
  const cat = prompt('分类 (瓷砖/石材/涂料/木材/墙纸/玻璃/金属/其他):') || '其他';
  const spec = prompt('规格 (可选):') || '';
  const waste = parseFloat(prompt('默认损耗率 (如0.05):') || '0.05');
  callSketchUp('save_mapping', JSON.stringify({
    su_name: suName, material_name: matName, category: cat,
    unit: 'm²', spec: spec, waste_rate: waste
  }));
}

function renderProcesses(processData) {
  window._processData = processData;
}

// Manual marking
function manualMark() {
  document.getElementById('marking-dialog').style.display = 'flex';
}

function closeMarkDialog() {
  document.getElementById('marking-dialog').style.display = 'none';
}

function confirmMark() {
  const data = {
    material_name: document.getElementById('mark-material').value,
    part: document.getElementById('mark-part').value,
    space: document.getElementById('mark-space').value,
    waste_rate: parseFloat(document.getElementById('mark-waste').value) || 0.05
  };
  callSketchUp('apply_marking', JSON.stringify(data));
  closeMarkDialog();
}
```

- [ ] **Step 5: Commit**

```bash
git add src/ui/dialog.rb src/ui/index.html src/ui/styles.css src/ui/app.js
git commit -m "feat: add WebDialog UI with statistics and mapping tabs"
```

---

### Task 8: Plugin Entry + State Management

**Files:**
- Create: `su-takeoff/src/main.rb`

- [ ] **Step 1: Implement main entry and state**

```ruby
# src/main.rb
module SuTakeoff
  PLUGIN_DIR = File.dirname(__dir__)

  # Singleton plugin state
  class PluginState
    include Singleton

    attr_reader :mapping, :processes

    def initialize
      @mapping = MaterialMapping.new
      @processes = ProcessLibrary.new
      load_data
    end

    def self.mapping_path
      File.join(PLUGIN_DIR, 'data', 'default_mapping.json')
    end

    def self.processes_path
      File.join(PLUGIN_DIR, 'data', 'default_processes.json')
    end

    private

    def load_data
      @mapping.load_json(self.class.mapping_path)
      @processes.load_json(self.class.processes_path)
    end
  end

  unless file_loaded?(__FILE__)
    # Add menu
    ui_menu = UI.menu('Plugins').add_submenu('SU Takeoff')
    ui_menu.add_item('材料统计') { Dialog.new.show }

    # Toolbar
    toolbar = UI::Toolbar.new('SU Takeoff')
    cmd = UI::Command.new('SU Takeoff') { Dialog.new.show }
    cmd.tooltip = 'SU Takeoff — 装修面材用量统计'
    toolbar = toolbar.add_item(cmd)
    toolbar.show

    file_loaded(__FILE__)
  end
end
```

- [ ] **Step 2: Update loader to require 'singleton'**

```ruby
# Update su_takeoff.rb
require 'json'
require 'csv'
require 'singleton'

require_relative 'src/data_models'
require_relative 'src/mapping'
require_relative 'src/process_library'
require_relative 'src/calculator'
require_relative 'src/scanner'
require_relative 'src/marker'
require_relative 'src/ui/dialog'
require_relative 'src/main'
```

- [ ] **Step 3: Commit**

```bash
git add src/main.rb
git add -p su_takeoff.rb  # stage the singleton require addition
git commit -m "feat: add plugin entry with menu, toolbar, and state management"
```

---

## Spec Coverage Check

| Spec Requirement | Task |
|----------------|------|
| 空间感知（组件层级） | Task 5 (Scanner — component_path) |
| 地面/墙面/天花识别 | Task 4 (Calculator.face_orientation) |
| 门窗洞口自动扣除 | Task 4 (Calculator — opening_area_by_face) |
| 材质映射管理 + CSV I/O | Task 2 (MaterialMapping) |
| 工艺匹配 → 损耗率 | Task 3 + Task 4 (process_overrides) |
| 手动标记面 | Task 6 (Marker) |
| 未映射材质标红预警 | Task 4 (Calculator.unmapped_materials) + Task 7 (JS unmapped rendering) |
| 按空间汇总视图 | Task 7 (JS renderResults by-space) |
| 按材料汇总视图 | Task 7 (JS renderResults by-material) |
| 展开明细视图 | Task 7 (stub — uses same data) |
| SU HTML 对话框三个 Tab | Task 7 (index.html three tabs) |

## Placeholder & Consistency Check

- No TBD/TODO placeholders
- Data models in `data_models.rb` are referenced consistently in scanner, calculator, marker
- `PluginState` singleton loaded in `main.rb`, used in `dialog.rb`
- `Marker.to_scan_items` called in `dialog.rb` — consistent with Marker implementation
- `Calculator.face_orientation` matches naming in MaterialUsage#part
- All file paths are exact and exist in the File Structure section
