#!/bin/bash
# ========================================
# PVE 防火墙配置脚本
# 用途：配置 Proxmox VE 防火墙允许特定端口访问
# ========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
    exit 1
fi

# 检查是否是 PVE 系统
if [ ! -d /etc/pve ]; then
    log_error "这不是 Proxmox VE 系统，无需配置 PVE 防火墙"
    exit 1
fi

log_info "=== PVE 防火墙配置工具 ==="
echo ""

# ========================================
# 收集配置信息
# ========================================
log_step "收集配置信息"
echo ""

echo "需要开放的端口（多个端口用空格分隔，如: 8080 8081 8443）:"
read -p "端口列表: " PORTS

if [ -z "$PORTS" ]; then
    log_error "未输入端口"
    exit 1
fi

echo ""
log_info "将开放以下端口："
for port in $PORTS; do
    echo "  - $port"
done
echo ""

read -p "确认配置？(y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    log_warn "用户取消操作"
    exit 0
fi

# ========================================
# 获取主机名
# ========================================
HOSTNAME=$(hostname)
HOST_FW="/etc/pve/nodes/${HOSTNAME}/host.fw"

log_info "当前主机: $HOSTNAME"
log_info "配置文件: $HOST_FW"
echo ""

# ========================================
# 备份现有配置
# ========================================
log_step "备份现有配置"
echo ""

if [ -f "$HOST_FW" ]; then
    BACKUP_FILE="${HOST_FW}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$HOST_FW" "$BACKUP_FILE"
    log_info "✓ 已备份到: $BACKUP_FILE"
else
    log_warn "配置文件不存在，将创建新文件"
fi

# ========================================
# 读取现有配置
# ========================================
log_step "读取现有配置"
echo ""

# 读取现有的 RULES 部分
EXISTING_RULES=""
if [ -f "$HOST_FW" ]; then
    EXISTING_RULES=$(sed -n '/^\[RULES\]/,/^\[/p' "$HOST_FW" | grep -v '^\[' || true)
fi

# ========================================
# 生成新配置
# ========================================
log_step "生成新配置"
echo ""

cat > "$HOST_FW" <<EOF
[OPTIONS]

enable: 1

[RULES]

IN ACCEPT -p icmp
IN SSH(ACCEPT) -source +management
IN ACCEPT -p tcp -dport 8006 -source +management
IN ACCEPT -p tcp -dport 3128 -source +management
EOF

# 添加用户指定的端口
for port in $PORTS; do
    echo "IN ACCEPT -p tcp -dport $port -source +management" >> "$HOST_FW"
    log_info "✓ 已添加端口: $port"
done

# ========================================
# 重启防火墙
# ========================================
log_step "应用防火墙规则"
echo ""

log_info "重启 PVE 防火墙..."
systemctl restart pve-firewall

log_info "等待防火墙生效..."
sleep 3

# ========================================
# 验证配置
# ========================================
log_step "验证配置"
echo ""

log_info "当前防火墙规则："
iptables -L PVEFW-HOST-IN -n -v | head -20

echo ""
log_info "测试端口监听："
for port in $PORTS; do
    if ss -tlnp | grep -q ":$port"; then
        echo -e "  ${GREEN}✓${NC} 端口 $port 正在监听"
    else
        echo -e "  ${YELLOW}!${NC} 端口 $port 未监听（应用可能未启动）"
    fi
done

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "PVE 防火墙配置完成！"
log_info "========================================="
echo ""

log_info "配置文件: $HOST_FW"
log_info "备份文件: ${BACKUP_FILE:-无}"
echo ""

log_info "已开放的端口："
for port in $PORTS; do
    echo "  - $port (仅允许来自 +management IP 集合)"
done
echo ""

log_info "查看 management IP 集合："
echo "  cat /etc/pve/firewall/cluster.fw"
echo ""

log_info "添加 IP 到 management 集合："
echo "  编辑 /etc/pve/firewall/cluster.fw"
echo "  在 [IPSET management] 部分添加 IP 或网段"
echo ""

log_info "手动重启防火墙："
echo "  systemctl restart pve-firewall"
echo ""

log_warn "注意：防火墙规则只允许来自 +management IP 集合的访问"
log_warn "如需允许所有 IP 访问，请手动修改 $HOST_FW"
log_warn "将 '-source +management' 删除即可"
echo ""
