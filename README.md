# SU Takeoff

SketchUp 插件 — 装修用量几何统计工具。扫描 SU 模型面与容器，按组件层级 / 空间 / 部位 / 材料分组，支持**面积（m²）/ 长度（m）/ 体积（m³）/ 件数（个）**四种计量方式，由 `TakeoffPolicy` 3 档优先级自动决议；每个量纲背后由独立的 `Strategy` 类承担聚合与单位，新增量纲不再触及多个文件。

## 功能

- **四种计量方式**：面积、长度、体积、件数。由 `TakeoffPolicy` 3 档优先级自动决议（算量标签 > 图层规则 > 几何启发式），用户可在材料视图确认或覆盖
- **组合计量**：支持「件数 + 长度」等复合标签，同一组件同时产出个数和米数（如线灯既数灯数又算长度）
- **组件映射**：组件定义名 → 真实材料映射。aggregate 模式整件统计（灯具/开关），expand 模式展开统计面材
- **容器整体量取**：踢脚线/装饰条等按图层或标签整体量取长度/体积，不下钻子面，避免 6 面同材质重复计算
- **空间/部位识别**：按组件名的 `-` 前缀自动提取空间名（如「主卧-涂料」→ 主卧），按面法向量自动划分地面 / 墙面 / 天花
- **门窗洞口扣减**：自动识别透明材质与以「窗 / 门 / window / door」命名的组件，从墙面净面积中扣除
- **薄板去重**：楼板/天花板双面仅保留面向居住者的一面；竖直薄板（散面建模的踢脚线）背靠背两面去重
- **材料映射**：SU 材质名 → 真实材料（分类、单位、规格），支持 JSON 持久化与 CSV 导入/导出
- **云端同步**：支持平台账号登录、项目绑定、SU v2 payload 构建、后台推送、失败重试和本地 outbox
- **几何启发式**：自动识别窄长垂直面为线材（宽 ≤ 0.2m + 长宽比 > 15），结果以橙色边框标记待用户确认，阈值可在设置页调整
- **数据持久化**：组件映射与配置以 JSON 存储，支持写入 SU 模型属性字典实现规则随模型走


## 项目结构

```
su-takeoff/
├── su_takeoff.rb              # 插件入口，require 所有 src/ 模块
├── src/
│   ├── data_models.rb         # ScanItem / Opening（keyword_init + 工厂方法）
│   ├── takeoff_policy.rb      # 算量策略决议器（3 档优先级）
│   ├── calculator.rb          # 决议引擎（薄板去重 + Policy 决议）
│   ├── workbench_presenter.rb # Scanner 结果 → 前端 JSON 工作台数据
│   ├── scanner.rb             # SU 模型扫描（递归遍历 + 容器决议 + 纯边线路径）
│   ├── mapping.rb             # SU 材质 → 真实材料映射
│   ├── component_mapping.rb   # 组件定义 → 材料映射（aggregate/expand）
│   ├── api/                   # 平台 API 对接（认证、payload、同步、outbox）
│   │   ├── api_client.rb      # HTTP/JSON 客户端
│   │   ├── auth_session.rb    # 登录、refresh、logout、me 校验
│   │   ├── project_binding.rb # 模型与平台项目绑定
│   │   ├── quantity_payload_builder.rb # SU v2 payload 构建
│   │   ├── quantity_sync_service.rb    # 推送、重试、成功/失败结果
│   │   └── sync_outbox.rb     # 本地失败队列
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
│   │   ├── builtin.rb         # register_all! 集中注册
│   │   └── loader.rb          # data/strategies.json 加载用户变体
│   ├── length_calculators/    # 长度算法库
│   │   ├── base.rb
│   │   ├── baseline.rb        # AttrDict baseline_id 边
│   │   ├── volume_based.rb    # 体积 ÷ 截面
│   │   ├── edge_based.rb      # 各方向最长边累加
│   │   ├── chained.rb         # 串联算法（Baseline → Volume → Edge）
│   │   └── path_sum.rb        # 纯路径累加（电线折线）
│   ├── main.rb                # PluginState 单例 + 菜单/工具栏注册
│   └── ui/
│       ├── dialog.rb          # HtmlDialog 桥接 + Ruby↔JS 回调
│       ├── index.html         # 左侧菜单 + 四页面布局
│       ├── app.js             # 应用入口、导航、扫描触发、摘要条
│       ├── styles.css         # Catppuccin 深色主题
│       └── js/
│           ├── model_view.js  # 按组件树形视图
│           ├── comp_mapping.js# 组件映射管理页
│           ├── cloud_sync.js  # 云端登录、项目绑定和推送页
│           └── settings.js    # 设置页（标签/分类/启发式/阈值）
├── data/
│   ├── config.json            # 标签定义、图层规则、启发式阈值
│   ├── api_config.json        # API 环境和 Base URL（非敏感配置）
│   ├── default_component_mapping.json # 预设组件定义 → 材料
│   └── strategies.json        # 用户自定义 Strategy 变体（base_strategy + match_rules）
├── test/                      # Minitest 单元测试（独立于 SU 运行时）
├── tools/
│   ├── pack_rbz.rb            # 打包 RBZ 安装包
│   ├── install_dev_loader.rb   # 写入开发 loader，SketchUp 直接加载源码
│   └── create_wall_model.rb   # 测试模型生成脚本
├── docs/
│   ├── 算量优化方案.md         # 量纲三态设计依据 + 实施情况
│   ├── 策略模式架构优化方案.md # Strategy 重构设计文档
│   ├── 架构优化路线图.md
│   └── 用户手册.md             # 用户操作指南
└── test_model.rb              # SU 控制台内测试模型生成器
```

## 安装

### 开发调试（推荐）

开发时不要反复打 RBZ。运行下面命令会在 SketchUp 的 Plugins 目录写入一个开发 loader，SketchUp 会直接加载当前源码目录：

```bash
ruby tools/install_dev_loader.rb
```

如需指定 SketchUp 版本：

```bash
ruby tools/install_dev_loader.rb 2023
```

重启 SketchUp 后使用 **Plugins → SU Takeoff Dev → 材料统计** 打开开发版。修改 Ruby 代码后点击 **Plugins → SU Takeoff Dev → 重新加载插件**；修改 HTML / JS / CSS 后关闭插件窗口再重新打开，开发模式会自动刷新前端资源时间戳，避免 HtmlDialog 缓存旧文件。

如果正式安装包仍在 Plugins 目录中，SketchUp 里可能同时出现 `SU Takeoff` 和 `SU Takeoff Dev`。调试时请使用 `SU Takeoff Dev`，或在扩展管理器中禁用正式版。

### 正式安装

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
3. 登录成功后进入功能页面：
   - **登录页**：校验平台账号，未登录时锁定插件功能
   - **按组件**：树形层级视图，组件可展开，显示面积/长度/体积/件数、部位徽标、材料数徽标。支持为组件分配算量标签
   - **材料映射**：管理 SU 材质 → 真实材料映射（分类/单位/规格），支持 CSV 导入/导出
   - **组件映射**：管理组件定义 → 材料映射（aggregate 整件统计 / expand 展开统计）
   - **设置**：组件分类单位、算量标签定义（支持多选组合）、启发式开关+阈值
   - **云端同步**：登录平台账号、绑定项目、推送 SU v2 算量 payload
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

单测覆盖数据模型、计算器、策略决议、长度算法库、组件映射，均独立于 SU 运行时。Scanner / Dialog 需在 SketchUp 内手动验证。`test_helper.rb` 自动注册内置策略 + 加载 `data/strategies.json`，单测无需手动 setup。
