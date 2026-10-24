#!/bin/bash
# ========================================
# 内网服务器配置脚本
# 用途：配置 Xray 客户端、代理、反向隧道等
# ========================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户运行此脚本"
    exit 1
fi

log_info "=== 开始配置内网服务器 ==="

# ========================================
# 配置参数收集
# ========================================
echo ""
log_step "========================================="
log_step "请输入配置参数"
log_step "========================================="
echo ""

read -p "VPS 服务器 IP 地址: " VPS_IP
read -p "VLESS 用户 UUID (从 3x-ui 复制): " VLESS_UUID
read -p "Reality publicKey (从 3x-ui 复制): " REALITY_PUBLIC_KEY
read -p "Reality shortId (从 3x-ui 复制): " REALITY_SHORT_ID
read -p "Reality spiderX (从 3x-ui 复制, 默认 /): " REALITY_SPIDER_X
REALITY_SPIDER_X=${REALITY_SPIDER_X:-/}

echo ""
log_info "配置参数确认："
echo "  VPS IP: $VPS_IP"
echo "  UUID: $VLESS_UUID"
echo "  publicKey: $REALITY_PUBLIC_KEY"
echo "  shortId: $REALITY_SHORT_ID"
echo "  spiderX: $REALITY_SPIDER_X"
echo ""
read -p "确认以上信息正确？(y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_error "用户取消操作"
    exit 1
fi

# ========================================
# 1. 系统更新和基础软件安装
# ========================================
log_info "1. 更新系统并安装基础软件..."
apt-get update -qq
apt-get install -y curl wget unzip socat jq privoxy proxychains4

# ========================================
# 2. 安装 Xray 客户端
# ========================================
log_info "2. 安装 Xray 客户端..."

if [ -f /usr/local/bin/xray ]; then
    log_warn "Xray 已安装，跳过安装"
else
    log_info "下载 Xray..."
    XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" -O /tmp/xray.zip

    log_info "解压并安装..."
    unzip -q /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -rf /tmp/xray /tmp/xray.zip

    log_info "Xray 安装完成: $(/usr/local/bin/xray version | head -1)"
fi

# ========================================
# 3. 配置 Xray 客户端
# ========================================
log_info "3. 配置 Xray 客户端..."

cat > /etc/xray-client-443-final.json <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${VPS_IP}",
            "port": 443,
            "users": [
              {
                "id": "${VLESS_UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "wwwqa.microsoft.com",
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "shortId": "${REALITY_SHORT_ID}",
          "spiderX": "${REALITY_SPIDER_X}"
        }
      }
    }
  ]
}
EOF

log_info "Xray 配置文件已创建: /etc/xray-client-443-final.json"

# ========================================
# 4. 创建 Xray systemd 服务
# ========================================
log_info "4. 创建 Xray systemd 服务..."

cat > /etc/systemd/system/xray-client.service <<'EOF'
[Unit]
Description=Xray Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray-client-443-final.json
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-client
systemctl start xray-client

log_info "Xray 服务已启动"

# 等待启动
sleep 3

# ========================================
# 5. 配置 Privoxy（SOCKS5 → HTTP 代理）
# ========================================
log_info "5. 配置 Privoxy..."

cat > /etc/privoxy/config <<'EOF'
listen-address  127.0.0.1:8118
forward-socks5 / 127.0.0.1:10808 .
EOF

systemctl restart privoxy
systemctl enable privoxy

log_info "Privoxy 已配置并启动"

# ========================================
# 6. 配置 Docker 代理
# ========================================
log_info "6. 配置 Docker 代理..."

if command -v docker &> /dev/null; then
    mkdir -p /etc/systemd/system/docker.service.d

    cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:8118"
Environment="HTTPS_PROXY=http://127.0.0.1:8118"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8"
EOF

    systemctl daemon-reload
    systemctl restart docker
    log_info "Docker 代理已配置"
else
    log_warn "Docker 未安装，跳过 Docker 代理配置"
fi

# ========================================
# 7. 配置 Git 代理
# ========================================
log_info "7. 配置 Git 代理..."

git config --global http.proxy http://127.0.0.1:8118
git config --global https.proxy http://127.0.0.1:8118

log_info "Git 代理已配置"

# ========================================
# 8. 配置 Shell 环境变量
# ========================================
log_info "8. 配置 Shell 环境变量..."

if ! grep -q "# === 全局代理配置 ===" ~/.bashrc; then
    cat >> ~/.bashrc <<'EOF'

# === 全局代理配置 ===
export http_proxy=socks5://127.0.0.1:10808
export https_proxy=socks5://127.0.0.1:10808
export HTTP_PROXY=socks5://127.0.0.1:10808
export HTTPS_PROXY=socks5://127.0.0.1:10808
export all_proxy=socks5://127.0.0.1:10808
export ALL_PROXY=socks5://127.0.0.1:10808
export no_proxy='localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8'
export NO_PROXY='localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8'

