#!/bin/bash
# ========================================
# Origin Validation 问题自动修复脚本
# 用途：解决通过 Cloudflare Tunnel 访问时的 Origin 校验失败问题
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

log_info "=== Origin Validation 问题修复工具 ==="

# ========================================
# 收集信息
# ========================================
echo ""
log_step "========================================="
log_step "请输入配置信息"
log_step "========================================="
echo ""

read -p "你的域名（如 subdomain.yourdomain.com）: " DOMAIN
read -p "根域名（如 yourdomain.com）: " ROOT_DOMAIN
read -p "应用运行端口（默认 8080）: " APP_PORT
APP_PORT=${APP_PORT:-8080}

echo ""
log_info "配置确认："
echo "  域名: $DOMAIN"
echo "  根域名: $ROOT_DOMAIN"
echo "  应用端口: $APP_PORT"
echo ""

read -p "请选择修复方案 (1-4):
  1) 修改 hosts 文件（最简单，推荐）
  2) 配置 NO_PROXY（适合 Docker）
  3) 配置 Nginx 反向代理（生产环境推荐）
  4) 全部应用（推荐）
选择: " CHOICE

case $CHOICE in
    1)
        log_info "选择方案1：修改 hosts 文件"
        ;;
    2)
        log_info "选择方案2：配置 NO_PROXY"
        ;;
    3)
        log_info "选择方案3：配置 Nginx 反向代理"
        ;;
    4)
        log_info "选择方案4：应用所有方案"
        ;;
    *)
        log_error "无效选择"
        exit 1
        ;;
esac

# ========================================
# 方案1：修改 hosts 文件
# ========================================
apply_hosts_fix() {
    log_step "应用方案1：修改 hosts 文件"

    # 备份
    cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)

    # 检查是否已存在
    if grep -q "$DOMAIN" /etc/hosts; then
        log_warn "$DOMAIN 已在 hosts 文件中，跳过"
    else
        echo "" >> /etc/hosts
        echo "# Origin validation fix - added $(date)" >> /etc/hosts
        echo "127.0.0.1 $DOMAIN" >> /etc/hosts
        echo "127.0.0.1 $ROOT_DOMAIN" >> /etc/hosts
        log_info "✓ 已添加本地域名解析"
    fi

    # 验证
    echo ""
    log_info "验证 hosts 配置："
    if ping -c 1 $DOMAIN 2>&1 | grep -q "127.0.0.1"; then
        echo -e "  ${GREEN}✓${NC} $DOMAIN → 127.0.0.1"
    else
        echo -e "  ${RED}✗${NC} $DOMAIN 解析失败"
    fi
}

