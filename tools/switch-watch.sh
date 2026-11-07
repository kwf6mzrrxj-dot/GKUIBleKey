#!/bin/bash
# 切换「是否把手表 App 嵌进主 App」。
#
# 为什么需要它：
#   Watch target 的 provisioning profile 只有 7 天（免费账号），过期后 Xcode
#   会把它从本地缓存删掉，而命令行又拿不到账号凭据（No Accounts）——
#   这时**整个主 App 都构建不了**，因为 watch app 是 embed 进去的。
#
#   临时摘掉依赖就能让手机端正常构建，代价是这次装出来的包不含手表 App。
#   手表端本来也已经因为 profile 过期而无法启动，不算新增损失。
#
# 用法：
#   ./tools/switch-watch.sh off    # 摘掉手表依赖（手机端可构建）
#   ./tools/switch-watch.sh on     # 恢复（需要 watch profile 有效）
#   ./tools/switch-watch.sh        # 查看当前状态
#
# 恢复的前提：Xcode → Settings → Accounts 里登录了
#   mmxisme@icloud.com（Team 2PQ29MSM39），并且 session 不是 expired。

set -euo pipefail
cd "$(dirname "$0")/.."

SPEC="project.yml"
MARK="# [NO-WATCH]"

# 依赖块的两种形态（缩进必须精确匹配）
ON_BLOCK="      - target: GKUIBleKeyWatch
        embed: true"
OFF_BLOCK="      # [NO-WATCH] 手表依赖已临时摘除（profile 过期）。恢复：./tools/switch-watch.sh on
      # - target: GKUIBleKeyWatch
      #   embed: true"

state() {
  if grep -q "\[NO-WATCH\]" "$SPEC"; then echo "off"; else echo "on"; fi
}

case "${1:-status}" in
  off)
    if [ "$(state)" = "off" ]; then
      echo "已经是 off（手表依赖已摘除）"
      exit 0
    fi
    cp "$SPEC" "$SPEC.bak"
    python3 - "$SPEC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
on = """      - target: GKUIBleKeyWatch
        embed: true"""
off = """      # [NO-WATCH] 手表依赖已临时摘除（profile 过期）。恢复：./tools/switch-watch.sh on
      # - target: GKUIBleKeyWatch
      #   embed: true"""
if s.count(on) != 1:
    sys.exit(f"找不到唯一的 watch 依赖块（匹配 {s.count(on)} 次）")
open(p, 'w').write(s.replace(on, off, 1))
PY
    xcodegen generate >/dev/null 2>&1
    rm -f "$SPEC.bak"
    echo "✓ 已摘除手表依赖，工程已重新生成。现在 Xcode 可以直接构建手机端。"
    echo "  恢复：./tools/switch-watch.sh on"
    ;;
  on)
    if [ "$(state)" = "on" ]; then
      echo "已经是 on（手表依赖存在）"
      exit 0
    fi
    cp "$SPEC" "$SPEC.bak"
    python3 - "$SPEC" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
off = """      # [NO-WATCH] 手表依赖已临时摘除（profile 过期）。恢复：./tools/switch-watch.sh on
      # - target: GKUIBleKeyWatch
      #   embed: true"""
on = """      - target: GKUIBleKeyWatch
        embed: true"""
if s.count(off) != 1:
    sys.exit(f"找不到唯一的注释块（匹配 {s.count(off)} 次）")
open(p, 'w').write(s.replace(off, on, 1))
PY
    xcodegen generate >/dev/null 2>&1
    rm -f "$SPEC.bak"
    echo "✓ 已恢复手表依赖，工程已重新生成。"
    echo "  ⚠️ 若 watch profile 仍无效，构建会再次失败 —— 那时先修 Xcode 账号。"
    ;;
  status|*)
    if [ "$(state)" = "off" ]; then
      echo "当前：off —— 手表依赖已摘除，Xcode 只能构建手机端"
    else
      echo "当前：on —— 包含手表 App（需要 watch profile 有效）"
    fi
    ;;
esac
