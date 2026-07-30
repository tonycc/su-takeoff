# 材质–供应链 SKU 关联 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户在材料映射页通过平台 `GET /api/v1/su/materials` 搜索并选择 SKU 与 SU 材质关联，持久化并在模型视图「产品信息」列展示「编码 名称」。

**Architecture:** 后端 `ApiClient#materials`（新增 query 支持）→ `dialog#search_skus` 回调（复用 AuthSession，后台线程 + UI 队列泵）→ 前端行内自动补全。关联存入 `MaterialMappingRecord`（JSON + 模型字典双持久化）。`WorkbenchPresenter` 把 SKU 附到 `geometry_usage`，`model_view` 在材料汇总行展示。

**Tech Stack:** Ruby（SketchUp 插件运行时，Minitest 单测独立于 SU）、原生 JS（HtmlDialog 全局命名空间）、CSS。

**参考文档：** `docs/superpowers/specs/2026-07-30-material-sku-association-design.md`

**测试命令：**
- 单文件：`ruby -Itest test/test_mapping.rb`
- 全量：`ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`

**文件责任划分：**
- `src/mapping.rb` — MaterialMappingRecord 增 SKU 三字段 + 全部持久化方法（add/to_h/json/csv）
- `src/api/api_client.rb` — get/request/build_uri 增 params 支持；新增 `materials`
- `src/workbench_presenter.rb` — geometry_usage 附 sku_code/sku_name
- `src/ui/dialog.rb` — save_mapping 传 SKU；新增 search_skus 回调
- `src/ui/index.html` — 两个映射行模板增「平台SKU」单元格
- `src/ui/js/mapping.js` — 表头增列、行回显、自动补全、receiveSkuResults、save 携带 SKU
- `src/ui/js/model_view.js` — 材料汇总行 tdInfo 填 SKU
- `src/ui/styles.css` — 下拉样式
- `test/test_mapping.rb` / `test/test_api_client.rb` / `test/test_workbench_presenter.rb` — 单测

---

### Task 1: MaterialMappingRecord 增加 SKU 字段与持久化

**Files:**
- Modify: `src/mapping.rb`
- Test: `test/test_mapping.rb`

- [ ] **Step 1: 写失败测试**

在 `test/test_mapping.rb` 的 `class TestMaterialMapping` 内（`test_old_json_without_platform_material_tag_still_loads` 之后、最后 `end` 之前）追加：

```ruby
    def test_platform_sku_roundtrips_json_and_csv
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05, 'wood', 'sku-1', 'SKU-001', '白橡木饰面板 18mm')

      json_file = Tempfile.new(['mapping', '.json'])
      @mapping.save_json(json_file.path)
      from_json = MaterialMapping.new
      from_json.load_json(json_file.path)
      assert_equal 'sku-1', from_json.get('a').platform_sku_id
      assert_equal 'SKU-001', from_json.get('a').platform_sku_code
      assert_equal '白橡木饰面板 18mm', from_json.get('a').platform_sku_name

      csv_file = Tempfile.new(['mapping', '.csv'])
      @mapping.export_csv(csv_file.path)
      from_csv = MaterialMapping.new
      from_csv.import_csv(csv_file.path)
      assert_equal 'SKU-001', from_csv.get('a').platform_sku_code
      assert_equal '白橡木饰面板 18mm', from_csv.get('a').platform_sku_name
    end

    def test_platform_sku_empty_string_normalizes_to_nil
      @mapping.add('a', 'A', 'cat', 'm²', '', 0.05, 'wood', '', '  ', nil)
      assert_nil @mapping.get('a').platform_sku_id
      assert_nil @mapping.get('a').platform_sku_code
      assert_nil @mapping.get('a').platform_sku_name
    end

    def test_old_json_without_sku_still_loads_nil
      file = Tempfile.new(['mapping', '.json'])
      file.write(JSON.generate('a' => {
        material_name: 'A', category: 'cat', unit: 'm²', spec: '',
        default_waste_rate: 0.05, platform_material_tag: 'wood'
      }))
      file.close
      @mapping.load_json(file.path)
      assert_nil @mapping.get('a').platform_sku_id
      assert_nil @mapping.get('a').platform_sku_code
    end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_mapping.rb`
Expected: FAIL（`platform_sku_id` 等字段不存在 / add 参数过多）