# ========================================
# 方案2：配置 NO_PROXY
# ========================================
apply_no_proxy_fix() {
    log_step "应用方案2：配置 NO_PROXY"

    # 配置 Shell 环境变量
    log_info "1. 配置 Shell 环境变量..."

    if ! grep -q "$DOMAIN" ~/.bashrc 2>/dev/null; then
        # 找到现有的 no_proxy 行并更新
        if grep -q "export no_proxy=" ~/.bashrc; then
            sed -i "s|export no_proxy='|export no_proxy='$DOMAIN,$ROOT_DOMAIN,|g" ~/.bashrc
            sed -i "s|export NO_PROXY='|export NO_PROXY='$DOMAIN,$ROOT_DOMAIN,|g" ~/.bashrc
        else
            echo "" >> ~/.bashrc
            echo "# Origin validation fix - added $(date)" >> ~/.bashrc
            echo "export no_proxy=\"\${no_proxy},$DOMAIN,$ROOT_DOMAIN\"" >> ~/.bashrc
            echo "export NO_PROXY=\"\${NO_PROXY},$DOMAIN,$ROOT_DOMAIN\"" >> ~/.bashrc
        fi
        log_info "✓ Shell 环境变量已更新"
    else
        log_warn "域名已在 .bashrc 中，跳过"
    fi

    # 配置 Docker
    if command -v docker &> /dev/null; then
        log_info "2. 配置 Docker NO_PROXY..."

        if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
            # 备份
            cp /etc/systemd/system/docker.service.d/http-proxy.conf \
               /etc/systemd/system/docker.service.d/http-proxy.conf.backup.$(date +%Y%m%d_%H%M%S)

            # 更新 NO_PROXY
            if grep -q "$DOMAIN" /etc/systemd/system/docker.service.d/http-proxy.conf; then
                log_warn "Docker 配置中已包含域名，跳过"
            else
                sed -i "s|NO_PROXY=|NO_PROXY=$DOMAIN,$ROOT_DOMAIN,*.${ROOT_DOMAIN},|g" \
                    /etc/systemd/system/docker.service.d/http-proxy.conf

                systemctl daemon-reload
                systemctl restart docker
                log_info "✓ Docker 代理配置已更新"
            fi
        else
            log_warn "Docker 代理配置文件不存在，跳过"
        fi
    else
        log_warn "Docker 未安装，跳过 Docker 配置"
    fi

    # 立即生效
    source ~/.bashrc 2>/dev/null || true

    echo ""
    log_info "验证 NO_PROXY 配置："
    if echo "$no_proxy" | grep -q "$DOMAIN"; then
        echo -e "  ${GREEN}✓${NC} Shell NO_PROXY 已包含 $DOMAIN"
    else
        echo -e "  ${YELLOW}!${NC} 需要重新登录或运行: source ~/.bashrc"
    fi

    if command -v docker &> /dev/null; then
        if docker info 2>&1 | grep "NO_PROXY" | grep -q "$DOMAIN"; then
            echo -e "  ${GREEN}✓${NC} Docker NO_PROXY 已包含 $DOMAIN"
        else
            echo -e "  ${YELLOW}!${NC} Docker 可能需要重启容器"
        fi
    fi
}

# ========================================
# 方案3：配置 Nginx 反向代理
# ========================================
apply_nginx_fix() {
    log_step "应用方案3：配置 Nginx 反向代理（HTTP + HTTPS）"

    # 安装 Nginx
    if ! command -v nginx &> /dev/null; then
        log_info "安装 Nginx..."
        apt-get update -qq
        apt-get install -y nginx
    else
        log_info "Nginx 已安装"
    fi

    # 端口配置
    NGINX_HTTP_PORT=8081
    NGINX_HTTPS_PORT=8443
    log_info "配置 Nginx 监听端口: HTTP=$NGINX_HTTP_PORT, HTTPS=$NGINX_HTTPS_PORT"
    log_warn "请注意：需要将 Cloudflare Tunnel 指向 localhost:$NGINX_HTTP_PORT"

    # 询问是否配置 HTTPS
    echo ""
    read -p "是否配置 HTTPS（需要证书）？(y/n): " SETUP_HTTPS

    CERT_PATH=""
    KEY_PATH=""
    if [ "$SETUP_HTTPS" = "y" ]; then
        read -p "证书文件路径（.pem）: " CERT_PATH
        read -p "私钥文件路径（.pem）: " KEY_PATH

        if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
            log_warn "证书或私钥文件不存在，跳过 HTTPS 配置"
            SETUP_HTTPS="n"
        else
            log_info "✓ 证书文件验证通过"
        fi
    fi

    # 创建配置
    cat > /etc/nginx/sites-available/origin-fix-https <<EOF
# Origin validation fix for $DOMAIN
# Created: $(date)

# HTTP configuration (Cloudflare Tunnel uses this)
server {
    listen $NGINX_HTTP_PORT;
    server_name $DOMAIN $ROOT_DOMAIN;
    access_log /var/log/nginx/${DOMAIN}.http.access.log;
    error_log /var/log/nginx/${DOMAIN}.http.error.log;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Key: Modify Origin to avoid validation failure
        proxy_set_header Origin http://127.0.0.1:${APP_PORT};
        proxy_set_header Referer http://127.0.0.1:${APP_PORT};

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering off;
    }
}
EOF

    # 添加 HTTPS 配置
    if [ "$SETUP_HTTPS" = "y" ]; then
        cat >> /etc/nginx/sites-available/origin-fix-https <<EOF

