#!/bin/bash
# 清理敏感信息脚本

# 定义替换规则
declare -A REPLACEMENTS=(
    ["YOUR_VPS_IP_PLACEHOLDER"]="YOUR_VPS_IP"
    ["YOUR_INTERNAL_IP_PLACEHOLDER"]="YOUR_INTERNAL_IP"
    ["YOUR_DOMAIN_PLACEHOLDER"]="yourdomain.com"
    ["YOUR_SUBDOMAIN_PLACEHOLDER"]="subdomain.yourdomain.com"
    ["YOUR_TOKEN_PLACEHOLDER"]="YOUR_CLOUDFLARE_API_TOKEN"
)

# 需要清理的文件列表
FILES=(
    "README.md"
    "skill.md"
    "diagnose-tunnel.sh"
    "fix-origin-validation.md"
    "fix-origin.sh"
    "setup-https-cert.sh"
    "lib/security.sh"
    "SECURITY-AUDIT-REPORT.md"
)

echo "开始清理敏感信息..."

for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "跳过不存在的文件: $file"
        continue
    fi

    echo "处理: $file"

    # 对每个文件执行所有替换
    for key in "${!REPLACEMENTS[@]}"; do
        value="${REPLACEMENTS[$key]}"
        sed -i "s|$key|$value|g" "$file"
    done
done

echo "✓ 敏感信息清理完成！"
