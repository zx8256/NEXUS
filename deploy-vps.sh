#!/bin/bash
# ========================================
# VPS 服务器部署脚本
# 用途：在 VPS 上部署 3x-ui 面板
# ========================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
    exit 1
fi

log_info "=== 开始部署 VPS 服务器 ==="

# ========================================
# 1. 系统更新和基础软件安装
# ========================================
log_info "1. 更新系统并安装基础软件..."
apt-get update -qq
apt-get install -y curl wget socat iptables net-tools

# ========================================
# 2. 安装 3x-ui 面板
# ========================================
log_info "2. 安装 3x-ui 面板..."

if command -v x-ui &> /dev/null; then
    log_warn "3x-ui 已安装，跳过安装步骤"
else
    log_info "下载并安装 3x-ui..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
fi

# ========================================
# 3. 配置防火墙
# ========================================
log_info "3. 配置防火墙规则..."

# 允许 SSH
iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# 允许 3x-ui 管理端口（默认 2053）
iptables -I INPUT -p tcp --dport 2053 -j ACCEPT

# 允许 VLESS 端口 443
iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 允许公网访问端口 8080
iptables -I INPUT -p tcp --dport 8080 -j ACCEPT

# 保存规则
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    apt-get install -y iptables-persistent
    iptables-save > /etc/iptables/rules.v4
fi

log_info "防火墙规则已配置"

# ========================================
# 4. 配置 SSH 服务允许反向隧道
# ========================================
log_info "4. 配置 SSH 服务..."

if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config; then
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    systemctl restart sshd
    log_info "SSH 反向隧道已启用"
else
    log_warn "SSH GatewayPorts 已配置，跳过"
fi

# ========================================
# 5. 配置 socat 端口转发服务
# ========================================
log_info "5. 配置 socat 端口转发服务..."

cat > /etc/systemd/system/port-forward-8080.service <<'EOF'
[Unit]
Description=Port Forward 8080 to 18080
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:18080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable port-forward-8080
systemctl start port-forward-8080

log_info "socat 端口转发服务已启动"

# ========================================
# 6. 启用 IP 转发
# ========================================
log_info "6. 启用 IP 转发..."

if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    log_info "IP 转发已启用"
else
    log_warn "IP 转发已启用，跳过"
fi

# ========================================
# 7. 配置 DNS
# ========================================
log_info "7. 配置 DNS 服务器..."

if ! grep -q "8.8.8.8" /etc/resolv.conf; then
    cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF
    log_info "DNS 已配置为 Google DNS"
else
    log_warn "DNS 已配置，跳过"
fi

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "VPS 服务器部署完成！"
log_info "========================================="
echo ""
log_info "下一步操作："
echo ""
echo "1. 访问 3x-ui 面板："
echo "   http://$(hostname -I | awk '{print $1}'):2053"
echo ""
echo "2. 默认登录信息："
echo "   用户名: admin"
echo "   密码: admin"
echo "   ⚠️  首次登录后请立即修改密码！"
echo ""
echo "3. 在 3x-ui 面板中配置 VLESS Reality 入站："
echo "   - 端口: 443"
echo "   - 协议: VLESS"
echo "   - 传输: TCP"
echo "   - 安全: Reality"
echo "   - 目标网站: wwwqa.microsoft.com:443"
echo ""
echo "4. 配置完成后，复制 VLESS 链接用于客户端配置"
echo ""
echo "5. 服务状态检查："
echo "   systemctl status port-forward-8080  # 端口转发服务"
echo "   ss -tlnp | grep 8080                # 检查端口监听"
echo ""
log_info "========================================="