# HTTPS configuration (LAN access)
server {
    listen $NGINX_HTTPS_PORT ssl http2;
    server_name $DOMAIN $ROOT_DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    # 强化的 SSL/TLS 配置
    ssl_protocols TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';
    ssl_prefer_server_ciphers off;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;

    # Session 配置
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    access_log /var/log/nginx/${DOMAIN}.https.access.log;
    error_log /var/log/nginx/${DOMAIN}.https.error.log;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Origin http://127.0.0.1:${APP_PORT};
        proxy_set_header Referer http://127.0.0.1:${APP_PORT};

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering off;
    }
}
EOF
        log_info "✓ HTTPS 配置已添加"
    fi

    # 启用配置
    ln -sf /etc/nginx/sites-available/origin-fix-https /etc/nginx/sites-enabled/

    # 配置 Nginx OOM 保护和自动重启
    log_info "配置 Nginx OOM 保护和自动重启..."
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/oom-protect.conf <<'EOFOOM'
[Service]
# Prevent OOM Killer from killing Nginx
OOMScoreAdjust=-900
# Auto-restart on failure
Restart=always
RestartSec=5
EOFOOM
    systemctl daemon-reload
    log_info "✓ OOM 保护已配置"

    # 测试配置
    if nginx -t 2>&1 | grep -q "successful"; then
        log_info "✓ Nginx 配置测试通过"
        systemctl restart nginx
        systemctl enable nginx
        log_info "✓ Nginx 已重启"
    else
        log_error "Nginx 配置测试失败"
        nginx -t
        return 1
    fi

    # 验证
    echo ""
    log_info "验证 Nginx 配置："
    if ss -tlnp | grep -q ":$NGINX_HTTP_PORT"; then
        echo -e "  ${GREEN}✓${NC} Nginx HTTP 正在监听端口 $NGINX_HTTP_PORT"
    else
        echo -e "  ${RED}✗${NC} Nginx HTTP 端口 $NGINX_HTTP_PORT 未监听"
    fi

    if [ "$SETUP_HTTPS" = "y" ]; then
        if ss -tlnp | grep -q ":$NGINX_HTTPS_PORT"; then
            echo -e "  ${GREEN}✓${NC} Nginx HTTPS 正在监听端口 $NGINX_HTTPS_PORT"
        else
            echo -e "  ${RED}✗${NC} Nginx HTTPS 端口 $NGINX_HTTPS_PORT 未监听"
        fi
    fi

    if timeout 3 curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$NGINX_HTTP_PORT 2>&1 | grep -q "200\|302\|401"; then
        echo -e "  ${GREEN}✓${NC} Nginx HTTP 代理正常工作"
    else
        echo -e "  ${YELLOW}!${NC} Nginx HTTP 代理可能未正常工作（应用可能未启动）"
    fi

    if [ "$SETUP_HTTPS" = "y" ]; then
        if timeout 3 curl -k -s -o /dev/null -w "%{http_code}" https://127.0.0.1:$NGINX_HTTPS_PORT 2>&1 | grep -q "200\|302\|401"; then
            echo -e "  ${GREEN}✓${NC} Nginx HTTPS 代理正常工作"
        else
            echo -e "  ${YELLOW}!${NC} Nginx HTTPS 代理可能未正常工作"
        fi
    fi

    echo ""
    log_warn "重要：请修改 Cloudflare Tunnel 配置："
    echo "  1. 访问 https://one.dash.cloudflare.com/"
    echo "  2. 找到你的 Tunnel"
    echo "  3. 编辑 Public Hostname"
    echo "  4. 将 URL 从 localhost:$APP_PORT 改为 localhost:$NGINX_HTTP_PORT"
    echo "  5. 保存后等待 30 秒生效"

    if [ "$SETUP_HTTPS" = "y" ]; then
        echo ""
        log_info "HTTPS 局域网访问："
        echo "  访问地址: https://<服务器IP>:$NGINX_HTTPS_PORT"
        echo "  证书: $CERT_PATH"
    fi
}

