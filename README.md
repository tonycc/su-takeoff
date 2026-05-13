# SU Takeoff

SketchUp 插件 — 装修面材用量自动统计工具。基于 SU 模型精准计算地面、墙面、天花的净用量，按组件层级 / 空间 / 部位 / 材料分组，输出含损耗率的采购量报表，为装修报价提供量化依据。

## 功能

- **组件层级感知**：保留 SU 模型完整的组件嵌套层级，同名实例按 entityID 区分
- **部位识别**：按面法向量自动划分地面 / 墙面 / 天花（阈值 cos 30°）
- **门窗扣减**：自动识别透明材质与以「窗 / 门 / window / door」命名的组件，从墙面净面积中扣除
- **薄板去重**：识别楼板 / 天花板的双面，仅保留面向居住者的那一面
- **材料映射**：将 SU 原生材质映射到工程用料（含分类、单位、规格、损耗率）
- **线材支持**：支持 m² / m / 个 三种计量单位。系统按面长宽比自动建议线性识别（>15 视为线条），用户可在材料视图覆盖
- **工艺匹配**：按材料类别挂接工艺做法，含派生项公式（一面瓷砖派生底层水泥砂浆 + 黏接剂等）
- **人工标注**：对未赋材质或需覆盖映射的面进行手工标记
- **同页多视图**：扫描后在「按组件 / 按材料 / 采购量」三视图间自由切换，映射就地编辑并即时重算
- **CSV 导出**：采购量视图可导出为 CSV（带 BOM 兼容 Excel）
- **数据持久化**：映射表与工艺库以 JSON 存储；可写入 SU 模型属性字典实现规则随模型走

## 项目结构

```
su-takeoff/
├── su_takeoff.rb              # 插件入口，加载所有模块
├── src/
│   ├── main.rb                # PluginState 单例 + 菜单 / 工具栏注册
│   ├── data_models.rb         # ScanItem / MaterialUsage / Opening
│   ├── mapping.rb             # MaterialMapping 材料映射表
│   ├── process_library.rb     # ProcessLibrary 工艺库（含派生项）
│   ├── calculator.rb          # 面积/长度计算、损耗换算、薄板去重、洞口扣减
│   ├── scanner.rb             # SU 模型扫描与门窗识别
│   ├── marker.rb              # 人工标注读写
│   ├── debug.rb               # 调试日志
│   ├── formula.rb             # 派生项公式求值器
│   └── ui/
│       ├── dialog.rb          # HtmlDialog 与 Ruby↔JS 桥
│       ├── index.html         # 三 Tab 布局：统计 / 映射 / 设置
│       ├── styles.css         # Catppuccin 深色主题
│       └── app.js             # 前端工作台与三视图渲染
├── data/
│   ├── default_mapping.json   # 默认材料映射
│   └── default_processes.json # 默认工艺库
├── test/                      # Minitest 单元测试
└── docs/superpowers/          # 设计与实施计划
```

## 安装

将整个 `su-takeoff` 目录复制到 SketchUp 插件目录：

- **macOS**：`~/Library/Application Support/SketchUp 2023/SketchUp/Plugins/`
- **Windows**：`C:\Users\<你>\AppData\Roaming\SketchUp\SketchUp 2023\SketchUp\Plugins\`

并额外放置一个入口文件 `su_takeoff_loader.rb`，内容为：

```ruby
require File.join(File.dirname(__FILE__), 'su-takeoff', 'su_takeoff.rb')
```

重启 SketchUp。

## 使用

1. **Plugins 菜单 → SU Takeoff → 材料统计**（或工具栏按钮）打开主界面
2. 点击 **扫描全部** / **仅选中面** 读取模型
3. 扫描后立即看到摘要条与三视图：
   - **按组件**（默认）：树形表格，组件可层层展开看到所属面，含面积 / 长度 / 部位徽标 / 采购量
   - **按材料**：SU 材质列表，可就地填写真实材料名 / 分类 / 单位 / 规格 / 损耗率，或勾选忽略
   - **采购量**：仅显示已映射材质的汇总，可按材料 / 按空间切换，支持 CSV 导出
4. 摘要条上「待 N」点击直接跳转到材料视图并筛选出待映射
5. 「映射」标签页管理映射库（搜索、删除、导入 / 导出 CSV）
6. 「设置」标签页可将映射规则写入 / 读取 SU 模型属性字典（实现规则随模型走）

## 测试

```bash
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
ruby -Itest test/test_formula.rb
```

单测覆盖数据模型、映射表、工艺库、计算器、公式求值器，均独立于 SU 运行时。Scanner / Marker / Dialog 需在 SketchUp 内手动验证。

## 路线图

下一版本候选项：

- 阴阳角计数
- 辅材联动（面材 → 底材 / 胶 / 嵌条）的工艺派生项扩展
- 按公司模版导出 Excel
- 报表模板自定义
- 多模型对比
