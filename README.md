# SU Takeoff

SketchUp 插件 — 装修用量几何统计工具。扫描 SU 模型面与容器，按组件层级 / 空间 / 部位 / 材料分组，支持**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**四种计量方式，由 `TakeoffPolicy` 4+1 档优先级自动决议；每个量纲背后由独立的 `Strategy` 类承担聚合、单位与命名匹配，新增量纲不再触及多个文件。

## 功能

- **四种计量方式**：面积、长度、体积、件数。由 `TakeoffPolicy` 4+1 档优先级自动决议（标签 > 图层规则 > 材质映射 > 策略自动匹配 > 几何启发式），用户可在材料视图确认或覆盖
- **基于命名约定的策略自动匹配**：内置踢脚线/电线/管材识别规则，可通过 `data/strategies.json` 扩展。组件定义名含关键字（如"电线"/"PVC管"）自动按长度统计，无需逐个打标签
- **3D 虚线渲染建模的电线/管材路径长度计算**：`SegmentedPath` 算法按长度分桶 + 过滤装饰边，解决重复段建模的电线/管道长度统计
- **组合计量**：支持「件数 + 长度」等复合标签，同一组件同时产出个数和米数（如线灯既数灯数又算长度）
- **组件映射**：组件定义名 → 真实材料映射。aggregate 模式整件统计（灯具/开关），expand 模式展开统计面材
- **容器整体量取**：踢脚线/装饰条等按图层、标签或命名匹配整体量取长度/体积，不下钻子面，避免 6 面同材质重复计算
- **空间/部位识别**：按组件名的 `-` 前缀自动提取空间名（如「主卧-涂料」→ 主卧），按面法向量自动划分地面 / 墙面 / 天花
- **门窗洞口扣减**：自动识别透明材质与以「窗 / 门 / window / door」命名的组件，从墙面净面积中扣除
- **薄板去重**：楼板/天花板双面仅保留面向居住者的一面；竖直薄板（散面建模的踢脚线）背靠背两面去重
- **材料映射**：SU 材质名 → 真实材料（分类、单位、规格），支持 JSON 持久化与 CSV 导入/导出
- **几何启发式**：自动识别窄长垂直面为线材（宽 ≤ 0.2m + 长宽比 > 15），结果以橙色边框标记待用户确认，阈值可在设置页调整
- **数据持久化**：映射表、配置以 JSON 存储，支持写入 SU 模型属性字典实现规则随模型走


## 项目结构

```
su-takeoff/
├── su_takeoff.rb              # 插件入口，require 所有 src/ 模块
├── src/
│   ├── data_models.rb         # ScanItem / Opening（keyword_init + 工厂方法）
│   ├── takeoff_policy.rb      # 算量策略决议器（4+1 档优先级）
│   ├── calculator.rb          # 决议引擎（薄板去重 + Policy 决议）
│   ├── workbench_presenter.rb # Scanner 结果 → 前端 JSON 工作台数据
│   ├── scanner.rb             # SU 模型扫描（递归遍历 + 容器决议 + 纯边线路径）
│   ├── mapping.rb             # SU 材质 → 真实材料映射
│   ├── component_mapping.rb   # 组件定义 → 材料映射（aggregate/expand）
│   ├── strategies/            # 算量策略库（9 个内置 + 自定义变体）
│   │   ├── base.rb            # 抽象基类（matches? 自动匹配规则）
│   │   ├── registry.rb        # 实例化 Registry（DI 友好，类方法委托 global）
│   │   ├── face_area.rb       # :area 默认，含洞口扣减
│   │   ├── face_linear.rb     # :length 启发式线材
│   │   ├── instance_count.rb  # :count 组件 aggregate
│   │   ├── solid_volume.rb    # :volume 默认
│   │   ├── solid_linear.rb    # :length 默认
│   │   ├── solid_count.rb     # :count 默认
│   │   ├── skip.rb            # :skip 占位
│   │   ├── skirting_linear.rb # 踢脚线：强制 EdgeBased
│   │   ├── wire_path.rb       # 电线/管材：强制 SegmentedPath
│   │   ├── builtin.rb         # register_all! 集中注册
│   │   └── loader.rb          # data/strategies.json 加载用户变体
│   ├── length_calculators/    # 长度算法库
│   │   ├── base.rb
│   │   ├── baseline.rb        # AttrDict baseline_id 边
│   │   ├── volume_based.rb    # 体积 ÷ 截面
│   │   ├── edge_based.rb      # 各方向最长边累加
│   │   ├── chained.rb         # 串联算法（Baseline → Volume → Edge）
│   │   ├── path_sum.rb        # 纯路径累加（电线折线）
│   │   └── segmented_path.rb  # 按长度分桶（3D 虚线渲染电线）
│   ├── main.rb                # PluginState 单例 + 菜单/工具栏注册
│   └── ui/
│       ├── dialog.rb          # HtmlDialog 桥接 + Ruby↔JS 回调
│       ├── index.html         # 左侧菜单 + 五页面布局
│       ├── app.js             # 应用入口、导航、扫描触发、摘要条
│       ├── styles.css         # Catppuccin 深色主题
│       └── js/
│           ├── model_view.js  # 按组件树形视图
│           ├── mapping.js     # 材料映射管理页
│           ├── comp_mapping.js# 组件映射管理页
│           └── settings.js    # 设置页（标签/分类/启发式/忽略材料）
├── data/
│   ├── config.json            # 标签定义、图层规则、启发式阈值、单位词表
│   ├── default_mapping.json   # 预设 SU 材质 → 真实材料
│   ├── default_component_mapping.json # 预设组件定义 → 材料
│   ├── ignored_materials.json # 持久化忽略材质列表
│   └── strategies.json        # 用户自定义 Strategy 变体（base_strategy + match_rules）
├── test/                      # Minitest 单元测试（独立于 SU 运行时）
├── tools/
│   ├── pack_rbz.rb            # 打包 RBZ 安装包
│   └── create_wall_model.rb   # 测试模型生成脚本
├── docs/
│   ├── 算量优化方案.md         # 量纲三态设计依据 + 实施情况
│   ├── 策略模式架构优化方案.md # Strategy 重构设计文档
│   ├── 架构优化路线图.md
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
3. 四个页面：
   - **按组件**：树形层级视图，组件可展开，显示面积/长度/体积/件数、部位徽标、材料数徽标。支持为组件分配算量标签
   - **材料映射**：管理 SU 材质 → 真实材料映射（分类/单位/规格），支持 CSV 导入/导出
   - **组件映射**：管理组件定义 → 材料映射（aggregate 整件统计 / expand 展开统计）
   - **设置**：单位词表、算量标签定义（支持多选组合）、启发式开关+阈值、忽略材料
4. 摘要条显示总览统计

## 测试

```bash
# 全部测试
ruby -Itest -e "Dir.glob('test/test_*.rb').each { |f| require f.sub('test/', '') }"

# 单独运行
ruby -Itest test/test_takeoff_policy.rb
ruby -Itest test/test_strategy_matching.rb
ruby -Itest test/test_length_calculator_chained.rb
ruby -Itest test/test_compute_geometry_only.rb
ruby -Itest test/test_wall_model.rb
```

单测覆盖数据模型、计算器、策略决议、Strategy 自动匹配、长度算法库、映射表，均独立于 SU 运行时。Scanner / Dialog 需在 SketchUp 内手动验证。`test_helper.rb` 自动注册内置策略 + 加载 `data/strategies.json`，单测无需手动 setup。
