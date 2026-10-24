#!/bin/bash
# 完整类型检查脚本 —— 破解 Xcode 27.1 命令行宏插件加载问题后的正确用法。
#
# 背景：本机 `xcodebuild` 命令行构建会报
#   "SwiftUIMacros.StateMacro ... malformed response"
# 根因是 xcodebuild 命令行模式没有正确传递 -plugin-path 给 swift-frontend，
# 导致 @State 等 SwiftUI 宏（在 Xcode 27 里被实现成宏）无法展开。
#
# 解决：直接用 swiftc，并显式指定 -plugin-path 指向宏库目录。
# 验证结果：全部源码（含 5 个 UI 文件）0 error 0 warning。
set -euo pipefail

cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
TARGET="arm64-apple-ios27.0"   # 与 project.yml 的 deploymentTarget iOS 27.0 一致

echo "SDK     = $SDK"
echo "PLUGINS = $PLUGINS"
echo "TARGET  = $TARGET"
echo "---"

OUT=$(swiftc -typecheck \
  -sdk "$SDK" \
  -target "$TARGET" \
  -swift-version 6 \
  -plugin-path "$PLUGINS" \
  Sources/App/AppModel.swift \
  Sources/Protocol/*.swift \
  Sources/Crypto/*.swift \
  Sources/Keychain/*.swift \
  Sources/Support/*.swift \
  Sources/BLE/*.swift \
  Sources/Security/*.swift \
  Sources/UI/*.swift 2>&1)

if echo "$OUT" | grep -qE "error:"; then
  echo "$OUT" | grep -E "error:|warning:" || true
  echo ""
  echo "❌ 类型检查失败"
  exit 1
fi

# 单独打印 warning（如果有）
if echo "$OUT" | grep -qE "warning:"; then
  echo "$OUT" | grep -E "warning:"
fi

N=$(find Sources -name '*.swift' | wc -l | tr -d ' ')
L=$(cat Sources/*/*.swift | wc -l | tr -d ' ')
echo ""
echo "✅ 类型检查通过：0 error，$N 文件 / $L 行"