# 代理管理别名
alias proxy-on='export http_proxy=socks5://127.0.0.1:10808 https_proxy=socks5://127.0.0.1:10808'
alias proxy-off='unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY'
alias proxy-status='echo "HTTP_PROXY: $http_proxy" && echo "HTTPS_PROXY: $https_proxy"'
EOF
    log_info "Shell 环境变量已配置"
else
    log_warn "Shell 环境变量已存在，跳过"
fi

# 立即生效
source ~/.bashrc

# ========================================
# 9. 配置 proxychains（可选）
# ========================================
log_info "9. 配置 proxychains..."

cat > /etc/proxychains4.conf <<'EOF'
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5 127.0.0.1 10808
EOF

log_info "proxychains 已配置"

# ========================================
# 10. 配置 SSH 反向隧道服务
# ========================================
log_info "10. 配置 SSH 反向隧道服务..."

# 检查 SSH 密钥
if [ ! -f ~/.ssh/id_rsa ]; then
    log_info "生成 SSH 密钥对..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
fi

log_warn "需要手动操作：将 SSH 公钥复制到 VPS"
echo ""
echo "运行以下命令将公钥复制到 VPS："
echo "  ssh-copy-id root@${VPS_IP}"
echo ""
read -p "完成后按回车继续..."

# 创建反向隧道服务
cat > /etc/systemd/system/reverse-tunnel.service <<EOF
[Unit]
Description=SSH Reverse Tunnel to Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ssh -N -R 18080:localhost:8080 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes root@${VPS_IP}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable reverse-tunnel
systemctl start reverse-tunnel

log_info "SSH 反向隧道服务已启动"

# ========================================
# 11. 测试所有网络功能
# ========================================
log_info "11. 测试网络功能..."

echo ""
log_step "========================================="
log_step "网络功能测试"
log_step "========================================="
echo ""

# 测试 SOCKS5 代理
echo -n "📡 SOCKS5 代理 (10808): "
if timeout 10 curl -x socks5://127.0.0.1:10808 -s -I https://www.google.com | grep -q "HTTP/"; then
    echo -e "${GREEN}✓ 正常${NC}"
else
    echo -e "${RED}✗ 失败${NC}"
fi

# 测试 HTTP 代理
echo -n "📡 HTTP 代理 (8118): "
if timeout 10 curl -x http://127.0.0.1:8118 -s -I https://www.google.com | grep -q "HTTP/"; then
    echo -e "${GREEN}✓ 正常${NC}"
else
    echo -e "${RED}✗ 失败${NC}"
fi

# 测试 Git
echo -n "📡 Git 访问 GitHub: "
if timeout 10 git ls-remote https://github.com/torvalds/linux.git HEAD &> /dev/null; then
    echo -e "${GREEN}✓ 正常${NC}"
else
    echo -e "${RED}✗ 失败${NC}"
fi

# 测试 Docker（如果安装）
if command -v docker &> /dev/null; then
    echo -n "📡 Docker 代理: "
    if docker info 2>&1 | grep -q "HTTP Proxy"; then
        echo -e "${GREEN}✓ 已配置${NC}"
    else
        echo -e "${RED}✗ 未配置${NC}"
    fi
fi

# 测试 SSH 隧道
echo -n "📡 SSH 反向隧道: "
if systemctl is-active --quiet reverse-tunnel; then
    echo -e "${GREEN}✓ 运行中${NC}"
else
    echo -e "${RED}✗ 未运行${NC}"
fi

# ========================================
# 完成
# ========================================
echo ""
log_info "========================================="
log_info "内网服务器配置完成！"
log_info "========================================="
echo ""
log_info "服务状态："
echo "  ✓ Xray 客户端: systemctl status xray-client"
echo "  ✓ Privoxy: systemctl status privoxy"
echo "  ✓ SSH 反向隧道: systemctl status reverse-tunnel"
echo ""
log_info "代理配置："
echo "  • SOCKS5 代理: 127.0.0.1:10808"
echo "  • HTTP 代理: 127.0.0.1:8118"
echo ""
log_info "访问方式："
echo "  • 局域网: http://$(hostname -I | awk '{print $1}'):8080"
echo "  • SSH 隧道: http://${VPS_IP}:8080"
echo "  • Cloudflare Tunnel: 需单独配置"
echo ""
log_info "快捷命令："
echo "  • proxy-status  - 查看代理状态"
echo "  • proxy-on      - 启用代理"
echo "  • proxy-off     - 禁用代理"
echo ""
log_info "下一步（可选）："
echo "  1. 配置 Cloudflare Tunnel（更安全的入站方式）"
echo "  2. 测试所有功能是否正常"
echo ""
log_info "========================================="
