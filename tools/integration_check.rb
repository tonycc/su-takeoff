#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/integration_check.rb
#
# 阶段 5 联调脚本：走真实的 AuthSession / QuantityPayloadBuilder /
# QuantitySyncService 代码路径，对生产（或指定环境）服务端验证：
#
#   1. 登录（含多租户 TENANT_SELECTION_REQUIRED 处理）
#   2. /identity/me 与 quantity:ingest 权限
#   3. 推送一份合成算量 payload
#   4. 幂等：相同 payload 再推一次，观察服务端去重
#   5. 大 payload：触发 413 / 网关限制，观察错误形态
#   6. 登出
#
# 凭证一律从环境变量读取，绝不写入文件或提交：
#   SU_USER, SU_PASS          必填（测试租户账号）
#   SU_TENANT_ID              可选；多租户账号不填会列出可选租户
#   SU_BASE_URL               默认 https://gzzyai.com
#   SU_ENV                    默认 production（production 强制 HTTPS）
#   SU_PROJECT_CODE/NAME      绑定项目，默认联调测试项目
#   SU_BIG                    大 payload 的组件数量，默认 20000；设 0 跳过
#   SU_DRY_RUN                设 1 时仅离线构建 payload 打印统计，不发请求
#
# 用法：
#   SU_DRY_RUN=1 ruby tools/integration_check.rb           # 离线自检
#   SU_USER=xx SU_PASS=yy ruby tools/integration_check.rb  # 真实联调

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(ROOT)

require 'json'
require 'fileutils'
require 'src/data_models'
require 'src/strategies/base'
require 'src/strategies/registry'
require 'src/strategies/face_area'
require 'src/strategies/face_linear'
require 'src/strategies/instance_count'
require 'src/strategies/solid_volume'
require 'src/strategies/solid_linear'
require 'src/strategies/solid_count'
require 'src/strategies/skip'
require 'src/length_calculators/base'
require 'src/strategies/builtin'
require 'src/strategies/loader'
require 'src/component_mapping'
require 'src/takeoff_policy'
require 'src/calculator'
require 'src/api/api_error'
require 'src/api/http_response'
require 'src/api/api_client'
require 'src/api/credential_store'
require 'src/api/auth_session'
require 'src/api/project_binding'
require 'src/api/quantity_payload_builder'
require 'src/api/sync_outbox'
require 'src/api/quantity_sync_service'

SuTakeoff::Strategies::Builtin.register_all!
SuTakeoff::Strategies::Loader.load_from_file!(File.join(ROOT, 'data', 'strategies.json'))

include SuTakeoff

# ---------------------------------------------------------------- 配置
BASE_URL = ENV['SU_BASE_URL'] || 'https://gzzyai.com'
ENV_NAME = ENV['SU_ENV'] || 'production'
USER = ENV['SU_USER']
PASS = ENV['SU_PASS']
TENANT = ENV['SU_TENANT_ID']
PROJECT_CODE = ENV['SU_PROJECT_CODE'] || 'ITG-TEST-001'
PROJECT_NAME = ENV['SU_PROJECT_NAME'] || '联调测试项目'
BIG = (ENV['SU_BIG'] || 20_000).to_i
DRY_RUN = ENV['SU_DRY_RUN'] == '1'

# ---------------------------------------------------------------- 结果收集
$results = []
def record(name, pass, detail = nil)
  $results << [name, pass, detail]
  status = pass ? 'PASS' : 'FAIL'
  puts format('  [%s] %s%s', status, name, detail ? " — #{detail}" : '')
end

def section(title)
  puts "\n== #{title} =="
end

# ---------------------------------------------------------------- 合成数据
def fake_binding
  Struct.new(:project_code, :project_name, :model_key, keyword_init: true) do
    def ensure_model_key!
      self.model_key ||= 'integration-model-key'
    end
  end.new(project_code: PROJECT_CODE, project_name: PROJECT_NAME,
          model_key: 'f47ac10b-58cc-4372-a567-0e02b2c3d479')
end

def face_item(id)
  ScanItem.face(
    face_id: id, face_persistent_id: 10_000 + id, su_material: 'paint',
    area: 10.0, normal: [0, 0, 1], width: 2.0, height: 5.0,
    layer_name: '墙面', component_path: ["空间#{id}"],
    component_path_ids: [id], component_path_persistent_ids: [100_000 + id]
  )
end

def linear_item(id)
  ScanItem.linear_solid(
    face_id: id, face_persistent_id: 20_000 + id, su_material: 'skirting',
    length: 3.0, layer_name: '线材', component_path: ["空间#{id}"],
    component_path_ids: [id], component_path_persistent_ids: [100_000 + id]
  )
end

# 常规 payload：1 个面积面 + 2 条线材 part
def sample_items
  [face_item(1), linear_item(2), linear_item(3)]
end

