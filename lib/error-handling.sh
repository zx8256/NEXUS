#!/bin/bash
# ========================================
# 错误处理和回滚函数库
# ========================================

# 全局变量
BACKUP_DIR="/var/backups/network-proxy"
ROLLBACK_STACK=()

# 初始化错误处理
init_error_handling() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    # 设置错误陷阱
    trap 'error_handler $? $LINENO' ERR
    trap 'cleanup_handler' EXIT
}

# 错误处理器
error_handler() {
    local exit_code=$1
    local line_number=$2

    log_error "脚本在第 $line_number 行失败，退出码: $exit_code"
    log_error "开始回滚操作..."

    rollback_all

    exit $exit_code
}

# 清理处理器
cleanup_handler() {
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_info "脚本执行成功"
        # 清理超过7天的备份
        find "$BACKUP_DIR" -type f -mtime +7 -delete 2>/dev/null || true
    else
        log_error "脚本执行失败，备份保留在: $BACKUP_DIR"
    fi
}

# 备份文件并记录到回滚栈
backup_and_track() {
    local file="$1"
    local description="${2:-备份文件}"

    if [ ! -e "$file" ]; then
        log_warn "文件不存在，跳过备份: $file"
        return 0
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/$(basename "$file").backup.$timestamp"

    if cp -a "$file" "$backup_file"; then
        log_info "✓ 已备份: $file → $backup_file"
        ROLLBACK_STACK+=("restore:$backup_file:$file:$description")
        echo "$backup_file"
        return 0
    else
        log_error "备份失败: $file"
        return 1
    fi
}

# 备份并修改文件
safe_modify_file() {
    local file="$1"
    local content="$2"
    local description="${3:-修改文件}"

    # 备份原文件
    backup_and_track "$file" "$description"

    # 写入新内容
    if echo "$content" > "$file"; then
        log_info "✓ 已修改: $file"
        return 0
    else
        log_error "修改失败: $file"
        rollback_last
        return 1
    fi
}

# 安全创建文件
safe_create_file() {
    local file="$1"
    local content="$2"
    local description="${3:-创建文件}"

    if [ -e "$file" ]; then
        log_error "文件已存在: $file"
        return 1
    fi

    # 写入内容
    if echo "$content" > "$file"; then
        log_info "✓ 已创建: $file"
        ROLLBACK_STACK+=("delete:$file:$description")
        return 0
    else
        log_error "创建失败: $file"
        return 1
    fi
}

# 安全创建符号链接
safe_create_link() {
    local target="$1"
    local link="$2"
    local description="${3:-创建符号链接}"

    if [ -L "$link" ]; then
        # 备份现有链接
        backup_and_track "$link" "$description"
    fi

    if ln -sf "$target" "$link"; then
        log_info "✓ 已创建符号链接: $link → $target"
        return 0
    else
        log_error "创建符号链接失败: $link"
        return 1
    fi
}

# 回滚最后一个操作
rollback_last() {
    if [ ${#ROLLBACK_STACK[@]} -eq 0 ]; then
        log_warn "回滚栈为空，无需回滚"
        return 0
    fi

    local operation="${ROLLBACK_STACK[-1]}"
    unset 'ROLLBACK_STACK[-1]'

    execute_rollback "$operation"
}

# 回滚所有操作
rollback_all() {
    log_warn "开始回滚所有操作 (${#ROLLBACK_STACK[@]} 项)"

    # 从后往前回滚
    for ((i=${#ROLLBACK_STACK[@]}-1; i>=0; i--)); do
        execute_rollback "${ROLLBACK_STACK[$i]}"
    done

    ROLLBACK_STACK=()
}

# 执行回滚操作
execute_rollback() {
    local operation="$1"

    IFS=':' read -r action arg1 arg2 description <<< "$operation"

    case "$action" in
        restore)
            local backup_file="$arg1"
            local target_file="$arg2"
            if [ -f "$backup_file" ]; then
                cp -a "$backup_file" "$target_file"
                log_info "✓ 已回滚: $target_file (从 $backup_file)"
            else
                log_error "回滚失败: 备份文件不存在 $backup_file"
            fi
            ;;
        delete)
            local file="$arg1"
            if [ -e "$file" ]; then
                rm -f "$file"
                log_info "✓ 已删除: $file"
            fi
            ;;
        *)
            log_error "未知的回滚操作: $action"
            ;;
    esac
}

# 验证配置文件
validate_config() {
    local config_file="$1"
    local validator="$2"

    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi

    # 执行验证器
    if $validator "$config_file"; then
        log_info "✓ 配置验证通过: $config_file"
        return 0
    else
        log_error "配置验证失败: $config_file"
        return 1
    fi
}

# Nginx 配置验证器
validate_nginx_config() {
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

# systemd 服务配置验证器
validate_systemd_service() {
    local service="$1"
    systemctl daemon-reload
    systemctl cat "$service" > /dev/null 2>&1
    return $?
}

# 安全重启服务
safe_restart_service() {
    local service="$1"
    local description="${2:-重启服务}"

    log_info "准备重启服务: $service"

    # 检查服务是否存在
    if ! systemctl list-unit-files | grep -q "^$service"; then
        log_error "服务不存在: $service"
        return 1
    fi

    # 检查当前状态
    local was_active=false
    if systemctl is-active --quiet "$service"; then
        was_active=true
    fi

    # 重启服务
    if systemctl restart "$service"; then
        log_info "✓ 服务重启成功: $service"

        # 等待服务稳定
        sleep 3

        # 验证服务状态
        if systemctl is-active --quiet "$service"; then
            log_info "✓ 服务运行正常: $service"
            return 0
        else
            log_error "服务重启后未正常运行: $service"

            # 如果之前未运行，不算失败
            if [ "$was_active" = false ]; then
                log_warn "服务之前也未运行，可能需要手动配置"
                return 0
            fi

            return 1
        fi
    else
        log_error "服务重启失败: $service"
        return 1
    fi
}

# 显示回滚栈
show_rollback_stack() {
    if [ ${#ROLLBACK_STACK[@]} -eq 0 ]; then
        echo "回滚栈为空"
        return
    fi

    echo "当前回滚栈 (${#ROLLBACK_STACK[@]} 项):"
    for operation in "${ROLLBACK_STACK[@]}"; do
        IFS=':' read -r action arg1 arg2 description <<< "$operation"
        echo "  - $description ($action)"
    done
}
