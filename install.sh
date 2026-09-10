#!/usr/bin/env bash
#
# 编译 dsh-ui 并安装到 ~/.local/bin（用 BIN_DIR 可覆盖目标目录）。
#
#   ./install.sh
#   BIN_DIR=/usr/local/bin ./install.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/dsh-ui.swift"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"

if [ ! -f "$src" ]; then
  echo "找不到源文件: $src" >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "需要 Xcode Command Line Tools（提供 swiftc）。安装：xcode-select --install" >&2
  exit 1
fi

mkdir -p "$bin_dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> 编译 dsh-ui.swift …"
swiftc -O "$src" -o "$tmp/dsh-ui"
install -m 0755 "$tmp/dsh-ui" "$bin_dir/dsh-ui"

echo "==> 已安装: $bin_dir/dsh-ui"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "提示: $bin_dir 不在 PATH 里，把它加进 shell 配置" ;;
esac

cat <<'MSG'

还差两步授权（只做一次，授予**运行 agent 的宿主程序**，通常是 Terminal / iTerm）：

  1. 系统设置 → 隐私与安全性 → 辅助功能     勾选该程序（注入事件、读 AX 树）
  2. 系统设置 → 隐私与安全性 → 屏幕录制     勾选该程序（截图）

验证:

  dsh-ui guard      # 拦截名单 / 审计日志 / 干跑状态
  dsh-ui displays   # 屏幕几何 —— 点任何坐标前先读它
MSG