def build_payload(items)
  Api::QuantityPayloadBuilder.new(
    items: items, openings: [],
    component_mapping: ComponentMapping.new,
    policy: TakeoffPolicy.new,
    binding: fake_binding
  ).build
end

def payload_json_bytes(payload)
  JSON.generate(payload).bytesize
end

# ---------------------------------------------------------------- 主流程
puts "SU Takeoff 云端同步联调脚本"
puts "Base=#{BASE_URL} env=#{ENV_NAME} dry_run=#{DRY_RUN}"

section '构建 payload（离线）'
build = build_payload(sample_items)
if build.issues.any?
  record('常规 payload 无 issue', false, build.issues.inspect)
else
  record('常规 payload 无 issue', true)
end
puts "    components=#{build.payload[:components].size} " \
     "bytes=#{payload_json_bytes(build.payload)} " \
     "idempotency=#{build.payload[:idempotency_key]}"

if DRY_RUN
  if BIG.positive?
    big_build = build_payload((1..BIG).map { |i| face_item(i) })
    puts "    大 payload components=#{big_build.payload[:components].size} " \
         "bytes=#{payload_json_bytes(big_build.payload)}"
  end
  puts "\nDRY_RUN 模式：跳过所有网络请求。去掉 SU_DRY_RUN=1 并提供 SU_USER/SU_PASS 进行真实联调。"
  exit 0
end

unless USER && PASS
  puts "\n缺少 SU_USER / SU_PASS，无法进行真实联调。"
  exit 2
end

client = Api::ApiClient.new(base_url: BASE_URL, environment: ENV_NAME)
session = Api::AuthSession.new(api_client: client,
                               credential_store: Api::MemoryCredentialStore.new)

section '1. 登录'
begin
  state = session.login(username: USER, password: PASS, tenant_id: TENANT)
  if state[:status] == :tenant_selection_required
    tenants = state[:available_tenants]
    record('多租户登录识别', true, "返回 #{tenants.size} 个租户")
    puts '    可选租户：'
    tenants.each { |t| puts "      - #{t.inspect}" }
    if TENANT
      state = session.login(username: USER, password: PASS, tenant_id: TENANT)
    else
      puts '    未设置 SU_TENANT_ID，请设置后重跑。此处结束。'
      exit 0
    end
  end
  record('登录成功', session.signed_in?, "status=#{state[:status]}")
rescue Api::ApiError => e
  record('登录成功', false, "code=#{e.code} #{e.message}")
  exit 1
end

section '2. /identity/me 与权限'
record('can_push? (quantity:ingest)', session.can_push?,
       "identity keys=#{(session.identity || {}).keys.inspect}")

section '3. 推送常规 payload'
outbox_dir = File.join(ROOT, 'tmp', 'integration_outbox')
FileUtils.mkdir_p(outbox_dir)
outbox = Api::SyncOutbox.new(dir: outbox_dir)
service = Api::QuantitySyncService.new(
  api_client: client, auth_session: session, outbox: outbox,
  binding: fake_binding,
  component_mapping: ComponentMapping.new,
  policy: TakeoffPolicy.new,
  persist_success: false
)

first = service.push_built(build)
record('首次推送成功', first.success?,
       first.success? ? "attempts=#{first.attempts} resp=#{first.response.inspect[0, 160]}" \
                      : "code=#{first.error&.code} #{first.error&.message}")

section '4. 幂等：相同 payload 再推一次'
second = service.push_built(build)
if second.success?
  same_sheet = first.response && second.response &&
               first.response['sheet_id'] == second.response['sheet_id']
  record('二次推送成功（服务端受理相同 idempotency_key）', true,
         "sheet_id 一致=#{same_sheet} resp=#{second.response.inspect[0, 160]}")
else
  record('二次推送成功（服务端受理相同 idempotency_key）', false,
         "code=#{second.error&.code} #{second.error&.message}")
end

section "5. 大 payload（#{BIG} 组件）限制探测"
if BIG.positive?
  big_build = build_payload((1..BIG).map { |i| face_item(i) })
  bytes = payload_json_bytes(big_build.payload)
  puts "    大 payload bytes=#{bytes}"
  big_result = service.push_built(big_build)
  if big_result.success?
    record('大 payload 推送', true, "服务端接受，bytes=#{bytes} resp=#{big_result.response.inspect[0, 120]}")
  else
    e = big_result.error
    record('大 payload 推送（观察限制行为）', true,
           "bytes=#{bytes} status=#{e&.status} code=#{e&.code} retryable=#{e&.retryable} msg=#{e&.message}")
  end
else
  puts '    SU_BIG=0，跳过。'
end

section '6. 登出'
begin
  session.logout
  record('登出', !session.signed_in?, "status=#{session.status}")
rescue StandardError => e
  record('登出', false, e.message)
end

section '汇总'
failed = $results.reject { |_, pass, _| pass }
puts "#{$results.size - failed.size}/#{$results.size} 通过"
exit(failed.empty? ? 0 : 1)
