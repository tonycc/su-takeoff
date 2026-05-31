#!/usr/bin/env ruby
# tools/pack_rbz.rb — 打包 .rbz 安装包
# 用法: ruby tools/pack_rbz.rb

require 'fileutils'

PROJECT_DIR = File.dirname(__dir__)
PACKAGE_NAME = "su-takeoff-v1.0.0"

def build_rbz
  tmp = File.join(PROJECT_DIR, 'tmp', 'rbz')
  FileUtils.rm_rf(tmp)
  FileUtils.mkdir_p(tmp)

  puts "收集文件..."

  # 1. loader 放在根级别
  FileUtils.cp(File.join(PROJECT_DIR, 'su_takeoff_loader.rb'), File.join(tmp, 'su_takeoff_loader.rb'))
  puts "  + su_takeoff_loader.rb"

  # 2. 插件主体放入 su-takeoff/ 子目录
  target = File.join(tmp, 'su-takeoff')
  FileUtils.mkdir_p(target)
  FileUtils.cp(File.join(PROJECT_DIR, 'su_takeoff.rb'), File.join(target, 'su_takeoff.rb'))
  puts "  + su-takeoff/su_takeoff.rb"

  # 3. src/ 和 data/
  FileUtils.cp_r(File.join(PROJECT_DIR, 'src'), File.join(target, 'src'))
  puts "  + su-takeoff/src/"
  FileUtils.cp_r(File.join(PROJECT_DIR, 'data'), File.join(target, 'data'))
  puts "  + su-takeoff/data/"

  # 4. 用系统 zip 打包
  rbz_path = File.join(PROJECT_DIR, "#{PACKAGE_NAME}.rbz")
  FileUtils.rm_f(rbz_path)

  Dir.chdir(tmp) do
    system('zip', '-r', rbz_path, '.', exception: true)
  end

  puts "打包完成: #{PACKAGE_NAME}.rbz"
  puts "大小: #{(File.size(rbz_path) / 1024.0).round(1)} KB"

  FileUtils.rm_rf(tmp)
end

build_rbz