- [ ] **Step 3: 修改 Struct 与 add**

`src/mapping.rb` 第 5-8 行 Struct 改为：

```ruby
  MappingRecord = Struct.new(
    :su_material_name, :material_name, :category,
    :unit, :spec, :default_waste_rate, :platform_material_tag,
    :platform_sku_id, :platform_sku_code, :platform_sku_name, keyword_init: true
  )
```

`add` 方法（第 15-26 行）改为：

```ruby
    def add(su_name, material_name, category, unit = 'm²',
            spec = '', default_waste_rate = 0.05, platform_material_tag = nil,
            platform_sku_id = nil, platform_sku_code = nil, platform_sku_name = nil)
      @records[su_name] = MappingRecord.new(
        su_material_name: su_name,
        material_name: material_name,
        category: category,
        unit: unit,
        spec: spec,
        default_waste_rate: default_waste_rate,
        platform_material_tag: normalize_optional(platform_material_tag),
        platform_sku_id: normalize_optional(platform_sku_id),
        platform_sku_code: normalize_optional(platform_sku_code),
        platform_sku_name: normalize_optional(platform_sku_name)
      )
    end
```

- [ ] **Step 4: 修改 CSV 导出/导入**

`export_csv`（第 44-52 行）改为：

```ruby
    def export_csv(path)
      CSV.open(path, 'w') do |csv|
        csv << %w[su_material_name material_name category unit spec default_waste_rate platform_material_tag platform_sku_id platform_sku_code platform_sku_name]
        @records.each_value do |r|
          csv << [r.su_material_name, r.material_name, r.category,
                  r.unit, r.spec, r.default_waste_rate, r.platform_material_tag,
                  r.platform_sku_id, r.platform_sku_code, r.platform_sku_name]
        end
      end
    end
```

`import_csv`（第 54-66 行）改为：

```ruby
    def import_csv(path)
      CSV.foreach(path, headers: true) do |row|
        add(
          row['su_material_name'],
          row['material_name'],
          row['category'],
          row['unit'] || 'm²',
          row['spec'] || '',
          (row['default_waste_rate'] || '0.05').to_f,
          row['platform_material_tag'],
          row['platform_sku_id'],
          row['platform_sku_code'],
          row['platform_sku_name']
        )
      end
    end
```

- [ ] **Step 5: 修改 JSON 四个方法**

`save_json`（第 68-76 行）与 `save_json_string`（第 97-105 行）的内层 Hash 均改为：

```ruby
        {
          material_name: r.material_name, category: r.category,
          unit: r.unit, spec: r.spec, default_waste_rate: r.default_waste_rate,
          platform_material_tag: r.platform_material_tag,
          platform_sku_id: r.platform_sku_id,
          platform_sku_code: r.platform_sku_code,
          platform_sku_name: r.platform_sku_name
        }
```

`load_json`（第 78-86 行）与 `load_json_string`（第 88-95 行）的 `add(...)` 调用均改为：

```ruby
        add(su_name, h['material_name'], h['category'],
            h['unit'], h['spec'] || '', h['default_waste_rate'].to_f,
            h['platform_material_tag'],
            h['platform_sku_id'], h['platform_sku_code'], h['platform_sku_name'])
```

- [ ] **Step 6: 运行测试确认通过**

Run: `ruby -Itest test/test_mapping.rb`
Expected: PASS（全部）

- [ ] **Step 7: 提交**

```bash
git add src/mapping.rb test/test_mapping.rb
git commit -m "feat(mapping): MaterialMappingRecord 增加 SKU 关联字段（id/code/name）并贯通 JSON/CSV 持久化"
```

---

### Task 2: ApiClient 增加 query 参数支持与 materials 方法

**Files:**
- Modify: `src/api/api_client.rb`
- Test: `test/test_api_client.rb`

- [ ] **Step 1: 写失败测试**

在 `test/test_api_client.rb` 的 `class TestApiClient` 内追加（需 `require 'uri'` 已在 api_client 间接可用；测试文件顶部若无则在测试方法内直接用 `URI.decode_www_form`，Ruby 标准库已加载）：

