# SU Takeoff

SketchUp 插件 — 装修面材用量自动统计工具。基于 SU 模型精准计算地面、墙面、天花的净用量，输出按空间、按部位、按材料的分项报表，为装修报价提供量化依据。

## MVP 功能

- **空间感知**：自动识别 SU 中的房间组/组件，按空间分组统计
- **部位识别**：按面法向量自动划分地面 / 墙面 / 天花（阈值 cos 30°）
- **门窗扣减**：自动识别透明材质与以 "窗 / 门 / window / door" 命名的组件，从墙面净面积中扣除
- **材料映射**：将 SU 原生材料映射到工程用料（含单位、损耗率）
- **工艺匹配**：按材料类别挂接工艺做法（单面刷漆、双面刷漆等）
- **人工标注**：可对未赋材质或需覆盖映射的面进行手工标记
- **三视图切换**：
  - 汇总视图：按材料汇总总用量
  - 明细视图：按空间 × 部位 × 材料分行展示
  - 异常视图：未映射材料、未覆盖面等待处理项
- **损耗率配置**：按材料单独设置或批量设置
- **数据持久化**：映射表与工艺库以 JSON 存储于 `data/`

## 项目结构

```
su-takeoff/
├── su_takeoff.rb              # 插件入口，加载所有模块
├── src/
│   ├── main.rb                # PluginState 单例 + 菜单 / 工具栏注册
│   ├── data_models.rb         # ScanItem / MaterialUsage / Opening
│   ├── mapping.rb             # MaterialMapping 材料映射表
│   ├── process_library.rb     # ProcessLibrary 工艺库
│   ├── calculator.rb          # 面积计算 / 损耗换算 / 部位判定
│   ├── scanner.rb             # SU 模型扫描与门窗识别
│   ├── marker.rb              # 人工标注读写
│   └── ui/
│       ├── dialog.rb          # WebDialog 与 Ruby↔JS 桥
│       ├── index.html         # 三 Tab 布局
│       ├── styles.css         # Catppuccin 深色主题
│       └── app.js             # 前端交互
├── data/
│   ├── default_mapping.json   # 默认材料映射
│   └── default_processes.json # 默认工艺库
├── test/                      # Minitest 单元测试
└── docs/superpowers/          # 方案与实施计划
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
2. 点击 **扫描模型** 读取当前模型
3. 在 **材料映射** 标签页维护映射关系与损耗率
4. 在 **统计** 标签页切换汇总 / 明细 / 异常视图
5. 如需对未赋材质的面手动指派材料，使用 **人工标注**：选中面后打开标注弹窗，选择材料与部位

## 测试

```bash
ruby -Itest test/test_data_models.rb
ruby -Itest test/test_mapping.rb
ruby -Itest test/test_process_library.rb
ruby -Itest test/test_calculator.rb
```

四组共 29 条单测覆盖数据模型、映射表、工艺库、计算器，均独立于 SU 运行时。Scanner / Marker / Dialog 需在 SketchUp 内手动验证。

## 路线图

下一版本候选项：

- 踢脚线长度统计
- 阴阳角计数
- 辅材联动（面材 → 底材 / 胶 / 嵌条）
- 按公司模版导出 Excel / CSV
- 报表模板自定义
