# SU Takeoff

SketchUp 插件 — 装修用量自动统计工具。扫描 SU 模型面与容器，按组件层级 / 空间 / 部位 / 材料分组，支持**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**四种计量方式，计入损耗率与工艺派生项，输出采购量报表。

## 功能

- **四种计量方式**：面积、长度、体积、件数。由 `TakeoffPolicy` 4 档优先级自动决议（标签 > 图层规则 > 材质映射 > 几何启发式），用户可在材料视图确认或覆盖
- **组合计量**：支持「件数 + 长度」等复合标签，同一组件同时产出个数和米数（如线灯既数灯数又算长度）
- **组件映射**：组件定义名 → 真实材料映射。aggregate 模式整件统计（灯具/开关），expand 模式展开统计面材
- **容器整体量取**：踢脚线/装饰条等按图层或标签整体量取长度/体积，不下钻子面，避免 6 面同材质重复计算
- **空间/部位识别**：按组件名的 `-` 前缀自动提取空间名（如「主卧-涂料」→ 主卧），按面法向量自动划分地面 / 墙面 / 天花
- **门窗洞口扣减**：自动识别透明材质与以「窗 / 门 / window / door」命名的组件，从墙面净面积中扣除
- **薄板去重**：楼板/天花板双面仅保留面向居住者的一面；竖直薄板（踢脚线）背靠背两面去重
- **材料映射**：SU 材质名 → 真实材料（分类、单位、规格、损耗率），支持 JSON 持久化与 CSV 导入/导出
- **工艺匹配**：按分类挂接工艺做法，含派生项公式（瓷砖 → 水泥砂浆 + 黏接剂等）
- **几何启发式**：自动识别窄长垂直面为线材（宽 ≤ 0.2m + 长宽比 > 15），结果以橙色边框标记待用户确认，阈值可在设置页调整
- **同材多算**：同一 SU 材质在不同计量方式下产出独立行（如启发式 length vs 映射 area），互不合并
- **多视图**：按组件（树形）/ 按材料（含规格分组展开）两视图自由切换，映射就地编辑即时重算
- **数据持久化**：映射表、工艺库、配置以 JSON 存储，支持写入 SU 模型属性字典实现规则随模型走


## 项目结构

```
su-takeoff/
├── su_takeoff.rb              # 插件入口，require 所有 src/ 模块
├── src/
│   ├── takeoff_policy.rb      # 算量策略决议器（4 档优先级）
│   ├── data_models.rb         # ScanItem / MaterialUsage / Opening
│   ├── calculator.rb          # 计算引擎（面积/长度/体积/件数 + 损耗 + 派生）
│   ├── scanner.rb             # SU 模型扫描（递归遍历 + 门窗识别 + 容器量取）
│   ├── mapping.rb             # SU材质 → 真实材料映射
│   ├── component_mapping.rb   # 组件定义 → 材料映射（aggregate/expand）
│   ├── process_library.rb     # 工艺库（分类 → 做法 → 派生项）
│   ├── formula.rb             # 派生项公式求值器
│   ├── main.rb                # PluginState 单例 + 菜单/工具栏注册
│   └── ui/
│       ├── dialog.rb          # HtmlDialog 桥接 + Ruby↔JS 回调
│       ├── index.html         # 左侧菜单 + 五页面布局
│       ├── app.js             # 应用入口、导航、扫描触发、摘要条
│       ├── styles.css         # Catppuccin 深色主题
│       └── js/
│           ├── model_view.js  # 按组件（树形）+ 按材料（启发式红行 + 规格分组）
│           ├── mapping.js     # 材料映射管理页
│           ├── comp_mapping.js# 组件映射管理页
│           └── settings.js    # 设置页（标签/图层规则/启发式/工艺/忽略材料）
├── data/
│   ├── config.json            # 标签定义、图层规则、启发式阈值、单位词表
│   ├── default_mapping.json   # 预设 SU材质 → 真实材料
│   ├── default_component_mapping.json # 预设组件定义 → 材料
│   ├── default_processes.json # 预设工艺定义
│   └── ignored_materials.json # 持久化忽略材质列表
├── test/                      # Minitest 单元测试（独立于 SU 运行时）
├── tools/
│   └── create_wall_model.rb   # 测试模型生成脚本
├── docs/
│   ├── 算量优化方案.md         # P1-P4 设计依据
│   └── 用户手册.md             # 用户操作指南
└── test_model.rb              # SU 控制台内测试模型生成器
```

## 安装

将整个 `su-takeoff` 目录复制到 SketchUp 插件目录：

- **macOS**：`~/Library/Application Support/SketchUp 2023/SketchUp/Plugins/`
- **Windows**：`C:\Users\<用户名>\AppData\Roaming\SketchUp\SketchUp 2023\SketchUp\Plugins\`

在插件目录下创建入口文件 `su_takeoff_loader.rb`：

```ruby
require File.join(File.dirname(__FILE__), 'su-takeoff', 'su_takeoff.rb')
```

重启 SketchUp。

## 使用

1. **Plugins → SU Takeoff → 材料统计** 打开主界面（或工具栏按钮）
2. **扫描全部** / **仅选中面** 读取模型数据
3. 五个页面：
   - **按组件**：树形层级视图，组件可展开，显示面积/长度/体积/件数、部位徽标、材料数徽标。支持为组件分配算量标签
   - **按材料**：SU 材质列表，按规格（宽×高 mm）分组展开。启发式判定的行染橙色边框，提供「✓按长度」「改面积」「跳过」确认按钮
   - **材料映射**：管理 SU 材质 → 真实材料映射（分类/单位/规格/损耗率），支持 CSV 导入/导出
   - **组件映射**：管理组件定义 → 材料映射（aggregate 整件统计 / expand 展开统计）
   - **设置**：单位词表、算量标签定义（支持多选组合）、图层规则、启发式开关+阈值、工艺库、忽略材料
4. 摘要条显示总览统计，「待确认 N」可点击跳转

## 测试

```bash
# 全部测试
ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"

# 单独运行
ruby -Itest test/test_takeoff_policy.rb
ruby -Itest test/test_calculator.rb
ruby -Itest test/test_calculator_volume.rb
ruby -Itest test/test_same_material_multi_method.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_formula.rb
```

单测覆盖数据模型、计算器、策略决议、映射表、工艺库、公式求值器，均独立于 SU 运行时。Scanner / Dialog 需在 SketchUp 内手动验证。
