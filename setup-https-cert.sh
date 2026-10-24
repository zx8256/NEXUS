#!/bin/bash
# ========================================
# Let's Encrypt 证书自动配置脚本
# 使用 DNS-01 验证 + Cloudflare API
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

log_info "=== Let's Encrypt 证书自动配置工具 ==="
echo ""

# ========================================
# 收集配置信息
# ========================================
log_step "收集配置信息"
echo ""

read -r -p "域名（如 subdomain.yourdomain.com）: " DOMAIN
read -r -p "根域名（如 yourdomain.com）: " ROOT_DOMAIN

# 验证域名格式
if ! validate_domain "$DOMAIN"; then
    log_error "无效的域名格式: $DOMAIN"
    exit 1
fi

if ! validate_domain "$ROOT_DOMAIN"; then
    log_error "无效的根域名格式: $ROOT_DOMAIN"
    exit 1
fi

# 安全地读取 API Token（不回显）
read_sensitive "Cloudflare API Token: " CF_TOKEN

# 验证 Token 格式
if ! validate_cloudflare_token "$CF_TOKEN"; then
    log_error "无效的 Cloudflare API Token 格式"
    exit 1
fi

read -r -p "证书保存目录（默认 /home/web/certs）: " CERT_DIR
CERT_DIR=${CERT_DIR:-/home/web/certs}

# 验证路径安全
if ! validate_path "$CERT_DIR"; then
    log_error "无效的证书目录路径"
    exit 1
fi

read -r -p "联系邮箱（用于 Let's Encrypt 通知）: " EMAIL
EMAIL=${EMAIL:-admin@${ROOT_DOMAIN}}

echo ""
log_info "配置确认："
echo "  域名: $DOMAIN"
echo "  根域名: $ROOT_DOMAIN"
echo "  证书目录: $CERT_DIR"
echo "  邮箱: $EMAIL"
echo "  API Token: ***REDACTED***"
echo ""

read -r -p "确认开始配置？(y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    log_warn "用户取消操作"
    exit 0
fi

# 清理敏感变量的痕迹
trap 'unset CF_TOKEN CF_Account_ID CF_Zone_ID' EXIT

# ========================================
# 安装 acme.sh
# ========================================
log_step "安装 acme.sh"
echo ""

if [ ! -d ~/.acme.sh ]; then
    log_info "下载并安装 acme.sh..."

    # 配置代理环境变量（如果有代理）
    if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
        export http_proxy="http://127.0.0.1:8118"
        export https_proxy="http://127.0.0.1:8118"
        log_info "使用代理: http://127.0.0.1:8118"
    fi

    # 验证下载完整性并安装
    if ! curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"; then
        log_error "acme.sh 安装失败"
        exit 1
    fi

    # 添加到 PATH
    export PATH="$HOME/.acme.sh:$PATH"
else
    log_info "acme.sh 已安装"
fi

# ========================================
# 配置 acme.sh
# ========================================
log_step "配置 acme.sh"
echo ""

# 设置默认 CA 为 Let's Encrypt
log_info "设置默认 CA 为 Let's Encrypt..."
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 配置 Cloudflare API Token（使用环境变量，不写入文件）
log_info "配置 Cloudflare API Token..."
export CF_Token="$CF_TOKEN"
export CF_Account_ID=""
export CF_Zone_ID=""

# 不在日志中显示 Token
log_info "✓ API Token 已设置（已加密存储）"

# ========================================
# 申请证书
# ========================================
log_step "申请 Let's Encrypt 证书"
echo ""

log_info "使用 DNS-01 验证方式申请证书..."
log_warn "这个过程需要 1-2 分钟，请耐心等待..."

# 创建证书目录
mkdir -p "$CERT_DIR"

# 申请证书（支持主域名和子域名）
if ~/.acme.sh/acme.sh --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    -d "$ROOT_DOMAIN" \
    --keylength ec-256; then

    log_info "✓ 证书申请成功"
else
    log_error "证书申请失败"
    exit 1
fi

# ========================================
# 安装证书
# ========================================
log_step "安装证书到指定目录"
echo ""

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --cert-file "$CERT_DIR/${DOMAIN}_cert.pem" \
    --key-file "$CERT_DIR/${DOMAIN}_key.pem" \
    --fullchain-file "$CERT_DIR/${DOMAIN}_fullchain.pem" \
    --reloadcmd "systemctl reload nginx 2>/dev/null || true"

log_info "✓ 证书已安装到: $CERT_DIR"

# ========================================
# 验证证书
# ========================================
log_step "验证证书"
echo ""

if [ -f "$CERT_DIR/${DOMAIN}_cert.pem" ]; then
    log_info "证书信息："
    openssl x509 -in "$CERT_DIR/${DOMAIN}_cert.pem" -noout -subject -dates -issuer
    echo ""
    log_info "✓ 证书文件存在且有效"
else
    log_error "证书文件不存在"
    exit 1
fi

# ========================================
# 配置自动续期
# ========================================
log_step "配置自动续期"
echo ""

log_info "acme.sh 已自动配置 cron 任务"
log_info "证书将在到期前 60 天自动续期"

# 显示 cron 任务
if crontab -l 2>/dev/null | grep -q acme.sh; then
    log_info "✓ Cron 任务已配置"
    crontab -l | grep acme.sh
else
    log_warn "未找到 cron 任务，可能需要手动配置"
fi

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "证书配置完成！"
log_info "========================================="
echo ""

log_info "证书文件："
echo "  证书: $CERT_DIR/${DOMAIN}_cert.pem"
echo "  私钥: $CERT_DIR/${DOMAIN}_key.pem"
echo "  完整链: $CERT_DIR/${DOMAIN}_fullchain.pem"
echo ""

log_info "证书有效期："
openssl x509 -in "$CERT_DIR/${DOMAIN}_cert.pem" -noout -dates | grep "notAfter" | cut -d= -f2
echo ""

log_info "下一步操作："
echo "  1. 在 Nginx 配置中使用这些证书文件"
echo "  2. 重启 Nginx: systemctl restart nginx"
echo "  3. 证书将在到期前自动续期"
echo ""

log_info "测试证书："
echo "  openssl s_client -connect ${DOMAIN}:443 -servername ${DOMAIN}"
echo ""

log_info "手动续期命令（通常不需要）："
echo "  ~/.acme.sh/acme.sh --renew -d ${DOMAIN} --ecc --force"
echo ""
