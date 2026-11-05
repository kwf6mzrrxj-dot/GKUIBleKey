#!/usr/bin/env bash
# 探测 Apple Watch 的调试通道是否可用（一行结论）。
#
# 背景（2026-11-04）：手表装不上，链路报
#   Transport error / kOpenErr (L2CAP open channel failed) / networking error
# 而 devicectl 里手表是 paired 但 Device State = disconnected。
# 说明「配对关系在，通道没建立」——多数是手表不在同一网络，或没开开发者模式。
#
# 用法：./tools/watch-connect.sh [手表 UDID]

set -uo pipefail

UDID="${1:-00008310-001722940287601E}"

echo "═══ Apple Watch 调试通道 ═══"

LINE=$(xcrun devicectl list devices 2>/dev/null | grep -i "$UDID")
if [ -z "$LINE" ]; then
  echo "  ❌ Mac 看不到这块表（未配对 / 不在旁边）"
  exit 2
fi
echo "  设备：$(echo "$LINE" | awk '{$1=$1; print}' | cut -c1-80)"

STATE=$(timeout 40 xcrun devicectl device info details --device "$UDID" 2>&1)
if echo "$STATE" | grep -q "Device State: connected"; then
  echo "  ✅ 通道已连上"
  exit 0
fi

echo "  ❌ 通道未建立"
echo "$STATE" | grep -iE "Device State|Transport Type|Error:" | sed 's/^/     /'
cat <<'TIP'

  三条可试（按成功率排序）：

  1) 走 iPhone 中继（不要求手表连 Wi-Fi）
     Xcode → Window → Devices and Simulators
     → 左侧选中 iPhone → 等下方出现 "Paired Watch"
     → 选中手表（Xcode 会顺带把它的 UDID 注册进团队）

  2) 让手表连上同一个 Wi-Fi
     手表放充电器上 → 设置 → Wi-Fi → 选与 Mac 相同的 SSID
     （Mac 现在是 192.168.0.105/24，有线）
     手表平时只在「充电 + iPhone 不在旁边」时才主动连 Wi-Fi

  3) 路由器关掉「AP 隔离 / 客户端隔离」
     否则有线与无线之间互相不可见，TCP 隧道建不起来
TIP
exit 1
