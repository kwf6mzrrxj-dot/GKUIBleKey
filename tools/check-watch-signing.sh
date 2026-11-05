#!/usr/bin/env bash
# 校验「嵌在手机 App 里的手表 App」是否真的能装到 Apple Watch 上。
#
# 背景（2026-11-04 实测修正）：
#
# 最初以为是「描述文件里缺少 Apple Watch 的 UDID」。这个判断是**错的** ——
# watchOS App 的描述文件本来就该只授权配对的 iPhone，安装时由手机转发给手表。
# 真正的问题在于描述文件的 `Platform` 字段：
#
#   正常 watchOS App  →  Platform = [watchOS]
#   我们这个         →  Platform = [iOS]     ← 平台不对，手表直接拒装
#
# `codesign --verify` 是能通过的（签名本身合法），所以只看签名会误判成「没问题」。
# 而 Platform 为什么是 iOS：**免费 Apple ID（Personal Team）拿不到 watchOS 平台
# 的描述文件**，Xcode 只能退回用同一套 iOS team profile 去签，于是签名成功、
# 平台错误，装到手表上就报「无法验证其完整性」——这句报错完全没提到平台。
#
# 换句话说：这不是隧道问题、不是注册问题、也不是代码问题。
# 免费账号无解，要么换付费账号（¥688/年），要么不做真机手表端。
#
# 用法：
#   ./tools/check-watch-signing.sh [产物 app 路径]
#   默认路径：build/Build/Products/Debug-iphoneos/GKUIBleKey.app

set -uo pipefail

APP="${1:-build/Build/Products/Debug-iphoneos/GKUIBleKey.app}"
WATCH="$APP/Watch/GKUIBleKeyWatch.app"
PHONE_UDID="${PHONE_UDID:-00008150-000A39EE2687801C}"

ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
info() { printf '  ·  %s\n' "$1"; }

echo "═══ 手表 App 安装可行性检查 ═══"

if [ ! -d "$WATCH" ]; then
  bad "找不到手表 App：$WATCH"
  echo "  （先跑一次 xcodebuild -scheme GKUIBleKey -destination 'id=$PHONE_UDID'）"
  exit 1
fi
ok "手表 App 已嵌入"

# ① 签名是否有效 —— 注意：这个通过 ≠ 能装
if codesign --verify --deep --strict "$WATCH" 2>/dev/null; then
  ok "代码签名校验通过（但这只说明签名合法，不说明平台对）"
else
  bad "代码签名无效（codesign --verify 失败）"
fi

PROFILE="$WATCH/embedded.mobileprovision"
if [ ! -f "$PROFILE" ]; then
  bad "缺少 embedded.mobileprovision —— 安装时必然报「无法验证其完整性」"
  exit 1
fi

PLIST=$(security cms -D -i "$PROFILE" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)

# ② 平台字段 —— 这才是「无法验证其完整性」的真正判据
PLATFORMS=$(printf '%s\n' "$PLIST" \
  | awk '/<key>Platform<\/key>/,/<\/array>/' \
  | grep -oE '<string>[^<]+</string>' | sed 's/<[^>]*>//g' | tr '\n' ' ')

echo
echo "  描述文件 Platform：${PLATFORMS:-（读不到）}"

if printf '%s' "$PLATFORMS" | grep -qw "watchOS"; then
  ok "平台包含 watchOS —— 这个包可以装到手表"
else
  bad "平台里没有 watchOS（当前：${PLATFORMS:-空}）"
  cat <<'TIP'

  这是「无法验证其完整性」的真正原因，和隧道、UDID 注册都无关。

  watchOS App 必须由 watchOS 平台的描述文件签名；现在这份是 iOS 的，
  Xcode 用它签出来的包签名合法、平台不对，手表校验时直接拒装。

  为什么会这样：免费 Apple ID（Personal Team）拿不到 watchOS 描述文件，
  Xcode 只能退回同账号的 iOS team profile。免费账号无法解决。

  两条出路：
    1) 升级 Apple Developer Program（个人 ¥688/年）→ 重新构建即正常
    2) 不做真机手表端：把 Watch target 的 embed 关掉（project.yml 第 74 行
       `target: GKUIBleKeyWatch / embed: true`），改用 iPhone 的
       Live Activity（会镜像到手表「智能叠放」）+ 快捷指令覆盖手表场景
TIP
  exit 2
fi

# ③ 授权设备 —— 参考信息
DEVICES=$(printf '%s\n' "$PLIST" \
  | awk '/<key>ProvisionedDevices<\/key>/,/<\/array>/' \
  | grep -oE '<string>[0-9A-Fa-f-]{25,}</string>' | sed 's/<[^>]*>//g')

COUNT=$(printf '%s\n' "$DEVICES" | grep -c . || true)
echo
echo "  授权设备（$COUNT 台）："
printf '%s\n' "$DEVICES" | while read -r d; do
  [ -n "$d" ] || continue
  [ "$d" = "$PHONE_UDID" ] && echo "    - $d  (iPhone)" || echo "    - $d  (Apple Watch)"
done

# ④ 有效期 —— 免费账号只有 7 天，过期要重签
EXP=$(printf '%s\n' "$PLIST" | awk '/<key>ExpirationDate<\/key>/' | head -1 >/dev/null; \
      printf '%s\n' "$PLIST" | grep -A1 '<key>ExpirationDate</key>' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
if [ -n "$EXP" ]; then
  echo
  info "描述文件到期：$EXP"
  DAYS=$(( ( $(date -j -f "%Y-%m-%d" "$EXP" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  if [ "$DAYS" -le 7 ] && [ "$DAYS" -ge 0 ]; then
    warn "只剩 $DAYS 天 —— 这是免费账号的 7 天有效期特征，到期需重新构建安装"
  elif [ "$DAYS" -lt 0 ]; then
    bad "已过期，需要重新构建"
  fi
fi

echo
ok "平台正确，可以尝试安装到手表"
exit 0
