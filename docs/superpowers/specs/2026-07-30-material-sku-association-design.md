# 材质–供应链 SKU 关联 设计文档

- 日期：2026-07-30
- 状态：待实现
- 关联：云端同步（v1.1.0）、材料映射、模型视图「产品信息」列

## 1. 背景与目标

模型视图的「产品信息」列目前是空白占位列（`src/ui/js/model_view.js`，表头第 3 列，4 处单元格均为空 `<td>`，CSV 导出为空串）。供应链平台已提供产品/SKU 查询接口 `GET /api/v1/su/materials`。

**目标**：让用户在材料映射页通过平台 API 搜索并选择供应链 **SKU**，将其与 SU 材质关联；关联结果持久化，并在模型视图「产品信息」列展示「SKU 编码 + 名称」。

## 2. 范围

**v1 包含：**
- `MaterialMapping`（材质级）关联 SKU：`sku_id / code / name`
- 映射页行内自动补全选择器
- 「产品信息」列展示「编码 名称」
- JSON + 模型 AttributeDictionary 双持久化；CSV 导入/导出携带 SKU

**v1 不包含（明确范围外）：**
- `ComponentMapping`（组件级）关联
- 将 SKU 写入推送 payload（契约 face/part 无此字段；服务端按 `material_tag` 做 SKU 匹配）
- 价格 / 报价

## 3. 平台契约（已确认）

```http
GET /api/v1/su/materials
Authorization: Bearer <access_token>
```

查询参数：`keyword`（匹配 SKU 编码/名称、产品名、品牌名）、`category_id`、`brand_id`、`status`（默认 `active`）、`page`（默认 1）、`page_size`（默认 20，最大 100）。

响应：

```json
{
  "total": 1, "page": 1, "page_size": 20,
  "items": [
    {
      "sku_id": "sku-id",
      "code": "SKU-SU-001",
      "name": "白橡木饰面板 18mm",
      "product": { "id": "product-id", "name": "白橡木饰面板", "code": "PROD-SU-001" },
      "brand": { "id": "brand-id", "name": "示例品牌" },
      "category_path": [ { "id": "category-id", "name": "板材" } ],
      "spec": "1220x2440x18mm",
      "unit": "piece",
      "primary_image_url": null,
      "status": "active"
    }
  ]
}
```

实测（生产 `https://gzzyai.com`）：外层信封与分页正确；`keyword`/`page_size` 参数被接受；测试租户 `system_default` 材料库为空（`total=0`）。

## 4. 关键决策

| 决策点 | 选择 | 理由 |
| --- | --- | --- |
| 关联粒度 | **SKU**（非 product） | 精确到规格；接口按 SKU 返回 |
| 选择交互 | **行内自动补全** | 轻量、不打断编辑 |
| 列展示内容 | **编码 + 名称** | 可读且保留稳定编码 |
| SKU 到达列的方式 | **Presenter 服务端解析后附到 usage** | 与现有材质信息解析一致，model_view 自包含 |
| 搜索策略 | **输入防抖实时调接口** | 库规模未知，搜索在服务端 |
| 持久化字段 | `sku_id / code / name`（3 个） | code+name 够展示，sku_id 作稳定引用；spec/unit 暂不存（YAGNI） |

## 5. 数据流（端到端）

```
映射页输入关键字
  → JS 防抖 callSketchUp('search_skus', {keyword, req_id})
  → dialog 回调 require_login! → 后台线程 auth_session.with_access_token_retry
  → ApiClient.materials(GET /api/v1/su/materials?keyword=..)
  → UI 队列泵 execute_script → window.receiveSkuResults(items, req_id)
  → 下拉建议；点选 → 行内隐藏存 sku_id，显示「编码 名称」
  → 保存 save_mapping(含 sku 字段) → MaterialMapping 持久化(JSON+模型字典)
  → send_mappings(回显) + send_workbench_state
       → Presenter 给每个 geometry_usage 附 sku_code/sku_name
       → model_view「产品信息」列渲染「编码 名称」
```

## 6. 组件改动清单

### 6.1 `src/mapping.rb`
- `MaterialMappingRecord` 在 `platform_material_tag` 后增 `:platform_sku_id, :platform_sku_code, :platform_sku_name`
- `add(..., platform_sku_id=nil, platform_sku_code=nil, platform_sku_name=nil)`，经 `normalize_optional`（strip、空→nil）
- `to_h` / `save_json` / `load_json` / `load_model_dict` 同步增删读 3 字段
- `export_csv` 增 3 列表头与值；`import_csv` 解析 3 列

