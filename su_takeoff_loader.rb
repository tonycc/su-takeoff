# su_takeoff_loader.rb — SketchUp 自动加载的入口
# 放在 Plugins 目录根级别，由 Extension Manager 安装后加载

plugin_dir = File.join(File.dirname(__FILE__), 'su-takeoff')
plugin_version = File.read(File.join(plugin_dir, 'VERSION'), encoding: 'UTF-8').strip

ext = SketchupExtension.new('SU Takeoff', File.join(plugin_dir, 'su_takeoff.rb'))
ext.version = plugin_version
ext.creator = 'Max'
ext.description = '装修用量统计 — 扫描模型面/容器，按组件层级/空间/部位/材料分组，计入损耗率，输出采购量报表。'
Sketchup.register_extension(ext, true)
