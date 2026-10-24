---
name: network-proxy-setup
description: 内网穿透与代理完整部署方案 - 自动化配置 Xray、Privoxy、SSH隧道、Cloudflare Tunnel，实现入站走Cloudflare/SSH隧道，出站走Xray代理
version: 1.0.0
author: Claude
---

# 内网穿透与代理部署 Agent

## 功能概述

这个技能提供完整的内网穿透和代理部署自动化方案，包括：

### 入站（外网访问内网）
- ✅ Cloudflare Tunnel（HTTPS，安全，隐藏IP）
- ✅ SSH 反向隧道（HTTP，备用方案）

### 出站（内网访问外网）
- ✅ Xray VLESS Reality 代理
- ✅ Privoxy（SOCKS5 → HTTP 转换）
- ✅ 全局代理支持（Docker、Git、apt-get 等）

## 使用方法

### 快速开始

```bash
# 调用此技能
/network-proxy-setup
```

Agent 会引导你完成以下步骤：

1. **VPS 服务器部署**
   - 安装 3x-ui 面板
   - 配置 VLESS Reality
   - 设置端口转发

2. **内网服务器配置**
   - 安装 Xray 客户端
   - 配置 Privoxy 代理
   - 设置 SSH 反向隧道
   - 配置 Docker/Git 代理

3. **Cloudflare Tunnel**（可选）
   - 安装 cloudflared
   - 配置安全访问

## 部署脚本

### 1. VPS 服务器部署

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/.../deploy-vps.sh

# 运行
bash deploy-vps.sh
```

### 2. 内网服务器配置

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/.../deploy-client.sh

# 运行（会提示输入 VPS 配置信息）
bash deploy-client.sh
```

### 3. Cloudflare Tunnel 配置

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/.../setup-cloudflare-tunnel.sh

# 运行
bash setup-cloudflare-tunnel.sh
```

## 架构图

```
入站（外网 → 内网）：
Internet → Cloudflare CDN → Cloudflared → 内网服务(8080)
Internet → VPS(8080) → SSH 隧道(18080) → 内网服务(8080)

出站（内网 → 外网）：
应用 → HTTP代理(8118) → SOCKS5(10808) → Xray → VPS → 外网
```

## 前置条件

### VPS 要求
- Debian 11+ / Ubuntu 20.04+
- 公网 IP
- 端口：22, 443, 2053, 8080

### 内网服务器要求
- Debian 11+ / Ubuntu 20.04+
- 可访问 VPS
- Root 权限

### 可选
- 域名（用于 Cloudflare Tunnel）
- Cloudflare 账号（免费）

## 配置文件

部署完成后的关键配置文件：

| 文件 | 用途 |
|------|------|
| `/etc/xray-client-443-final.json` | Xray 客户端配置 |
| `/etc/systemd/system/xray-client.service` | Xray 服务 |
| `/etc/systemd/system/reverse-tunnel.service` | SSH 隧道服务 |
| `/etc/systemd/system/docker.service.d/http-proxy.conf` | Docker 代理 |
| `/etc/privoxy/config` | Privoxy 配置 |

## 服务管理

### 查看状态
```bash
systemctl status xray-client      # Xray 代理
systemctl status privoxy          # HTTP 代理转换
systemctl status reverse-tunnel   # SSH 隧道
systemctl status cloudflared      # Cloudflare Tunnel
```

### 重启服务
```bash
systemctl restart xray-client
systemctl restart privoxy
systemctl restart reverse-tunnel
systemctl restart cloudflared
```

### 查看日志
```bash
journalctl -u xray-client -f
journalctl -u privoxy -f
journalctl -u reverse-tunnel -f
journalctl -u cloudflared -f
```

## 测试命令

### 测试代理连接
```bash
# SOCKS5 代理
curl -x socks5://127.0.0.1:10808 -I https://www.google.com

# HTTP 代理
curl -x http://127.0.0.1:8118 -I https://www.google.com

# Git 访问
git ls-remote https://github.com/torvalds/linux.git HEAD

# Docker 拉取
docker pull hello-world
```

### 测试入站访问
```bash
# Cloudflare Tunnel
curl https://pve.example.com

# SSH 隧道
curl http://VPS_IP:8080

# 局域网
curl http://YOUR_INTERNAL_IP:8080
```

## 常见问题

### 1. 代理无法连接
```bash
# 检查 Xray 服务
systemctl restart xray-client
systemctl status xray-client
```

### 2. Docker 拉取失败
```bash
# 检查 Docker 代理配置
docker info | grep -A 3 'HTTP Proxy'

# 重启服务
systemctl restart privoxy
systemctl restart docker
```

### 3. Git 无法访问 GitHub
```bash
# 重新配置 Git 代理
git config --global http.proxy http://127.0.0.1:8118
git config --global https.proxy http://127.0.0.1:8118
```

### 4. SSH 隧道断开
```bash
# 检查密钥
ssh root@VPS_IP "echo OK"

# 重启隧道
systemctl restart reverse-tunnel
```

## 快速命令

```bash
# 代理状态
proxy-status

# 启用代理
proxy-on

# 禁用代理
proxy-off

# 查看所有服务
systemctl status xray-client privoxy reverse-tunnel cloudflared
```

## 安全建议

1. ✅ 修改 3x-ui 默认密码
2. ✅ 配置防火墙规则
3. ✅ 定期更新系统
4. ✅ 启用 Fail2ban（VPS）
5. ✅ 定期检查日志

## 维护建议

- 每周检查服务状态
- 每月备份配置文件
- 每月更新系统
- 监控代理性能

## 技术支持

详细文档请参考 `README.md`。

## 许可证

MIT License