### 6.2 `src/api/api_client.rb`
- `get/post/request` 增 `params:` 可选参数；`build_uri` 在有 params 时 `uri.query = URI.encode_www_form(params.compact)`（path-only 调用不受影响）
- 新增 `materials(access_token:, keyword: nil, category_id: nil, brand_id: nil, status: 'active', page: 1, page_size: 20)`，`GET /api/v1/su/materials`，返回解析后的 Hash（`{total,page,page_size,items}`）；错误经现有 `request` 机制统一转 `ApiError`

### 6.3 `src/ui/dialog.rb`
- 新回调 `search_skus`：`require_login!` 守卫；后台 `Thread.new`（避免冻结 SU UI，沿用登录/推送模式）→ `auth_session.with_access_token_retry { |t| api_client.materials(access_token: t, keyword: kw, page_size: 20) }` → 经 UI 队列泵 `execute_script("window.receiveSkuResults(...)")`；Dialog 销毁后安全跳过
- `save_mapping`：`m.add(..., data['platform_sku_id'], data['platform_sku_code'], data['platform_sku_name'])`

### 6.4 `src/ui/js/mapping.js`
- 映射行（已映射/未映射模板）增「平台SKU」单元格：输入框 + 下拉建议层
- 输入 debounce ~300ms → `callSketchUp('search_skus', JSON.stringify({keyword, req_id}))`
- `window.receiveSkuResults(items, req_id)`：req_id 匹配当前才渲染；每行显示 `编码 · 名称 · 规格 · 品牌/分类`，底部「共 N 条」；`total=0` 显示「无匹配产品」
- 点选 → 输入框显示「编码 名称」，行内隐藏态存 `sku_id/code/name`；清空输入 = 撤销关联
- `saveMappingRow` 携带 sku 三字段；失焦仅收起下拉（提交仍走「保存」按钮，与现有交互一致）

### 6.5 `src/workbench_presenter.rb`
- `build_geometry_usages`：每个 usage 据 `su_material` 查 `@mapping.get(su_mat)`，存在则附 `sku_code` / `sku_name`

### 6.6 `src/ui/js/model_view.js`
- 4 处「产品信息（空白列）」的 `tdInfo`：在**有明确单一 su_material 的行**填「`sku_code sku_name`」；跨材质汇总行留空
- CSV 导出（表头 line ~1210、数据行 ~1246）该列同步填值

## 7. 持久化

配置优先级（CLAUDE.md）：模型 AttributeDictionary > data JSON > 默认。SKU 三字段随 `to_h`/`load` 同时落到：
- `save_json(mapping_path)`（data JSON）
- `save_mapping_to_model_dict`（模型 AttributeDictionary，随 SKP 走）

## 8. 错误处理 / 边界

- 映射页在登录门禁之后，触发搜索时必已登录；token 过期由 `with_access_token_retry` 自动 refresh 重试一次，失败提示「登录已过期，请重新登录」
- 网络/超时 → `ApiError`（retryable）→ 中文化「查询失败，请重试」；403（模块未启用/无权限）→「请联系管理员」
- 关键字特殊字符由 `URI.encode_www_form` 编码；快速连续输入由 debounce + req_id 防旧结果覆盖新结果
- 关联后平台侧改码/删除：本地显示离线快照，不自动校验（v1）
- HtmlDialog 销毁后回调安全跳过（沿用现有检查）

## 9. 测试

无 SU / 无网络（`transport:` mock、注入式构造）：
- `test_api_client.rb`：`materials` query 拼装（keyword/page/page_size/status、中文编码）、mock 解析、错误转 `ApiError`、params 支持不影响既有接口
- `test_mapping.rb`：`add/to_h/load` 往返保留 sku 三字段；CSV 导出/导入含 sku 列；空串归一为 nil
- Presenter：mapping 有 sku 时 usage 附 `sku_code/name`，无则 nil

手动验证（依赖 SU / 浏览器 / 有数据租户）：搜索回调、autocomplete、列展示。

## 10. 验收标准

1. 映射页输入关键字可列出平台 SKU 并点选（需有数据的租户）
2. 保存后刷新仍在（JSON + 模型字典双持久化）
3. 模型视图「产品信息」列对已关联材质显示「编码 名称」，未关联为空
4. CSV 导出/导入保留 SKU 关联
5. 单测全绿

## 11. 风险与待确认

- **测试租户材料库为空**（`system_default` `total=0`）：完整选择流程需有数据的租户才能线上验证；空库下仅能验证空结果路径。
- `search_skus` 是否需要独立权限（如 supply 模块开关）：契约未明示，按「登录 + Bearer token 即可查询」实现，403 时提示联系管理员。
- SKU 字段长度：本地存储/展示无服务端约束；前端以 CSS 截断 + title 全文。
