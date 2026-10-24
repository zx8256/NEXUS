#!/bin/bash
# 快速诊断脚本

echo "=== Cloudflare Tunnel + Nginx 诊断 ==="
echo ""

echo "1. 检查 Nginx 是否正常运行"
systemctl status nginx --no-pager | head -3

echo ""
echo "2. 检查端口监听"
ss -tlnp | grep -E '8080|8081'

echo ""
echo "3. 测试直接访问应用"
curl -s -o /dev/null -w "应用端口 8080: HTTP %{http_code}\n" http://127.0.0.1:8080

echo ""
echo "4. 测试 Nginx 代理"
curl -s -o /dev/null -w "Nginx 端口 8081: HTTP %{http_code}\n" http://127.0.0.1:8081

echo ""
echo "5. 测试带 Origin 头的请求"
curl -H "Origin: https://subdomain.yourdomain.com" -s -o /dev/null -w "带 Origin 头: HTTP %{http_code}\n" http://127.0.0.1:8081

echo ""
echo "6. 检查 Cloudflare Tunnel 状态"
systemctl status cloudflared --no-pager | head -3

echo ""
echo "7. 查看最近的 Cloudflare Tunnel 日志"
journalctl -u cloudflared -n 10 --no-pager | grep -E 'ERR|INF'

echo ""
echo "8. 测试外网访问（如果修改了配置）"
echo "请在浏览器访问: https://subdomain.yourdomain.com"
