#!/bin/zsh
# ============================================================
#  一键同步到 GitHub（提交 + 推送）
#
#  用法：
#    ./tools/sync.sh                 # 自动生成提交信息
#    ./tools/sync.sh "修复 xxx"       # 自定义提交信息
#
#  安全：暂存区一旦出现真实密钥文件会**直接中止**，
#        避免 `git add -A` 把车钥匙推上去。
# ============================================================

cd "$(dirname "$0")/.." || exit 1

SECRET="Resources/builtin-keys.txt"

# ---------- 安全检查 1：密钥文件是否被 .gitignore 正确排除 ----------
if ! git check-ignore -q "$SECRET"; then
  echo "❌ .gitignore 没有排除 $SECRET"
  echo "   这会把真实车钥匙推上去。已中止。"
  exit 1
fi

git add -A

# ---------- 安全检查 2：暂存区里有没有密钥文件 ----------
if git diff --cached --name-only | grep -qx "$SECRET"; then
  echo "❌ 暂存区包含 $SECRET，已中止。"
  echo "   请检查 .gitignore 后重试："
  echo "     git reset $SECRET"
  exit 1
fi

# ---------- 没有改动就只推送 ----------
if git diff --cached --quiet; then
  if git status -sb | head -1 | grep -q "ahead"; then
    echo "无新改动，推送已有的本地提交…"
    git push origin main
  else
    echo "✅ 已是最新，无需操作"
  fi
  exit 0
fi

MSG="${1:-同步：$(date '+%Y-%m-%d %H:%M')}"

echo "将要提交："
git diff --cached --stat | tail -1
echo ""
git commit -m "$MSG" || exit 1
git push origin main || exit 1

echo ""
echo "✅ 已同步：$(git log --oneline -1)"