# ========================================
# 执行选择的方案
# ========================================
echo ""
case $CHOICE in
    1)
        apply_hosts_fix
        ;;
    2)
        apply_no_proxy_fix
        ;;
    3)
        apply_nginx_fix
        ;;
    4)
        log_info "应用所有方案..."
        apply_hosts_fix
        echo ""
        apply_no_proxy_fix
        echo ""
        apply_nginx_fix
        ;;
esac

# ========================================
# 测试
# ========================================
echo ""
log_step "========================================="
log_step "测试配置"
log_step "========================================="
echo ""

log_info "1. 测试域名解析："
if ping -c 1 $DOMAIN 2>&1 | grep -q "127.0.0.1"; then
    echo -e "  ${GREEN}✓${NC} $DOMAIN → 127.0.0.1"
else
    echo -e "  ${YELLOW}!${NC} $DOMAIN → $(dig +short $DOMAIN | head -1)"
fi

log_info "2. 测试本地应用访问："
if timeout 3 curl -s -o /dev/null http://127.0.0.1:$APP_PORT; then
    echo -e "  ${GREEN}✓${NC} 应用端口 $APP_PORT 可访问"
else
    echo -e "  ${RED}✗${NC} 应用端口 $APP_PORT 无法访问"
fi

if [ "$CHOICE" = "3" ] || [ "$CHOICE" = "4" ]; then
    log_info "3. 测试 Nginx 代理："
    if timeout 3 curl -s -o /dev/null http://127.0.0.1:$NGINX_PORT; then
        echo -e "  ${GREEN}✓${NC} Nginx 代理端口 $NGINX_PORT 可访问"
    else
        echo -e "  ${RED}✗${NC} Nginx 代理端口 $NGINX_PORT 无法访问"
    fi
fi

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "Origin Validation 修复完成！"
log_info "========================================="
echo ""

case $CHOICE in
    1)
        log_info "已应用方案1（hosts 文件）"
        echo "  - $DOMAIN 现在解析到 127.0.0.1"
        echo "  - 应用访问自己时不会走代理"
        ;;
    2)
        log_info "已应用方案2（NO_PROXY）"
        echo "  - Shell 环境变量已更新"
        echo "  - Docker 代理已更新（如果已安装）"
        echo "  - 可能需要重启 Docker 容器"
        ;;
    3)
        log_info "已应用方案3（Nginx 反向代理）"
        echo "  - Nginx 监听端口: $NGINX_PORT"
        echo "  - 代理目标: localhost:$APP_PORT"
        echo ""
        log_warn "下一步操作："
        echo "  1. 修改 Cloudflare Tunnel 配置"
        echo "  2. 将 URL 改为: http://localhost:$NGINX_PORT"
        echo "  3. 保存后等待 30 秒"
        ;;
    4)
        log_info "已应用所有方案"
        echo "  ✓ hosts 文件已更新"
        echo "  ✓ NO_PROXY 已配置"
        echo "  ✓ Nginx 反向代理已配置"
        echo ""
        log_warn "推荐使用 Nginx 方案（最可靠）"
        echo "  请修改 Cloudflare Tunnel 指向: http://localhost:$NGINX_PORT"
        ;;
esac

echo ""
log_info "测试方法："
echo "  1. 访问: https://$DOMAIN"
echo "  2. 尝试登录"
echo "  3. 如果成功，问题已解决！"
echo ""
log_info "如果仍然失败，请检查："
echo "  - 应用是否正常运行"
echo "  - Cloudflare Tunnel 配置是否正确"
echo "  - 查看应用日志获取更多信息"
echo ""
log_info "========================================="
