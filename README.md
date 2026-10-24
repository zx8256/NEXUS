# 内网穿透与代理完整部署文档

## 📋 目录

1. [概述](#概述)
2. [架构设计](#架构设计)
3. [前置条件](#前置条件)
4. [部署流程](#部署流程)
5. [故障排查](#故障排查)
6. [维护手册](#维护手册)

---

## 概述

这是一个完整的企业级网络配置方案，实现：

### 🔒 入站流量（外网访问内网服务）
- **Cloudflare Tunnel**：安全的 HTTPS 访问，隐藏真实 IP
- **SSH 反向隧道**：备用方案，通过 VPS 转发

### 🚀 出站流量（内网访问外网）
- **Xray VLESS Reality**：高性能代理，突破网络限制
- **全局代理支持**：Docker、Git、apt-get 等工具自动使用代理

### ✨ 核心优势

- ✅ **自动化部署**：一键脚本，10 分钟完成配置
- ✅ **开机自启**：所有服务自动启动，无需手动干预
- ✅ **高可用性**：多种入站方式，服务持续可用
- ✅ **安全可靠**：HTTPS 加密 + Reality 协议混淆
- ✅ **易于维护**：systemd 统一管理，日志完整

---

## 架构设计

### 网络拓扑图

```
┌─────────────────────────────────────────────────────────────┐
│                         外网用户                              │
└────────────┬────────────────────────────────┬────────────────┘
             │                                │
             │ HTTPS (443)                    │ HTTP (8080)
             ▼                                ▼
   ┌─────────────────┐              ┌─────────────────┐
   │ Cloudflare CDN  │              │  VPS 服务器     │
   │  (隐藏真实IP)    │              │  YOUR_VPS_IP │
   └────────┬────────┘              └────────┬────────┘
            │                                │
            │ Cloudflare Tunnel              │ SSH 反向隧道
            │                                │ (18080→8080)
            ▼                                ▼
   ┌────────────────────────────────────────────────────────┐
   │              内网服务器 (YOUR_INTERNAL_IP)                  │
   ├────────────────────────────────────────────────────────┤
   │  入站服务：                                              │
   │    • 端口 8080: Web 服务                                │
   │    • Cloudflare Tunnel Agent                           │
   │    • SSH 隧道客户端                                      │
   ├────────────────────────────────────────────────────────┤
   │  出站代理链：                                            │
   │    应用 → HTTP(8118) → SOCKS5(10808) → Xray → VPS → 外网 │
   │                                                         │
   │  支持的应用：                                            │
   │    • Docker (pull/push)                                │
   │    • Git (clone/pull/push)                             │
   │    • apt-get (update/install)                          │
   │    • curl/wget/npm/pip...                              │
   └────────────────────────────────────────────────────────┘
```

### 服务依赖关系

```
内网服务器服务栈：
├── Xray Client (10808) ← SOCKS5 代理基础
│   └── systemd: xray-client.service
│
├── Privoxy (8118) ← SOCKS5 → HTTP 转换
│   └── systemd: privoxy.service
│
├── Docker Daemon ← 使用 HTTP 代理
│   └── 配置: /etc/systemd/system/docker.service.d/http-proxy.conf
│
├── SSH Reverse Tunnel ← 反向隧道
│   └── systemd: reverse-tunnel.service
│
└── Cloudflare Tunnel ← 安全入站
    └── systemd: cloudflared.service

VPS 服务器服务栈：
├── 3x-ui Panel ← Xray 服务器管理
│   └── 端口: 2053 (管理), 443 (VLESS)
│
└── Socat Port Forward ← 端口转发
    └── systemd: port-forward-8080.service
    └── 8080 → 18080 (SSH 隧道端口)
```

---

## 前置条件

### VPS 服务器

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 11+ / Ubuntu 20.04+ |
| 内存 | ≥ 512MB |
| 硬盘 | ≥ 10GB |
| 网络 | 公网 IP，可访问 |
| 端口 | 22 (SSH), 443 (VLESS), 2053 (3x-ui), 8080 (Web) |

### 内网服务器

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 11+ / Ubuntu 20.04+ |
| 内存 | ≥ 1GB |
| 硬盘 | ≥ 20GB |
| 网络 | 可访问 VPS，可被局域网访问 |
| 权限 | root 或 sudo |

### 可选资源

- **域名**：用于 Cloudflare Tunnel（推荐）
- **Cloudflare 账号**：免费注册即可

---

## 部署流程

### 第一阶段：VPS 服务器部署

#### 1.1 上传并运行部署脚本

```bash
# 上传脚本到 VPS
scp deploy-vps.sh root@YOUR_VPS_IP:/root/

# SSH 连接到 VPS
ssh root@YOUR_VPS_IP

# 添加执行权限
chmod +x /root/deploy-vps.sh

# 运行脚本
bash /root/deploy-vps.sh
```

#### 1.2 配置 3x-ui 面板

脚本运行完成后，访问 3x-ui 管理面板：

```
http://YOUR_VPS_IP:2053
```

**默认登录信息：**
- 用户名：`admin`
- 密码：`admin`

⚠️ **首次登录后立即修改密码！**

#### 1.3 创建 VLESS Reality 入站

1. 登录面板后，点击 **"入站列表"** → **"添加入站"**

2. 填写配置：

   | 字段 | 值 |
   |------|------|
   | 备注 | `VLESS-Reality-443` |
   | 协议 | `VLESS` |
   | 监听 IP | `0.0.0.0` |
   | 端口 | `443` |
   | 传输协议 | `TCP` |
   | 流控 | `xtls-rprx-vision` |
   | TLS | `Reality` |
   | 目标网站 | `wwwqa.microsoft.com:443` |
   | ServerNames | `wwwqa.microsoft.com` |

3. 点击 **"保存"**，然后点击 **"生成密钥"** 生成 Reality 密钥对

4. 点击 **"复制链接"** 或手动记录以下信息：
   - UUID
   - publicKey
   - shortId
   - spiderX

#### 1.4 测试端口

```bash
# 检查 3x-ui 运行状态
systemctl status x-ui

# 检查端口监听
ss -tlnp | grep -E '443|2053|8080'

# 应该看到：
# *:443   (Xray)
# *:2053  (3x-ui Web)
# *:8080  (socat)
```

---

### 第二阶段：内网服务器配置

#### 2.1 上传并运行配置脚本

```bash
# 在本地机器上传脚本到内网服务器
scp deploy-client.sh root@YOUR_INTERNAL_IP:/root/

# SSH 连接到内网服务器
ssh root@YOUR_INTERNAL_IP

# 添加执行权限
chmod +x /root/deploy-client.sh

# 运行脚本
bash /root/deploy-client.sh
```

#### 2.2 按提示输入配置信息

脚本会提示输入以下信息（从 3x-ui 获取）：

```
VPS 服务器 IP 地址: YOUR_VPS_IP
VLESS 用户 UUID: 404aa7bb-b4dc-4db4-9875-e03140737112
Reality publicKey: 54pVNoRgle2zhGjlAHwH9aQ9dOusEDisleS3-OoE6ho
Reality shortId: 41cadcd32e139d98
Reality spiderX: /24acde256b1bf51
```

#### 2.3 配置 SSH 密钥（脚本会提示）

当脚本提示时，运行：

```bash
ssh-copy-id root@YOUR_VPS_IP
```

输入 VPS 的 root 密码，完成密钥复制。

#### 2.4 验证所有服务

脚本结束时会自动测试所有功能：

```
📡 SOCKS5 代理 (10808): ✓ 正常
📡 HTTP 代理 (8118): ✓ 正常
📡 Git 访问 GitHub: ✓ 正常
📡 Docker 代理: ✓ 已配置
📡 SSH 反向隧道: ✓ 运行中
```

---

### 第三阶段：Cloudflare Tunnel 配置（可选）

#### 3.1 前置准备

- 注册 Cloudflare 账号：https://dash.cloudflare.com/sign-up
- 添加域名到 Cloudflare（如 `example.com`）
- 修改域名 DNS 服务器为 Cloudflare 提供的地址

#### 3.2 运行 Cloudflare Tunnel 配置脚本

```bash
# 在内网服务器上运行
bash /root/setup-cloudflare-tunnel.sh
```

#### 3.3 创建 Tunnel

1. 访问：https://one.dash.cloudflare.com/
2. 点击 **Networks → Tunnels**
3. 点击 **"Create a tunnel"**
4. 选择 **"Cloudflared"**
5. 输入隧道名称：`pve-tunnel`
6. 点击 **"Save tunnel"**

#### 3.4 安装 Connector

复制页面显示的安装命令（类似）：

```bash
sudo cloudflared service install eyJhIjoiNzg5YzJkZjU2ODA2...
```

粘贴到脚本提示中。

#### 3.5 配置 Public Hostname

在 Cloudflare Dashboard：

1. 点击你的 Tunnel
2. 点击 **"Public Hostname"** 标签
3. 点击 **"Add a public hostname"**
4. 填写：
   - **Subdomain**: `pve`
   - **Domain**: `example.com`
   - **Type**: `HTTP`
   - **URL**: `localhost:8080`
5. 点击 **"Save hostname"**

#### 3.6 测试访问

等待 30 秒后访问：

```
https://pve.example.com
```

---

## 故障排查

### 问题 1：Xray 代理无法连接外网

**症状：**
```bash
curl -x socks5://127.0.0.1:10808 https://www.google.com
# 超时或连接失败
```

**排查步骤：**

1. 检查 Xray 服务状态
```bash
systemctl status xray-client
```

2. 检查端口监听
```bash
ss -tlnp | grep 10808
```

3. 检查 VPS 上的 Xray 服务器
```bash
ssh root@YOUR_VPS_IP
systemctl status x-ui
ss -tlnp | grep 443
```

4. 查看 Xray 日志
```bash
journalctl -u xray-client -n 50
```

5. 测试到 VPS 的连接
```bash
telnet YOUR_VPS_IP 443
```

**解决方案：**

- 重启 Xray 客户端：`systemctl restart xray-client`
- 检查 3x-ui 配置是否正确
- 验证 UUID、publicKey、shortId 是否匹配

---

### 问题 2：Docker 无法拉取镜像

**症状：**
```bash
docker pull nginx
# 超时或连接失败
```

**排查步骤：**

1. 检查 Docker 代理配置
```bash
docker info | grep -A 3 'HTTP Proxy'
```

2. 检查 Privoxy 状态
```bash
systemctl status privoxy
```

3. 测试 HTTP 代理
```bash
curl -x http://127.0.0.1:8118 -I https://www.google.com
```

**解决方案：**

```bash
# 重启 Privoxy
systemctl restart privoxy

# 重启 Docker
systemctl restart docker

# 测试拉取
docker pull hello-world
```

---

### 问题 3：Git 无法访问 GitHub

**症状：**
```bash
git clone https://github.com/torvalds/linux.git
# Failed to connect
```

**排查步骤：**

1. 检查 Git 代理配置
```bash
git config --global --get http.proxy
git config --global --get https.proxy
```

2. 测试代理
```bash
curl -x http://127.0.0.1:8118 -I https://github.com
```

**解决方案：**

```bash
# 重新配置 Git 代理
git config --global http.proxy http://127.0.0.1:8118
git config --global https.proxy http://127.0.0.1:8118

# 测试
git ls-remote https://github.com/torvalds/linux.git HEAD
```

---

### 问题 4：SSH 反向隧道断开

**症状：**
```bash
systemctl status reverse-tunnel
# 显示 failed 或 inactive
```

**排查步骤：**

1. 检查 SSH 密钥
```bash
ssh root@YOUR_VPS_IP "echo OK"
```

2. 手动测试隧道
```bash
ssh -N -R 18080:localhost:8080 root@YOUR_VPS_IP
```

3. 查看日志
```bash
journalctl -u reverse-tunnel -n 50
```

**解决方案：**

```bash
# 重启服务
systemctl restart reverse-tunnel

# 如果密钥问题，重新配置
ssh-copy-id root@YOUR_VPS_IP
```

---

### 问题 5：Cloudflare Tunnel 无法访问

**症状：**
访问 `https://pve.example.com` 返回 502 或超时

**排查步骤：**

1. 检查 cloudflared 服务
```bash
systemctl status cloudflared
```

2. 查看日志
```bash
journalctl -u cloudflared -n 50
```

3. 检查本地服务
```bash
curl http://localhost:8080
```

4. 在 Cloudflare Dashboard 检查 Tunnel 状态

**解决方案：**

```bash
# 重启 cloudflared
systemctl restart cloudflared

# 检查配置
cat /etc/cloudflared/config.yml

# 如果配置错误，重新安装
# 从 Cloudflare Dashboard 获取新的安装命令
```

---

## 维护手册

### 日常检查命令

```bash
# 检查所有关键服务
systemctl status xray-client privoxy reverse-tunnel cloudflared

# 检查端口监听
ss -tlnp | grep -E '10808|8118|8080'

# 测试网络功能
curl -x socks5://127.0.0.1:10808 -I https://www.google.com
curl -x http://127.0.0.1:8118 -I https://www.google.com
git ls-remote https://github.com/torvalds/linux.git HEAD
```

### 查看日志

```bash
# Xray 客户端日志
journalctl -u xray-client -f

# Privoxy 日志
journalctl -u privoxy -f

# SSH 隧道日志
journalctl -u reverse-tunnel -f

# Cloudflare Tunnel 日志
journalctl -u cloudflared -f

# Docker 日志
journalctl -u docker -f
```

### 重启服务

```bash
# 重启 Xray（如果代理失效）
systemctl restart xray-client

# 重启 Privoxy（如果 HTTP 代理失效）
systemctl restart privoxy

# 重启 SSH 隧道（如果无法从外网访问）
systemctl restart reverse-tunnel

# 重启 Cloudflare Tunnel
systemctl restart cloudflared

# 重启 Docker（修改代理配置后）
systemctl daemon-reload
systemctl restart docker
```

### 更新配置

#### 修改 Xray 配置

```bash
# 编辑配置文件
nano /etc/xray-client-443-final.json

# 重启服务
systemctl restart xray-client

# 验证
systemctl status xray-client
```

#### 修改 Docker 代理

```bash
# 编辑配置
nano /etc/systemd/system/docker.service.d/http-proxy.conf

# 重载并重启
systemctl daemon-reload
systemctl restart docker

# 验证
docker info | grep -A 3 'HTTP Proxy'
```

### 备份关键配置

```bash
# 创建备份目录
mkdir -p /root/backup

# 备份 Xray 配置
cp /etc/xray-client-443-final.json /root/backup/

# 备份 systemd 服务文件
cp /etc/systemd/system/xray-client.service /root/backup/
cp /etc/systemd/system/reverse-tunnel.service /root/backup/

# 备份 Docker 代理配置
cp -r /etc/systemd/system/docker.service.d /root/backup/

# 备份 Git 配置
git config --global --list > /root/backup/git-config.txt

# 备份 Shell 配置
cp ~/.bashrc /root/backup/
```

### 性能监控

```bash
# 查看 Xray 进程资源使用
ps aux | grep xray

# 查看网络连接
ss -tunap | grep -E '10808|8118'

# 测试代理速度
curl -x socks5://127.0.0.1:10808 -o /dev/null -s -w '%{time_total}\n' https://www.google.com

# 查看系统资源
htop
```

### 安全建议

1. **定期更新系统**
```bash
apt-get update && apt-get upgrade -y
```

2. **修改 3x-ui 默认密码**
   - 登录 http://VPS_IP:2053
   - 修改 admin 密码

3. **配置防火墙规则**
```bash
# 只允许特定 IP 访问 3x-ui 面板
iptables -A INPUT -p tcp --dport 2053 -s YOUR_IP -j ACCEPT
iptables -A INPUT -p tcp --dport 2053 -j DROP
```

4. **启用 Fail2ban**（VPS）
```bash
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban
```

5. **定期检查日志**
```bash
# 查看异常连接
journalctl -u xray-client | grep -i error
journalctl -u reverse-tunnel | grep -i error
```

---

## 快速参考

### 配置文件位置

| 服务 | 配置文件路径 |
|------|-------------|
| Xray 客户端 | `/etc/xray-client-443-final.json` |
| Xray 服务 | `/etc/systemd/system/xray-client.service` |
| Privoxy | `/etc/privoxy/config` |
| SSH 隧道 | `/etc/systemd/system/reverse-tunnel.service` |
| Docker 代理 | `/etc/systemd/system/docker.service.d/http-proxy.conf` |
| Git 配置 | `~/.gitconfig` |
| Shell 环境 | `~/.bashrc` |
| Proxychains | `/etc/proxychains4.conf` |

### 常用端口

| 端口 | 用途 |
|------|------|
| 10808 | Xray SOCKS5 代理 |
| 8118 | Privoxy HTTP 代理 |
| 8080 | 本地 Web 服务 |
| 8081 | Nginx HTTP 代理 (Cloudflare Tunnel) |
| 8443 | Nginx HTTPS 代理 (局域网访问) |
| 18080 | SSH 隧道远程端口 |
| 443 | VLESS Reality 端口 (VPS) |
| 2053 | 3x-ui 管理面板 (VPS) |

### 快捷命令别名

```bash
# 代理管理
proxy-status  # 查看代理状态
proxy-on      # 启用环境变量代理
proxy-off     # 禁用环境变量代理

# 服务管理
alias xray-status='systemctl status xray-client'
alias xray-restart='systemctl restart xray-client'
alias tunnel-status='systemctl status reverse-tunnel'
alias tunnel-restart='systemctl restart reverse-tunnel'
alias cf-status='systemctl status cloudflared'
alias cf-restart='systemctl restart cloudflared'

# 测试命令
alias test-proxy='curl -x socks5://127.0.0.1:10808 -I https://www.google.com'
alias test-http='curl -x http://127.0.0.1:8118 -I https://www.google.com'
alias test-git='git ls-remote https://github.com/torvalds/linux.git HEAD'
```

---

## 高级功能

### 功能 1：HTTPS 证书配置

#### 1.1 使用 Let's Encrypt + Cloudflare DNS-01

自动申请和配置 Let's Encrypt 证书，支持自动续期。

**运行配置脚本：**

```bash
bash setup-https-cert.sh
```

**脚本功能：**
- ✅ 自动安装 acme.sh
- ✅ 使用 Cloudflare API Token 进行 DNS-01 验证
- ✅ 申请 ECC 256 位证书（更安全、更快）
- ✅ 自动配置证书续期（60 天前自动续期）
- ✅ 证书更新后自动重载 Nginx

**所需信息：**
- 域名（如 subdomain.yourdomain.com）
- 根域名（如 yourdomain.com）
- Cloudflare API Token（需要 Zone:DNS:Edit 权限）
- 证书保存目录（默认 /home/web/certs）
- 联系邮箱

**证书路径：**
- 证书文件：`/home/web/certs/subdomain.yourdomain.com_cert.pem`
- 私钥文件：`/home/web/certs/subdomain.yourdomain.com_key.pem`
- 完整链：`/home/web/certs/subdomain.yourdomain.com_fullchain.pem`

**手动续期命令：**
```bash
~/.acme.sh/acme.sh --renew -d subdomain.yourdomain.com --ecc --force
```

**查看证书信息：**
```bash
openssl x509 -in /home/web/certs/subdomain.yourdomain.com_cert.pem -noout -text
```

---

### 功能 2：Nginx HTTPS 配置

#### 2.1 HTTP + HTTPS 双栈代理

Nginx 同时提供 HTTP 和 HTTPS 访问，支持：
- **HTTP (8081)**：Cloudflare Tunnel 使用
- **HTTPS (8443)**：局域网直接 HTTPS 访问

**配置文件：** `/etc/nginx/sites-available/origin-fix-https`

**功能特性：**
- ✅ 修改 Origin 和 Referer 头避免校验失败
- ✅ WebSocket 支持
- ✅ 完整的 SSL/TLS 配置（TLSv1.2 + TLSv1.3）
- ✅ OOM 保护（防止系统杀掉 Nginx）
- ✅ 自动重启（服务异常自动恢复）

**访问方式：**
- 外网：https://subdomain.yourdomain.com（通过 Cloudflare Tunnel）
- 局域网：https://YOUR_INTERNAL_IP:8443（直接 HTTPS）

**测试命令：**
```bash
# 测试 HTTP 端口
curl -I http://127.0.0.1:8081

# 测试 HTTPS 端口
curl -k -I https://127.0.0.1:8443
curl -k -I https://YOUR_INTERNAL_IP:8443
```

#### 2.2 Nginx 稳定性配置

**OOM 保护配置：** `/etc/systemd/system/nginx.service.d/oom-protect.conf`

```ini
[Service]
# 防止 OOM Killer 杀掉 Nginx
OOMScoreAdjust=-900
# 异常时自动重启
Restart=always
RestartSec=5
```

**应用配置：**
```bash
systemctl daemon-reload
systemctl restart nginx
```

---

### 功能 3：PVE 防火墙配置

#### 3.1 配置防火墙规则

Proxmox VE 有自己的防火墙系统，需要单独配置。

**运行配置脚本：**

```bash
bash setup-pve-firewall.sh
```

**脚本功能：**
- ✅ 自动检测 PVE 系统
- ✅ 备份现有防火墙配置
- ✅ 添加端口规则到 management IP 集合
- ✅ 自动重启防火墙服务
- ✅ 验证配置是否生效

**默认开放端口：**
- 8080（Web 应用）
- 8081（Nginx HTTP）
- 8443（Nginx HTTPS）

#### 3.2 手动配置防火墙

**主机防火墙配置：** `/etc/pve/nodes/<hostname>/host.fw`

```ini
[OPTIONS]

enable: 1

[RULES]

IN ACCEPT -p icmp
IN SSH(ACCEPT) -source +management
IN ACCEPT -p tcp -dport 8006 -source +management
IN ACCEPT -p tcp -dport 3128 -source +management
IN ACCEPT -p tcp -dport 8080 -source +management
IN ACCEPT -p tcp -dport 8081 -source +management
IN ACCEPT -p tcp -dport 8443 -source +management
```

**配置 management IP 集合：** `/etc/pve/firewall/cluster.fw`

```ini
[OPTIONS]

enable: 1
policy_in: DROP
policy_out: ACCEPT

[IPSET management]

192.168.1.0/24
192.168.3.0/24
192.168.4.2
192.168.5.0/24
```

**重启防火墙：**
```bash
systemctl restart pve-firewall
```

**验证规则：**
```bash
# 查看 iptables 规则
iptables -L PVEFW-HOST-IN -n -v

# 查看端口监听
ss -tlnp | grep -E '8080|8081|8443'
```

---

### 功能 4：Origin 验证修复增强

#### 4.1 完整的 Origin 修复方案

更新后的 `fix-origin.sh` 脚本支持：
- ✅ 方案 1：修改 hosts 文件
- ✅ 方案 2：配置 NO_PROXY
- ✅ 方案 3：配置 Nginx 反向代理（HTTP + HTTPS）
- ✅ 方案 4：全部应用

**运行脚本：**
```bash
bash fix-origin.sh
```

**新增功能：**
- 同时配置 HTTP 和 HTTPS
- 自动配置 SSL 证书（如果已存在）
- Nginx OOM 保护和自动重启
- 完整的验证和测试

---

## 部署脚本清单

| 脚本 | 用途 | 运行环境 |
|------|------|----------|
| `deploy-vps.sh` | VPS 服务器完整部署 | VPS 服务器 |
| `deploy-client.sh` | 内网客户端完整部署 | 内网服务器 |
| `setup-cloudflare-tunnel.sh` | Cloudflare Tunnel 配置 | 内网服务器 |
| `setup-https-cert.sh` | Let's Encrypt 证书申请 | 内网服务器 |
| `setup-pve-firewall.sh` | PVE 防火墙配置 | PVE 主机 |
| `fix-origin.sh` | Origin 验证修复 | 内网服务器 |
| `diagnose-tunnel.sh` | 快速诊断工具 | 内网服务器 |

---

## 总结

通过本方案，你将获得：

- ✅ **完整的入站解决方案**：Cloudflare Tunnel（主） + SSH 隧道（备）
- ✅ **完整的出站解决方案**：Xray VLESS Reality 代理
- ✅ **全局代理支持**：Docker、Git、apt-get 等自动使用代理
- ✅ **HTTPS 安全访问**：Let's Encrypt 证书 + 自动续期
- ✅ **局域网直连**：HTTPS 端口无证书警告
- ✅ **PVE 防火墙**：自动配置规则，安全可控
- ✅ **开机自启**：所有服务自动启动
- ✅ **高可用性**：服务异常自动重启，OOM 保护
- ✅ **易于维护**：systemd 统一管理，日志完整

如有问题，请参考故障排查章节或查看详细日志。
