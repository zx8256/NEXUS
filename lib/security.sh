#!/bin/bash
# ========================================
# 安全工具函数库
# 提供输入验证、转义、完整性检查等安全功能
# ========================================

# 验证域名格式
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 验证 IP 地址
validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # 验证每个八位组
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# 验证 UUID
validate_uuid() {
    local uuid="$1"
    if [[ ! "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        return 1
    fi
    return 0
}

# 验证文件路径（防止路径遍历）
validate_path() {
    local path="$1"
    local realpath_result

    # 检查是否包含 ..
    if [[ "$path" == *".."* ]]; then
        return 1
    fi

    # 使用 realpath 验证（如果文件存在）
    if [ -e "$path" ]; then
        realpath_result=$(realpath "$path" 2>/dev/null)
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    return 0
}

# 安全地转义字符串用于 Shell 命令
shell_escape() {
    local string="$1"
    printf '%q' "$string"
}

# 验证并下载文件（带完整性检查）
secure_download() {
    local url="$1"
    local output="$2"
    local expected_sha256="$3"  # 可选

    # 使用临时文件
    local tmpfile
    tmpfile=$(mktemp)

    # 下载
    if ! curl -fsSL "$url" -o "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi

    # 如果提供了 SHA256，验证完整性
    if [ -n "$expected_sha256" ]; then
        local actual_sha256
        actual_sha256=$(sha256sum "$tmpfile" | cut -d' ' -f1)

        if [ "$actual_sha256" != "$expected_sha256" ]; then
            rm -f "$tmpfile"
            return 2  # 完整性验证失败
        fi
    fi

    # 移动到目标位置
    mv "$tmpfile" "$output"
    return 0
}

# 过滤日志中的敏感信息
filter_sensitive() {
    local input="$1"

    # 过滤 API Token（格式：cfut_xxxx, sk-xxxx, Bearer xxxx）
    input=$(echo "$input" | sed -E 's/(cfut_|sk-|Bearer )[a-zA-Z0-9_-]{20,}/\1***REDACTED***/g')

    # 过滤密码（password=xxxx, passwd=xxxx）
    input=$(echo "$input" | sed -E 's/(password|passwd|pwd)=[^&[:space:]]+/\1=***REDACTED***/gi')

    # 过滤 UUID（可能是 API key）
    input=$(echo "$input" | sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/***UUID-REDACTED***/gi')

    echo "$input"
}

# 安全地读取敏感输入（不回显）
read_sensitive() {
    local prompt="$1"
    local varname="$2"

    read -r -s -p "$prompt" "$varname"
    echo ""  # 换行
}

# 验证 Cloudflare API Token 格式
validate_cloudflare_token() {
    local token="$1"

    # Cloudflare Token 格式：cfut_ 开头，后跟40个字符
    if [[ ! "$token" =~ ^cfut_[a-zA-Z0-9_-]{40,}$ ]]; then
        return 1
    fi
    return 0
}

# 创建安全的临时目录
secure_mktemp() {
    local tmpdir
    tmpdir=$(mktemp -d)
    chmod 700 "$tmpdir"
    echo "$tmpdir"
}

# 安全地创建配置文件（restrictive permissions）
secure_write_config() {
    local file="$1"
    local content="$2"

    # 使用临时文件
    local tmpfile
    tmpfile=$(mktemp)

    # 写入内容
    echo "$content" > "$tmpfile"

    # 设置权限为 600（仅所有者可读写）
    chmod 600 "$tmpfile"

    # 移动到目标位置
    mv "$tmpfile" "$file"

    # 确保权限正确
    chmod 600 "$file"
}

# 验证命令是否安全（白名单）
validate_command() {
    local cmd="$1"

    # 提取命令名称
    local cmd_name
    cmd_name=$(echo "$cmd" | awk '{print $1}')

    # 白名单命令
    local safe_commands=(
        "systemctl"
        "cloudflared"
        "curl"
        "wget"
        "git"
        "docker"
        "apt-get"
        "nginx"
        "cat"
        "echo"
        "grep"
        "sed"
        "awk"
    )

    for safe_cmd in "${safe_commands[@]}"; do
        if [ "$cmd_name" = "$safe_cmd" ]; then
            return 0
        fi
    done

    return 1
}

# 备份配置文件
backup_config() {
    local file="$1"
    local backup_dir="${2:-/var/backups/network-proxy}"

    if [ ! -f "$file" ]; then
        return 1
    fi

    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/$(basename "$file").backup.$timestamp"

    cp -a "$file" "$backup_file"
    echo "$backup_file"
}

# 原子性写入文件（先写临时文件再 mv）
atomic_write() {
    local target="$1"
    local content="$2"

    local tmpfile
    tmpfile=$(mktemp)

    echo "$content" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }

    mv "$tmpfile" "$target" || {
        rm -f "$tmpfile"
        return 1
    }

    return 0
}
