#!/bin/bash
# ========================================
# 统一健康检查服务
# 监控所有关键服务的健康状态
# ========================================

set -euo pipefail

# 配置
LOG_FILE="/var/log/network-proxy-health.log"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
MAX_FAILURES=3

# 服务列表
declare -A SERVICES=(
    ["xray-client"]="SOCKS5代理"
    ["privoxy"]="HTTP代理"
    ["nginx"]="Nginx反向代理"
    ["cloudflared"]="Cloudflare Tunnel"
)

# 端口检查
declare -A PORTS=(
    ["10808"]="Xray SOCKS5"
    ["8118"]="Privoxy HTTP"
    ["8081"]="Nginx HTTP"
    ["8443"]="Nginx HTTPS"
)

# 记录日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 发送告警
send_alert() {
    local message="$1"
    log "ALERT: $message"

    if [ -n "$ALERT_WEBHOOK" ]; then
        curl -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"⚠️ Network Proxy Alert: $message\"}" \
            2>/dev/null || true
    fi
}

# 检查 systemd 服务状态
check_service() {
    local service="$1"
    local name="$2"

    if systemctl is-active --quiet "$service"; then
        log "✓ $name ($service) 运行正常"
        return 0
    else
        log "✗ $name ($service) 未运行"
        send_alert "$name 服务停止运行"
        return 1
    fi
}

# 检查端口监听
check_port() {
    local port="$1"
    local name="$2"

    if ss -tlnp | grep -q ":$port "; then
        log "✓ 端口 $port ($name) 正常监听"
        return 0
    else
        log "✗ 端口 $port ($name) 未监听"
        send_alert "端口 $port ($name) 未监听"
        return 1
    fi
}

# 检查代理连通性
check_proxy() {
    local proxy="$1"
    local name="$2"

    if timeout 10 curl -x "$proxy" -s -o /dev/null -w "%{http_code}" https://www.google.com 2>&1 | grep -q "200\|301\|302"; then
        log "✓ $name 代理连通性正常"
        return 0
    else
        log "✗ $name 代理连通性测试失败"
        send_alert "$name 代理无法访问外网"
        return 1
    fi
}

# 主检查流程
main() {
    log "========== 健康检查开始 =========="

    local failures=0

    # 检查 systemd 服务
    for service in "${!SERVICES[@]}"; do
        if ! check_service "$service" "${SERVICES[$service]}"; then
            ((failures++))
        fi
    done

    # 检查端口
    for port in "${!PORTS[@]}"; do
        if ! check_port "$port" "${PORTS[$port]}"; then
            ((failures++))
        fi
    done

    # 检查代理连通性
    if ! check_proxy "socks5://127.0.0.1:10808" "SOCKS5"; then
        ((failures++))
    fi

    if ! check_proxy "http://127.0.0.1:8118" "HTTP"; then
        ((failures++))
    fi

    # 检查 SSH 隧道
    if systemctl is-active --quiet reverse-tunnel; then
        log "✓ SSH 反向隧道运行中"
    else
        log "✗ SSH 反向隧道未运行"
        ((failures++))
    fi

    # 汇总结果
    if [ $failures -eq 0 ]; then
        log "========== 所有检查通过 =========="
        exit 0
    elif [ $failures -ge $MAX_FAILURES ]; then
        log "========== 检查失败: $failures 项 =========="
        send_alert "健康检查失败 $failures 项，系统可能存在严重问题"
        exit 1
    else
        log "========== 检查完成，$failures 项警告 =========="
        exit 0
    fi
}

main
