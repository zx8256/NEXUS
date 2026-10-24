#!/bin/bash
# ========================================
# Cloudflare Tunnel 配置脚本
# 用途：配置 Cloudflare Tunnel 实现安全的入站访问
# ========================================

set -euo pipefail

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载安全工具函数
if [ -f "$SCRIPT_DIR/lib/security.sh" ]; then
    source "$SCRIPT_DIR/lib/security.sh"
else
    echo "错误：找不到安全工具库 lib/security.sh"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(filter_sensitive "$1")"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(filter_sensitive "$1")"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(filter_sensitive "$1")"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
    exit 1
fi

log_info "=== 配置 Cloudflare Tunnel ==="

# ========================================
# 1. 安装 cloudflared
# ========================================
log_info "1. 安装 cloudflared..."

if command -v cloudflared &> /dev/null; then
    log_warn "cloudflared 已安装: $(cloudflared version)"
else
    log_info "下载并安装 cloudflared..."

    # 添加 Cloudflare GPG 密钥（带完整性验证）
    mkdir -p --mode=0755 /usr/share/keyrings

    # 下载 GPG 密钥并验证
    if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg; then
        log_error "下载 Cloudflare GPG 密钥失败"
        exit 1
    fi

    # 验证 GPG 密钥指纹
    gpg --list-packets /usr/share/keyrings/cloudflare-main.gpg > /dev/null 2>&1 || {
        log_error "GPG 密钥验证失败"
        rm -f /usr/share/keyrings/cloudflare-main.gpg
        exit 1
    }

    # 添加仓库
    local codename
    codename=$(lsb_release -cs)
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $codename main" | tee /etc/apt/sources.list.d/cloudflared.list

    # 安装
    apt-get update
    apt-get install -y cloudflared

    log_info "cloudflared 安装完成: $(cloudflared version)"
fi

# ========================================
# 2. 配置说明
# ========================================
echo ""
log_step "========================================="
log_step "Cloudflare Tunnel 配置指南"
log_step "========================================="
echo ""
log_info "请按照以下步骤操作："
echo ""
echo "步骤 1: 访问 Cloudflare Zero Trust Dashboard"
echo "  https://one.dash.cloudflare.com/"
echo ""
echo "步骤 2: 创建 Tunnel"
echo "  1. 点击 Networks → Tunnels"
echo "  2. 点击 'Create a tunnel'"
echo "  3. 选择 'Cloudflared'"
echo "  4. 输入隧道名称（如 pve-tunnel）"
echo "  5. 点击 'Save tunnel'"
echo ""
echo "步骤 3: 安装 Tunnel Token"
echo "  页面会显示一个 Token（格式：eyJhIjoiNzg5...）"
echo ""
read -r -p "请粘贴 Tunnel Token: " TUNNEL_TOKEN

# 验证 Token 格式（base64）
if [[ ! "$TUNNEL_TOKEN" =~ ^eyJ[A-Za-z0-9+/=]+$ ]]; then
    log_error "无效的 Tunnel Token 格式"
    exit 1
fi

# ========================================
# 3. 安全地安装 Tunnel
# ========================================
log_info "3. 安装 Cloudflare Tunnel..."

# 使用参数化命令而不是 eval
if ! cloudflared service install "$TUNNEL_TOKEN"; then
    log_error "Tunnel 安装失败"
    exit 1
fi

# 等待服务启动
sleep 5

# ========================================
# 4. 检查服务状态
# ========================================
log_info "4. 检查服务状态..."
systemctl status cloudflared --no-pager | head -15

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "Cloudflare Tunnel 安装完成！"
log_info "========================================="
echo ""
log_info "下一步："
echo ""
echo "1. 在 Cloudflare Dashboard 中配置 Public Hostname："
echo "   - 点击你的 Tunnel"
echo "   - 点击 'Public Hostname' 标签"
echo "   - 点击 'Add a public hostname'"
echo ""
echo "2. 填写配置："
echo "   Subdomain: pve"
echo "   Domain: 你的域名（如 example.com）"
echo "   Type: HTTP"
echo "   URL: localhost:8080"
echo ""
echo "3. 保存后等待 30 秒"
echo ""
echo "4. 访问测试："
echo "   https://pve.你的域名.com"
echo ""
log_info "服务管理："
echo "  systemctl status cloudflared   # 查看状态"
echo "  systemctl restart cloudflared  # 重启服务"
echo "  journalctl -u cloudflared -f   # 查看日志"
echo ""
log_info "========================================="