```ruby
  def test_materials_builds_query_and_parses_items
    transport = Transport.new(FakeResponse.new(
      '200', '{"total":1,"page":2,"page_size":5,"items":[{"sku_id":"s1","code":"SKU-1","name":"白橡木 18mm"}]}'
    ))
    client = SuTakeoff::Api::ApiClient.new(base_url: 'https://api.example.com', transport: transport)

    result = client.materials(access_token: 'tok', keyword: '橡木', page: 2, page_size: 5)

    assert_equal 1, result['total']
    assert_equal 'SKU-1', result['items'].first['code']
    call = transport.calls.first
    assert_equal '/api/v1/su/materials', call[:uri].path
    assert_equal 'Bearer tok', call[:request]['Authorization']
    query = URI.decode_www_form(call[:uri].query).to_h
    assert_equal '橡木', query['keyword']
    assert_equal '2', query['page']
    assert_equal '5', query['page_size']
    assert_equal 'active', query['status']
    refute query.key?('category_id'), 'nil 参数不应出现在 query'
  end

  def test_materials_error_becomes_api_error
    transport = Transport.new(FakeResponse.new(
      '403', '{"detail":{"code":"MODULE_DISABLED","message":"租户未启用供应链模块"}}'
    ))
    client = SuTakeoff::Api::ApiClient.new(base_url: 'https://api.example.com', transport: transport)

    err = assert_raises(SuTakeoff::Api::ApiError) { client.materials(access_token: 'tok') }
    assert_equal 'MODULE_DISABLED', err.code
  end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_api_client.rb`
Expected: FAIL（`materials` 未定义）

- [ ] **Step 3: 增加 MATERIALS_PATH 常量与 materials 方法**

`src/api/api_client.rb` 在 `QUANTITIES_PATH = '/api/v1/su/quantities'`（第 18 行）之后加：

```ruby
      MATERIALS_PATH = '/api/v1/su/materials'
```

在 `push_quantities` 方法（第 61-63 行）之后加：

```ruby
      def materials(access_token:, keyword: nil, category_id: nil, brand_id: nil,
                    status: 'active', page: 1, page_size: 20)
        params = {
          'keyword' => keyword,
          'category_id' => category_id,
          'brand_id' => brand_id,
          'status' => status,
          'page' => page,
          'page_size' => page_size
        }
        get(MATERIALS_PATH, access_token: access_token, params: params)
      end
```

- [ ] **Step 4: 给 get / request / build_uri 增加 params 支持**

`get`（第 65-67 行）改为：

```ruby
      def get(path, access_token: nil, params: nil, read_timeout: @read_timeout)
        request('GET', path, access_token: access_token, params: params, read_timeout: read_timeout)
      end
```

`request`（第 73 行起）签名与首行改为：

```ruby
      def request(method, path, body: nil, access_token: nil, params: nil, read_timeout: @read_timeout)
        uri = build_uri(path, params)
```

（`request` 方法体其余部分不变。）

`build_uri`（第 120-125 行）改为：

```ruby
      def build_uri(path, params = nil)
        clean_path = path.to_s.start_with?('/') ? path.to_s : "/#{path}"
        uri = @base_uri.dup
        uri.path = "#{@base_uri.path}#{clean_path}"
        uri.query = URI.encode_www_form(params.reject { |_, v| v.nil? }) if params && !params.empty?
        uri
      end
```

（`post` 不需要 params，保持不变；`me`/`logout` 等经 get/post 调用，params 默认 nil，行为不变。）

- [ ] **Step 5: 运行测试确认通过**

Run: `ruby -Itest test/test_api_client.rb`
Expected: PASS（含既有测试不被破坏）

- [ ] **Step 6: 提交**

```bash
git add src/api/api_client.rb test/test_api_client.rb
git commit -m "feat(api): ApiClient 增加 query 参数支持与 materials 产品/SKU 查询方法"
```

---

### Task 3: WorkbenchPresenter 将 SKU 附到 geometry_usage

**Files:**
- Modify: `src/workbench_presenter.rb`
- Test: `test/test_workbench_presenter.rb`（新建）

- [ ] **Step 1: 写失败测试（新建文件）**

创建 `test/test_workbench_presenter.rb`：

