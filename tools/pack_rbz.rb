#!/usr/bin/env ruby
# tools/pack_rbz.rb — 打包 .rbz 安装包
# 用法: ruby tools/pack_rbz.rb

require 'fileutils'
require 'json'
require 'uri'

PROJECT_DIR = File.dirname(__dir__)
VERSION = File.read(File.join(PROJECT_DIR, 'VERSION'), encoding: 'UTF-8').strip
raise "VERSION 格式无效: #{VERSION.inspect}" unless VERSION.match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/)

PACKAGE_NAME = "su-takeoff-v#{VERSION}"

def write_release_api_config(target)
  source_path = File.join(PROJECT_DIR, 'data', 'api_config.json')
  source = JSON.parse(File.read(source_path, encoding: 'UTF-8'))
  environment = source['environment'].to_s.strip
  base_url = source['base_url'].to_s.strip
  uri = URI.parse(base_url)

  unless environment == 'production' && uri.scheme == 'https' && uri.host
    raise "试用包只允许使用生产 HTTPS API，当前配置: environment=#{environment.inspect}, base_url=#{base_url.inspect}"
  end

  release_config = {
    'environment' => 'production',
    'base_url' => base_url
  }
  File.write(
    File.join(target, 'api_config.json'),
    "#{JSON.pretty_generate(release_config)}\n"
  )
end

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
  FileUtils.cp(File.join(PROJECT_DIR, 'VERSION'), File.join(target, 'VERSION'))
  puts "  + su-takeoff/VERSION"
  FileUtils.cp(File.join(PROJECT_DIR, 'su_takeoff.rb'), File.join(target, 'su_takeoff.rb'))
  puts "  + su-takeoff/su_takeoff.rb"

  # 3. src/ 和发布数据白名单
  FileUtils.cp_r(File.join(PROJECT_DIR, 'src'), File.join(target, 'src'))
  puts "  + su-takeoff/src/"

  data_target = File.join(target, 'data')
  FileUtils.mkdir_p(data_target)
  write_release_api_config(data_target)
  puts "  + su-takeoff/data/api_config.json (production)"
  FileUtils.cp(File.join(PROJECT_DIR, 'data', 'strategies.json'), File.join(data_target, 'strategies.json'))
  puts "  + su-takeoff/data/strategies.json"

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
