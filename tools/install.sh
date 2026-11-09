#!/usr/bin/env bash
#
# 一条命令把 App 装到手机：检查签名 → 构建 → 安装 → 启动。
#
# 为什么需要它：这套东西有三个环节会各自失败，报错又都不直白 ——
#   ① 设备没连上 → devicectl 报 CoreDeviceError 4016（其实是"锁屏/不可达"）
#   ② 某张 profile 过期 → xcodebuild 报 "No profiles for ..."（可能只是 watch 那张）
#   ③ Apple ID 凭据丢失 → "No Accounts"（只能去 Xcode GUI 登录）
# 这里把三者分别检查、分别说清，避免对着一条 error 猜。
#
# 用法：
#   ./tools/install.sh                 # 完整构建（含手表）并安装
#   ./tools/install.sh --phone-only    # 只构建手机端（Watch profile 过期时用）
#   ./tools/install.sh --build-only    # 只构建不安装（手机不在身边时用）
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# 默认设备（1的iPhone）。换机器时改这里，或第一个非选项参数传 UDID。
DEFAULT_DEVICE="00008150-000A39EE2687801C"

DEVICE=""
PHONE_ONLY=0
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --phone-only) PHONE_ONLY=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) DEVICE="$arg" ;;
  esac
done
DEVICE="${DEVICE:-$DEFAULT_DEVICE}"

red()  { printf "\033[31m%s\033[0m\n" "$*"; }
grn()  { printf "\033[32m%s\033[0m\n" "$*"; }
ylw()  { printf "\033[33m%s\033[0m\n" "$*"; }
dim()  { printf "\033[2m%s\033[0m\n" "$*"; }

# ── 1. 设备 ────────────────────────────────────────────────────────────

dim "▸ 检查设备 $DEVICE"
# ★ 不要用 `awk '{print $3" "$4}'` 取列（2026-11-07 修）。
#
# `devicectl list devices` 的 Hostname 列经常是**空**的，此时整行少一列，
# $3/$4 就落到 "(UDID) connected" 上 —— 里面不含 available，
# 于是手机明明连着也被判成"不可用"。改成在整行里抓状态词，与列数无关。
DEVLINE=$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" | head -1)
if [ -z "$DEVLINE" ]; then
  red "✗ 找不到这台设备。手机是否插过这台 Mac 并信任过？"
  exit 1
fi
STATE=$(echo "$DEVLINE" | grep -oE 'available \(paired\)|unavailable|available|connected|disconnected|shutdown|booted' | head -1)
STATE="${STATE:-未知}"
case "$STATE" in
  available*|connected) grn "✓ 设备可用（${STATE}）" ;;
  *)
    red "✗ 设备当前不可用（${STATE}）"
    dim "  常见原因：手机锁屏 / 没插 USB / 不在同一 WiFi。"
    dim "  ● 锁屏也会报 CoreDeviceError 4016，先解锁再看。"
    if [ "$BUILD_ONLY" -eq 0 ]; then
      dim "  只想先出包，可以加 --build-only。"
      exit 1
    fi
    ylw "  → 继续构建，不安装。"
    BUILD_ONLY=1
    ;;
esac

# ── 2. 签名 ────────────────────────────────────────────────────────────

dim "▸ 检查描述文件"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WATCH_OK=0        # 有一张 watchkitapp 的 profile，且在有效期内
MAIN_OK=0         # 主 App 的 profile 有效
for f in "$PROFILE_DIR"/*.mobileprovision; do
  [ -e "$f" ] || continue
  name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)
  exp=$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
  case "$name" in
    *gkuiblekey*)
      mark=""
      # 字符串比较对 ISO8601 有效
      if [[ "$exp" < "$NOW" ]]; then mark="  ← 已过期"; fi
      printf "  %-42s %s%s\n" "${name#iOS Team Provisioning Profile: }" "$exp" "$mark"
      case "$name" in
        *watchkitapp*) [ -z "$mark" ] && WATCH_OK=1 ;;
        *widget)       ;;
        *gkuiblekey)   [ -z "$mark" ] && MAIN_OK=1 ;;
      esac
      ;;
  esac
done

# ★ 关键：watchkitapp 的 profile 过期后会被 Xcode **直接删掉**，
#   这时循环里根本看不到它 —— 不能只靠"过期"判断，要按"是否有有效的"判断。
if [ "$MAIN_OK" -eq 0 ]; then
  red "✗ 主 App 的签名已失效，必须先续签："
  dim "  Xcode → Settings → Accounts → 确认 mmxisme@icloud.com（Team 2PQ29MSM39）在线"
  dim "  命令行续不了时会报 No Accounts，那种情况只能回 Xcode GUI。"
  exit 1
fi

if [ "$WATCH_OK" -eq 0 ] && [ "$PHONE_ONLY" -eq 0 ]; then
  ylw "✗ 没有可用的 watchkitapp 描述文件（过期或已被删除）。"
  ylw "  它是 embed 进主 App 的，缺了它整个构建会失败。"
  ylw "  → 自动改用 --phone-only（本次装出来的包不含手表 App）。"
  PHONE_ONLY=1
fi

# ── 3. 构建 ────────────────────────────────────────────────────────────

if [ "$PHONE_ONLY" -eq 1 ]; then
  dim "▸ 构建（仅手机端，临时摘掉 Watch 依赖）"
  cp project.yml /tmp/project.yml.install.bak
  # 用 Python 精确注释那一行，避免 sed 在 YAML 里误伤
  python3 - <<'PY'
import re
p = 'project.yml'
s = open(p).read()
s = s.replace("      - target: GKUIBleKeyWatch\n        embed: true",
              "      # [install.sh --phone-only] 临时移除\n"
              "      # - target: GKUIBleKeyWatch\n      #   embed: true", 1)
open(p, 'w').write(s)
PY
  xcodegen generate >/dev/null 2>&1
  trap 'cp /tmp/project.yml.install.bak project.yml && xcodegen generate >/dev/null 2>&1 && dim "▸ 已恢复 project.yml"' EXIT
else
  dim "▸ 构建（完整，含手表）"
fi

if ! xcodebuild -project GKUIBleKey.xcodeproj -scheme GKUIBleKey \
      -configuration Debug -destination 'generic/platform=iOS' \
      -derivedDataPath DerivedData -allowProvisioningUpdates build \
      2>&1 | grep -E "^\*\* BUILD|error:" ; then
  red "✗ 构建命令异常退出"
  exit 1
fi

APP="DerivedData/Build/Products/Debug-iphoneos/GKUIBleKey.app"
[ -d "$APP" ] || { red "✗ 没找到构建产物 $APP"; exit 1; }

EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
      | plutil -extract ExpirationDate raw - 2>/dev/null || echo "?")
grn "✓ 产物就绪（签名至 ${EXP}）"

# ── 4. 安装 ────────────────────────────────────────────────────────────

if [ "$BUILD_ONLY" -eq 1 ]; then
  ylw "▸ 跳过安装（--build-only）。包在：${APP}"
  dim "  手机连上后执行："
  dim "  xcrun devicectl device install app --device $DEVICE \"$APP\""
  exit 0
fi

dim "▸ 安装"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -3

dim "▸ 启动"
xcrun devicectl device process launch --device "$DEVICE" com.mmxisme.gkuiblekey 2>&1 | tail -1
grn "✓ 完成"