```ruby
require_relative 'test_helper'
require 'src/mapping'
require 'src/component_mapping'
require 'src/takeoff_policy'
require 'src/calculator'
require 'src/workbench_presenter'

module SuTakeoff
  class TestWorkbenchPresenterSku < Minitest::Test
    def build_usages(mapping)
      items = [ScanItem.face(face_id: 1, su_material: 'paint', area: 10.0,
                             normal: [0, 0, 1], width: 2, height: 5,
                             layer_name: '墙面', component_path: ['客厅'],
                             component_path_ids: [10])]
      policy = TakeoffPolicy.new(mapping: mapping)
      WorkbenchPresenter.new(
        items: items, openings: [],
        hierarchy: { name: '(root)', entity_id: 0, kind: 'root',
                     definition_name: nil, depth: 0, hidden: false, children: [] },
        colors: {}, mapping: mapping, component_mapping: ComponentMapping.new,
        policy: policy, ignored: [], tag_defs: {}
      ).build[:geometry_usages]
    end

    def test_usage_carries_sku_when_mapping_has_sku
      mapping = MaterialMapping.new
      mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint',
                  'sku-1', 'SKU-001', '白橡木饰面板 18mm')
      usage = build_usages(mapping).find { |u| u[:su_material] == 'paint' }
      assert_equal 'SKU-001', usage[:sku_code]
      assert_equal '白橡木饰面板 18mm', usage[:sku_name]
    end

    def test_usage_sku_nil_when_mapping_without_sku
      mapping = MaterialMapping.new
      mapping.add('paint', '乳胶漆', '涂料', 'm²', '', 0.0, 'paint')
      usage = build_usages(mapping).find { |u| u[:su_material] == 'paint' }
      assert_nil usage[:sku_code]
      assert_nil usage[:sku_name]
    end
  end
end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `ruby -Itest test/test_workbench_presenter.rb`
Expected: FAIL（usage 无 `sku_code` 键 → nil ≠ 'SKU-001'）

- [ ] **Step 3: 在 usage Hash 中附加 SKU**

`src/workbench_presenter.rb`，在构建 usage Hash 处（约第 200-204 行，`faces_detail` 的 `}` 之后、返回 Hash 的 `{` 之前）插入一行定义 record，并在 Hash 的 `su_material: su_mat,` 之后加两个键。

将：

```ruby
      {
        entity_id: eid,
        su_material: su_mat,
        unit: primary_unit,
```

改为：

```ruby
      record = @mapping && @mapping.get(su_mat)

      {
        entity_id: eid,
        su_material: su_mat,
        sku_code: record && record.platform_sku_code,
        sku_name: record && record.platform_sku_name,
        unit: primary_unit,
```

- [ ] **Step 4: 运行测试确认通过**

Run: `ruby -Itest test/test_workbench_presenter.rb`
Expected: PASS

- [ ] **Step 5: 跑全量确认无回归**

Run: `ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`
Expected: 0 failures, 0 errors

- [ ] **Step 6: 提交**

```bash
git add src/workbench_presenter.rb test/test_workbench_presenter.rb
git commit -m "feat(presenter): geometry_usage 附带关联 SKU（sku_code/sku_name）供前端展示"
```

---

### Task 4: dialog.rb 传 SKU 保存 + search_skus 回调

**Files:**
- Modify: `src/ui/dialog.rb`

> 本任务依赖 SketchUp 运行时，无自动化测试（CLAUDE.md：Dialog 需手动验证）。改完后在 Task 7 手动联调。

- [ ] **Step 1: 注册 search_skus 回调**

`src/ui/dialog.rb`，在 `get_mappings` 回调（第 54 行）附近追加一行：

```ruby
      @dialog.add_action_callback('search_skus') { |_ctx, json| require_login! && search_skus(json) }
```

- [ ] **Step 2: save_mapping 传递 SKU 字段**

`save_mapping`（第 421-431 行）的 `m.add(...)` 调用改为：

```ruby
      m.add(data['su_name'], data['material_name'], data['category'],
            data['unit'], data['spec'], (data['waste_rate'] || 0.0).to_f,
            data['platform_material_tag'],
            data['platform_sku_id'], data['platform_sku_code'], data['platform_sku_name'])
```

- [ ] **Step 3: 新增 search_skus 方法**

在 `cloud_logout`（约第 690 行）之后追加：

```ruby
    def search_skus(json)
      data = JSON.parse(json)
      keyword = data['keyword'].to_s
      req_id = data['req_id']
      ensure_cloud_ui_pump
      Thread.new do
        begin
          result = auth_session.with_access_token_retry do |token|
            api_client.materials(
              access_token: token,
              keyword: keyword.empty? ? nil : keyword,
              page_size: 20
            )
          end
          items = result.is_a?(Hash) ? Array(result['items']) : []
          total = result.is_a?(Hash) ? (result['total'] || items.size) : items.size
          payload = JSON.generate({ req_id: req_id, total: total, items: items })
          run_on_ui_thread do
            @dialog.execute_script("window.receiveSkuResults(#{payload})") rescue nil
          end
        rescue => e
          err = JSON.generate({ req_id: req_id, error: login_error_message(e) })
          run_on_ui_thread do
            @dialog.execute_script("window.receiveSkuResults(#{err})") rescue nil
          end
        end
      end
    end
```

（复用既有 `auth_session` / `api_client` / `ensure_cloud_ui_pump` / `run_on_ui_thread` / `login_error_message`。）

- [ ] **Step 4: Ruby 语法检查**

Run: `ruby -c src/ui/dialog.rb`
Expected: `Syntax OK`

- [ ] **Step 5: 提交**

```bash
git add src/ui/dialog.rb
git commit -m "feat(dialog): save_mapping 传递 SKU 字段；新增 search_skus 后台回调（复用会话与 UI 队列泵）"
```

---

### Task 5: 前端映射页 SKU 自动补全

**Files:**
- Modify: `src/ui/index.html`
- Modify: `src/ui/js/mapping.js`
- Modify: `src/ui/styles.css`

> 前端无自动化测试，浏览器/SU 内手动验证（Task 7）。

- [ ] **Step 1: index.html 两个模板增加 SKU 单元格**

`src/ui/index.html`，`tmpl-mapping-row`（第 77-87 行）中 `<td><input type="text" class="u-platform-tag"></td>`（第 82 行）之后插入：

```html
    <td class="col-sku">
      <input type="text" class="u-sku" placeholder="搜索SKU" autocomplete="off">
      <div class="sku-dropdown" style="display:none"></div>
    </td>
```

`tmpl-mapping-unmapped-row`（第 89-106 行）中 `<td><input type="text" class="u-platform-tag" placeholder="平台标签"></td>`（第 101 行）之后插入相同三行。

- [ ] **Step 2: mapping.js 两个表头增加「平台SKU」列**

`src/ui/js/mapping.js`，已映射表头字符串（第 85-93 行）中 `'<th style="width:100px">平台标签</th>' +` 之后插入：

```js
        '<th style="width:160px">平台SKU</th>' +
```

未映射表头字符串（第 99-109 行）中 `'<th style="width:100px">平台标签</th>' +` 之后同样插入该行。

- [ ] **Step 3: mapping.js 已映射行回显 SKU 并绑定自动补全**

`renderSimpleMappingTable` 的已映射分支（第 121-139 行），在 `tr.querySelector('.u-unit').value = m.unit || 'm²';`（第 131 行）之后插入：

```js
      tr.dataset.skuId = m.platform_sku_id || '';
      tr.dataset.skuCode = m.platform_sku_code || '';
      tr.dataset.skuName = m.platform_sku_name || '';
      tr.querySelector('.u-sku').value =
        m.platform_sku_code ? (m.platform_sku_code + ' ' + (m.platform_sku_name || '')) : '';
      bindSkuAutocomplete(tr);
```

- [ ] **Step 4: mapping.js 未映射行同样处理**

未映射分支（第 140-188 行），在 `tr.querySelector('.u-unit').value = suggested;`（第 180 行）之后插入：

```js
      tr.dataset.skuId = m.platform_sku_id || '';
      tr.dataset.skuCode = m.platform_sku_code || '';
      tr.dataset.skuName = m.platform_sku_name || '';
      tr.querySelector('.u-sku').value =
        m.platform_sku_code ? (m.platform_sku_code + ' ' + (m.platform_sku_name || '')) : '';
      bindSkuAutocomplete(tr);
```

- [ ] **Step 5: saveMappingRow 携带 SKU 字段**

`saveMappingRow`（第 219-237 行）的 `callSketchUp('save_mapping', JSON.stringify({...}))` 对象中，在 `waste_rate: 0.0` 之前追加三行：

```js
    platform_sku_id: tr.dataset.skuId || '',
    platform_sku_code: tr.dataset.skuCode || '',
    platform_sku_name: tr.dataset.skuName || '',
```

（即在 `spec: ...` 之后、`waste_rate: 0.0` 之前。）

- [ ] **Step 6: 追加自动补全逻辑**

在 `mapping.js` 文件末尾（`openAddMapping` 之后）追加：

```js
// ---------------- SKU 自动补全 ----------------
window._skuReqId = 0;
window._skuActiveRow = null;

(function() {
  var bound = false;
  window._ensureSkuCloser = function() {
    if (bound) return;
    bound = true;
    document.addEventListener('click', function(e) {
      document.querySelectorAll('.sku-dropdown').forEach(function(dd) {
        var tr = dd.closest('tr');
        if (!tr || !tr.contains(e.target)) dd.style.display = 'none';
      });
    });
  };
})();

function bindSkuAutocomplete(tr) {
  var input = tr.querySelector('.u-sku');
  var dd = tr.querySelector('.sku-dropdown');
  if (!input || !dd) return;
  window._ensureSkuCloser();
  var timer = null;
  input.addEventListener('input', function() {
    clearTimeout(timer);
    // 手动编辑即视为撤销已选，需重新从下拉选择才会写回 sku 字段
    tr.dataset.skuId = '';
    tr.dataset.skuCode = '';
    tr.dataset.skuName = '';
    var kw = input.value.trim();
    timer = setTimeout(function() {
      window._skuReqId += 1;
      window._skuActiveRow = tr;
      callSketchUp('search_skus', JSON.stringify({ keyword: kw, req_id: window._skuReqId }));
    }, 300);
  });
  input.addEventListener('focus', function() {
    if (dd.children.length > 0) dd.style.display = '';
  });
}

window.receiveSkuResults = function(data) {
  if (data.req_id !== window._skuReqId) return; // 丢弃过期响应
  var tr = window._skuActiveRow;
  if (!tr) return;
  var dd = tr.querySelector('.sku-dropdown');
  if (!dd) return;
  dd.innerHTML = '';
  if (data.error) {
    dd.appendChild(skuOption('查询失败：' + data.error, null, tr));
    dd.style.display = '';
    return;
  }
  var items = data.items || [];
  if (items.length === 0) {
    dd.appendChild(skuOption('无匹配产品', null, tr));
    dd.style.display = '';
    return;
  }
  items.forEach(function(it) {
    var label = (it.code || '') + ' · ' + (it.name || '');
    if (it.spec) label += ' · ' + it.spec;
    if (it.brand && it.brand.name) label += ' · ' + it.brand.name;
    dd.appendChild(skuOption(label, it, tr));
  });
  var foot = document.createElement('div');
  foot.className = 'sku-opt sku-foot';
  foot.textContent = '共 ' + (data.total || items.length) + ' 条';
  dd.appendChild(foot);
  dd.style.display = '';
};

function skuOption(label, item, tr) {
  var div = document.createElement('div');
  div.className = 'sku-opt';
  div.textContent = label;
  if (item) {
    div.onclick = function() {
      var input = tr.querySelector('.u-sku');
      input.value = (item.code || '') + ' ' + (item.name || '');
      tr.dataset.skuId = item.sku_id || '';
      tr.dataset.skuCode = item.code || '';
      tr.dataset.skuName = item.name || '';
      tr.querySelector('.sku-dropdown').style.display = 'none';
    };
  }
  return div;
}
```

- [ ] **Step 7: styles.css 追加下拉样式**

在 `src/ui/styles.css` 末尾追加：

```css
/* SKU 自动补全 */
.col-sku { position: relative; }
.u-sku { width: 150px; }
.sku-dropdown {
  position: absolute; z-index: 1000; left: 0; right: 0;
  max-height: 240px; overflow-y: auto;
  background: #fff; border: 1px solid #d0d0d8; border-radius: 6px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, .12); margin-top: 2px;
}
.sku-opt { padding: 6px 8px; font-size: 12px; cursor: pointer; white-space: nowrap; }
.sku-opt:hover { background: #eef1ff; }
.sku-foot { color: #6c7086; cursor: default; border-top: 1px solid #eee; }
.sku-foot:hover { background: transparent; }
```

- [ ] **Step 8: 提交**

```bash
git add src/ui/index.html src/ui/js/mapping.js src/ui/styles.css
git commit -m "feat(ui): 映射页平台 SKU 行内自动补全（搜索/选择/回显/撤销）"
```

---

### Task 6: 模型视图「产品信息」列展示 SKU

**Files:**
- Modify: `src/ui/js/model_view.js`

> 设计决策：SKU 为材质级信息，仅在**材料汇总行**（每个组件下每种材质一行）展示一次，规格组行/面明细行/组件节点行不重复展示，避免冗余。

- [ ] **Step 1: 材料汇总行 tdInfo 填 SKU**

`src/ui/js/model_view.js`，材料汇总行的产品信息列（约第 619-621 行）：

```js
  // 产品信息（空白列）
  var tdInfo = document.createElement('td');
  row.appendChild(tdInfo);
```

改为：

```js
  // 产品信息（材料汇总行展示关联 SKU：编码 + 名称）
  var tdInfo = document.createElement('td');
  if (usage.sku_code) {
    tdInfo.textContent = usage.sku_code + ' ' + (usage.sku_name || '');
    tdInfo.title = tdInfo.textContent;
  }
  row.appendChild(tdInfo);
```

（此处 `usage` 在作用域内——同一函数上方第 609 行已使用 `usage.su_material`。其余 4 处 `tdInfo`（规格组行 ~430、面明细行 ~500、组件节点行 ~846/~1046）保持空白，刻意不填。）

- [ ] **Step 2: 浏览器/SU 内目视确认（可在 Task 7 一并做）**

确认已关联材质的材料汇总行显示「编码 名称」，未关联为空，组件节点行不显示。

- [ ] **Step 3: 提交**

```bash
git add src/ui/js/model_view.js
git commit -m "feat(ui): 模型视图产品信息列在材料汇总行展示关联 SKU"
```

---

### Task 7: 打包、文档与手动联调验收

**Files:**
- Modify: `docs/用户手册.md`
- Modify: `CLAUDE.md`（可选补充）

- [ ] **Step 1: 打包 RBZ 并检查内容**

Run: `ruby tools/pack_rbz.rb`
Expected: 生成新版 rbz；包内含改动后的 `src/mapping.rb`、`src/api/api_client.rb`、`src/workbench_presenter.rb`、`src/ui/dialog.rb`、`src/ui/index.html`、`src/ui/js/mapping.js`、`src/ui/js/model_view.js`、`src/ui/styles.css`。

- [ ] **Step 2: 全量测试再确认**

Run: `ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"`
Expected: 0 failures, 0 errors

- [ ] **Step 3: 手动联调（需 SketchUp + 登录 + 有数据的租户）**

在 SketchUp 加载插件（开发用 `tools/install_dev_loader.rb`），逐项核对验收标准：
1. 映射页「平台SKU」输入关键字 → 下拉列出平台 SKU（编码·名称·规格·品牌）
2. 点选 → 输入框显示「编码 名称」；清空 → 撤销
3. 保存 → 重开映射页仍回显（JSON + 模型字典）
4. 扫描后模型视图「产品信息」列对已关联材质显示「编码 名称」，未关联为空
5. 映射 CSV 导出/导入保留 SKU
6. 未登录时映射页锁定（登录门禁），无法搜索

> 注意：测试租户 `system_default` 材料库为空（`total=0`），仅能验证「无匹配产品」路径；完整选择流程需有数据的租户。

- [ ] **Step 4: 更新用户手册**

`docs/用户手册.md` 材料映射章节增加「平台 SKU 关联」小节：说明在映射页搜索并选择供应链 SKU、保存后在模型视图「产品信息」列展示、需先登录平台账号。

- [ ] **Step 5: （可选）CLAUDE.md 补充**

`CLAUDE.md` 云端同步层说明中补一句：`ApiClient#materials` 查询 `GET /api/v1/su/materials`（SKU/产品），映射记录含 `platform_sku_id/code/name`。

- [ ] **Step 6: 提交文档**

```bash
git add "docs/用户手册.md" CLAUDE.md
git commit -m "docs: 补充平台 SKU 关联的使用说明与模块描述"
```

---

## 验收标准（对应 spec §10）

1. 映射页输入关键字可列出平台 SKU 并点选（需有数据的租户）
2. 保存后刷新仍在（JSON + 模型字典双持久化）
3. 模型视图「产品信息」列对已关联材质显示「编码 名称」，未关联为空
4. CSV 导出/导入保留 SKU 关联
5. 单测全绿
