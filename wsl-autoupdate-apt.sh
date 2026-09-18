#!/bin/bash
# ============================================================
#  WSL 自动更新 —— 发行版内软件包升级
#  由 Windows 计划任务 "WSL Auto Update" 调用：
#      wsl.exe -d Ubuntu -u root -- /usr/local/sbin/wsl-autoupdate-apt.sh
#
#  说明：WSL 的 distro 只在被访问时运行，systemd 定时器
#  （apt-daily.timer / unattended-upgrades）只在 distro 存活窗口内
#  才会触发，因此发行版内的自动更新实际长期失效。本脚本由
#  Windows 侧定时唤醒 distro 来补上这个缺口。
#
#  注意：本文件必须保持 LF 行尾且不得带 UTF-8 BOM，否则 shebang
#  失效、脚本无法执行。Windows 侧副本由计划任务用 cp 直接拷贝。
# ============================================================

# 把 stderr 并入 stdout，避免 PowerShell 侧收到 ErrorRecord 后丢失文本
exec 2>&1

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

rc_final=0

echo "### 发行版  : $(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo unknown)"
echo "### 内核    : $(uname -r)"
echo "### 开始时间: $(date -Is)"
echo

echo "### [1/4] apt-get update"
apt-get update -qq
update_rc=$?
echo "### apt-get update 退出码: $update_rc"
if [ "$update_rc" -ne 0 ]; then
    echo "### 警告: 部分软件源刷新失败，后续升级可能不完整"
    rc_final=1
fi

echo
echo "### [2/4] apt-get upgrade"
# --force-confdef / --force-confold: 保留本机已有配置文件，不被新版覆盖
apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Use-Pty=0 \
    upgrade
upgrade_rc=$?
echo "### apt-get upgrade 退出码: $upgrade_rc"
if [ "$upgrade_rc" -ne 0 ]; then
    rc_final=1
fi

echo
echo "### [3/4] dpkg 一致性检查"
if dpkg --audit 2>/dev/null | grep -q .; then
    echo "### dpkg 存在半配置包，需要人工介入:"
    dpkg --audit 2>/dev/null | sed 's/^/###   /'
    rc_final=1
else
    echo "### dpkg 状态: 正常"
fi

echo
echo "### [4/4] 结果汇总"
remaining=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c . || true)
echo "### 仍可升级包数量: $remaining"
if [ "${remaining:-0}" -gt 0 ]; then
    echo "### 清单（通常为 Ubuntu 分阶段发布 phased 中、或来自第三方源的包）:"
    apt list --upgradable 2>/dev/null | tail -n +2 | sed 's/^/###   /'
fi
echo "### 结束时间: $(date -Is)"

if [ "$rc_final" -eq 0 ]; then
    echo "### 结论: 正常完成"
else
    echo "### 结论: 存在失败项 (update=$update_rc, upgrade=$upgrade_rc)，需人工检查"
fi
exit "$rc_final"
