#!/bin/bash

# Linux Swap 一键设置脚本
# 支持交换分区和交换文件两种方式
# 适用于所有Linux系统和虚拟环境(KVM, LXC 等)
#
# ==========================================
# ==      Author: Cloudream Innovation    ==
# ==      版本: 1.6.3                     ==
# ==========================================
#

set -euo pipefail # 发生错误时立即退出, 未定义变量视为错误, 管道中命令失败则整个管道失败

# --- 颜色定义 ---
RED='\033[0;31m'        # 红色
GREEN='\033[0;32m'      # 绿色
YELLOW='\033[1;33m'     # 黄色
BLUE='\033[0;34m'       # 蓝色
MAGENTA='\033[0;35m'    # 洋红色
CYAN='\033[0;36m'       # 青色
NC='\033[0m'            # 无颜色 (恢复默认)

# --- 全局变量 ---
SCRIPT_NAME="$(basename "$0")"                          # 脚本名称
LOG_FILE=""                                             # 日志文件路径, 将由 mktemp 初始化
SWAP_FILE_DEFAULT="/swapfile"                           # 默认交换文件路径
AUTHOR_NAME="Cloudream Innovation"                      # 作者名称
MAX_FSTAB_BACKUPS=5                                     # 保留的fstab最大备份数量

BACKUP_FSTAB_DIR_PREFERRED="/var/backups"               # fstab 首选备份目录
BACKUP_FSTAB_DIR_FALLBACK="/etc"                        # fstab 备用备份目录
ACTUAL_BACKUP_FSTAB_BASE=""                             # 实际使用的fstab备份文件名前缀 (路径+fstab.bak)
SYSCTL_SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness.conf" # Swappiness 配置文件路径

# --- 标志位 ---
VERBOSE=0               # 是否启用详细输出模式 (0: 否, 1: 是)
IS_CONTAINER_ENV=0      # 是否为容器环境 (例如 OpenVZ, LXC)
IS_INTERACTIVE_MODE=0   # 标记是否为交互模式

# --- 日志函数 ---
# 记录普通日志
log() {
    # 确保LOG_FILE已设置
    if [[ -n "$LOG_FILE" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    else
        # 如果LOG_FILE未设置 (例如mktemp失败后)，则输出到stderr
        echo "$(date '+%Y-%m-%d %H:%M:%S') - LOG_FILE_NOT_SET - $1" >&2
    fi
}

# 记录并显示错误信息 (红色)
log_error() {
    echo -e "${RED}错误: $1${NC}" >&2 # 输出到标准错误
    log "ERROR: $1"
}

# 记录并显示警告信息 (黄色)
log_warning() {
    echo -e "${YELLOW}警告: $1${NC}" >&2 # 输出到标准错误
    log "WARNING: $1"
}

# 记录并显示参考信息 (蓝色, 仅在详细模式下显示)
log_info() {
    if [[ "${VERBOSE:-0}" == "1" ]]; then
        echo -e "${BLUE}信息: $1${NC}"
    fi
    log "INFO: $1"
}

# 记录并显示成功信息 (绿色)
log_success() {
    echo -e "${GREEN}成功: $1${NC}"
    log "SUCCESS: $1"
}

# --- 错误处理与退出 ---
error_exit() {
    log_error "$1"
    # 检查LOG_FILE是否已成功创建
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        echo -e "\n${RED}脚本执行失败。详细错误信息请查看日志文件: ${CYAN}$LOG_FILE${NC}"
    else
        echo -e "\n${RED}脚本执行失败。无法写入日志文件。${NC}"
    fi
    exit 1
}

# --- 清理函数 (脚本退出时执行) ---
cleanup() {
    # 如果日志文件为空 (例如脚本因参数错误早期退出), 则删除日志文件
    # 并且确保LOG_FILE变量不为空且确实是一个文件
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" && ! -s "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
    fi
}
trap cleanup EXIT # 注册 cleanup 函数在脚本退出时执行

# --- 辅助函数 ---
# 初始化并确定fstab备份目录
initialize_fstab_backup_location() {
    if [[ -d "$BACKUP_FSTAB_DIR_PREFERRED" && -w "$BACKUP_FSTAB_DIR_PREFERRED" ]]; then
        ACTUAL_BACKUP_FSTAB_BASE="${BACKUP_FSTAB_DIR_PREFERRED}/fstab.bak"
        log_info "fstab备份将存储在首选目录: $BACKUP_FSTAB_DIR_PREFERRED"
    else
        log_warning "首选fstab备份目录 '$BACKUP_FSTAB_DIR_PREFERRED' 不存在或不可写。"
        if [[ -d "$BACKUP_FSTAB_DIR_FALLBACK" && -w "$BACKUP_FSTAB_DIR_FALLBACK" ]]; then
            ACTUAL_BACKUP_FSTAB_BASE="${BACKUP_FSTAB_DIR_FALLBACK}/fstab.bak"
            log_warning "fstab备份将存储在备用目录: $BACKUP_FSTAB_DIR_FALLBACK"
        else
            log_error "首选和备用fstab备份目录均不可用。fstab备份功能将受限！"
            ACTUAL_BACKUP_FSTAB_BASE="" # 表示备份可能失败
        fi
    fi
}


# 获取唯一的 fstab 备份文件名
get_backup_fstab_name() {
    if [[ -n "$ACTUAL_BACKUP_FSTAB_BASE" ]]; then
        echo "${ACTUAL_BACKUP_FSTAB_BASE}.$(date +%Y%m%d_%H%M%S)"
    else
        echo ""
    fi
}

# 清理旧的fstab备份文件
cleanup_old_fstab_backups() {
    if [[ -z "$ACTUAL_BACKUP_FSTAB_BASE" ]]; then
        log_warning "由于fstab备份目录未正确设置，跳过清理旧备份。"
        return
    fi

    local backup_dir
    backup_dir=$(dirname "$ACTUAL_BACKUP_FSTAB_BASE")
    local backup_prefix
    backup_prefix=$(basename "$ACTUAL_BACKUP_FSTAB_BASE")

    find "$backup_dir" -maxdepth 1 -name "${backup_prefix}.*" -printf '%T@ %p\n' 2>/dev/null | \
        sort -nr | \
        awk '{print $2}' | \
        tail -n +$((MAX_FSTAB_BACKUPS + 1)) | \
        while IFS= read -r old_backup; do
            if [[ -f "$old_backup" ]]; then
                log_info "清理旧的fstab备份: $old_backup"
                rm -f "$old_backup" || log_warning "删除旧备份 '$old_backup' 失败。"
            fi
        done
}


# 打印分隔线
print_separator() {
    echo "----------------------------------------------------------------------"
}

# 打印主标题
print_main_title() {
    echo
    echo -e "${MAGENTA}======================================================================${NC}"
    echo -e "${MAGENTA}==${NC}      ${CYAN}Linux Swap 智能设置脚本 (v1.6.3)${NC}      ${MAGENTA}==${NC}"
    echo -e "${MAGENTA}==${NC}                  ${YELLOW}作者: ${AUTHOR_NAME}${NC}                   ${MAGENTA}==${NC}"
    echo -e "${MAGENTA}======================================================================${NC}"
    echo
}

# 封装确认对话框
# 参数1: 提示信息字符串
# 返回值: 0 表示确认 (yes), 1 表示取消 (no/其他)
prompt_for_confirmation() {
    local prompt_message="$1"
    local confirm_input
    read -p $'\e[1;33m'"${prompt_message} (y/N): "$'\e[0m' -r confirm_input
    if [[ "$confirm_input" =~ ^[Yy是]$ ]]; then
        return 0 # 确认
    else
        echo "操作已取消。" # 统一的取消信息
        return 1 # 取消
    fi
}


# --- 环境检查 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要root权限运行。请尝试使用: sudo $0"
    fi
    log_info "Root权限检查通过。"
}

prompt_to_install_dependency() {
    local cmd_missing="$1"
    declare -A CMD_TO_PKG_MAP
    CMD_TO_PKG_MAP=(
        [file]="file"
        [fdisk]="util-linux"
        [lsblk]="util-linux"
        [fallocate]="util-linux"
        [blkid]="util-linux"
        [mkswap]="util-linux"
        [swapon]="util-linux"
        [swapoff]="util-linux"
        [sysctl]="procps"
    )

    local pkg_name="${CMD_TO_PKG_MAP[$cmd_missing]:-}"
    if [[ -z "$pkg_name" ]]; then
        pkg_name="$cmd_missing"
        log_info "无法从内部映射找到 '$cmd_missing' 的包名，将尝试使用 '$cmd_missing' 作为包名进行安装。"
    fi

    local pkg_manager=""
    local install_cmd=""
    local update_cmd=""

    if command -v apt-get &>/dev/null; then
        pkg_manager="apt"
        update_cmd="sudo apt-get update"
        install_cmd="sudo apt-get install -y"
        if [[ "$cmd_missing" == "fdisk" && ! -f /usr/sbin/fdisk && -f /sbin/fdisk ]]; then
             pkg_name="fdisk"
        elif [[ "$cmd_missing" == "sysctl" ]]; then
             pkg_name="procps"
        fi
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        install_cmd="sudo dnf install -y"
        if [[ "$cmd_missing" == "sysctl" ]]; then
             pkg_name="procps-ng"
        fi
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        install_cmd="sudo yum install -y"
        if [[ "$cmd_missing" == "sysctl" ]]; then
             pkg_name="procps-ng"
        fi
    else
        error_exit "缺少必要命令 '$cmd_missing'。未检测到 apt, dnf 或 yum 包管理器，无法自动安装。请手动安装。"
    fi

    log_warning "必要命令 '$cmd_missing' 未找到。"

    if prompt_for_confirmation "脚本需要此命令才能继续。它似乎由软件包 \"$pkg_name\" 提供。是否现在自动安装它?"; then
        log_info "用户同意安装软件包 '$pkg_name'。"
        echo -e "${BLUE}正在准备安装 '$pkg_name'...${NC}"

        if [[ "$pkg_manager" == "apt" && -n "$update_cmd" ]]; then
            log_info "正在执行: $update_cmd"
            if ! $update_cmd &>> "$LOG_FILE"; then
                log_warning "执行 '$update_cmd' 失败，但这可能不影响安装。继续尝试..."
            fi
        fi

        log_info "正在执行: $install_cmd $pkg_name"
        echo -e "${BLUE}执行安装命令: ${CYAN}$install_cmd $pkg_name${NC}"
        if ! $install_cmd "$pkg_name" &>> "$LOG_FILE"; then
            error_exit "安装软件包 '$pkg_name' 失败。请检查日志 '$LOG_FILE' 并尝试手动安装。"
        fi
        log_success "软件包 '$pkg_name' 安装成功。"

        if ! command -v "$cmd_missing" &> /dev/null; then
             error_exit "已安装软件包 '$pkg_name'，但命令 '$cmd_missing' 仍然不可用。可能存在路径问题或安装异常。"
        fi
    else
        error_exit "缺少必要命令 '$cmd_missing' 且用户选择不安装。"
    fi
}

check_environment() {
    local required_commands=("swapon" "swapoff" "mkswap" "free" "df" "awk" "sed" "grep" "file" "blkid" "tail" "dirname" "readlink" "mktemp" "mv" "cp" "rm" "chmod" "dd" "sysctl")

    if ! command -v fdisk &> /dev/null && ! command -v lsblk &> /dev/null; then
        log_error "缺少必要的磁盘查看命令: fdisk 或 lsblk 未找到。"
        prompt_to_install_dependency "lsblk"
    fi

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            prompt_to_install_dependency "$cmd"
        fi
    done
    log_info "所有必要命令检查完毕。"

    local virt_type=""
    if command -v systemd-detect-virt &>/dev/null && [[ $(systemd-detect-virt) != "none" ]]; then
        virt_type=$(systemd-detect-virt)
    elif [[ -f /proc/vz/version ]]; then
        virt_type="openvz"
    elif [[ -d /proc/xen ]]; then
        virt_type="xen"
    elif grep -qi "hypervisor" /proc/cpuinfo 2>/dev/null; then
        if dmesg | grep -qi "KVM" 2>/dev/null; then
            virt_type="kvm"
        elif dmesg | grep -qi "VMware" 2>/dev/null; then
            virt_type="vmware"
        elif dmesg | grep -qi "Hyper-V" 2>/dev/null || dmesg | grep -qi "hv_storvsc" 2>/dev/null; then
            virt_type="hyper-v"
        else
            virt_type="Unknown Hypervisor (from /proc/cpuinfo & dmesg)"
        fi
    fi

    if [[ -n "$virt_type" ]]; then
        log_info "检测到虚拟化环境: $virt_type"
        if [[ "$virt_type" == "openvz" || "$virt_type" == "lxc" ]]; then
            IS_CONTAINER_ENV=1
            log_warning "检测到 ${virt_type} 容器环境。在此类环境中创建或管理Swap可能受到宿主机限制或不被支持。"
        fi
    else
        log_info "当前可能为物理机或未识别的虚拟化环境。"
    fi
}

# --- Swap 信息获取与显示 ---
get_current_swap() {
    echo "--- 当前系统Swap信息 ---"
    if command -v free &>/dev/null; then
        free -h | grep -E "^Mem:|^Swap:" || free -m | grep -E "^Mem:|^Swap:"
    else
        log_warning "无法使用 'free' 命令显示内存和Swap使用情况。"
    fi
    echo

    if swapon --show NAME,TYPE,SIZE,USED,PRIO 2>/dev/null | grep -q .; then
        echo "当前活动的Swap设备 (名称, 类型, 大小, 已用, 优先级):"
        swapon --show NAME,TYPE,SIZE,USED,PRIO
    else
        echo "当前没有活动的Swap。"
    fi
    print_separator
}

show_disk_info() {
    echo "--- 可用磁盘分区信息 (已挂载) ---"
    df -hT | head -1
    df -hT | grep -E "^/dev/" | grep -vE "(tmpfs|squashfs|iso9660|udf)"
    echo

    echo "--- 可用块设备信息 (分区与磁盘) ---"
    if command -v lsblk &> /dev/null; then
        lsblk -fpno NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL,UUID,ROTA | grep -vE "(rom|loop)"
    elif command -v fdisk &> /dev/null; then
        log_info "'lsblk' 未找到，尝试使用 'sudo fdisk -l'。"
        sudo fdisk -l 2>/dev/null | grep -E "^Disk /dev/|^/dev/" | head -n 15
    else
        log_warning "'lsblk' 和 'fdisk' 命令均未找到，无法显示详细块设备信息。"
    fi
    print_separator
}

# --- 输入验证 ---
validate_size() {
    local size_input="$1"
    local size_mb

    if [[ ! "$size_input" =~ ^[0-9]+([MmGgTt])?$ ]]; then
        log_error "无效的大小格式: '$size_input'。请使用如 512M, 2G, 1024 (默认视为MB)。"
        return 1
    fi

    local num="${size_input//[^0-9]/}"
    local unit="${size_input//[0-9]/}"
    unit=$(echo "$unit" | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        G|GT) size_mb=$((num * 1024)) ;;
        T|TT) size_mb=$((num * 1024 * 1024)) ;;
        M|MB) size_mb="$num" ;;
        "")   size_mb="$num" ;;
        *)
            log_error "无法识别的大小单位: '$unit' (来自输入 '$size_input')。"
            return 1
            ;;
    esac

    if [[ $size_mb -lt 64 ]]; then
        log_error "Swap大小 ($size_mb MB) 不能小于 64MB。"
        return 1
    fi

    if [[ $size_mb -gt $((32 * 1024)) ]]; then
        log_warning "Swap大小 ($size_mb MB) 已超过 32GB。对于多数系统可能不是最佳选择，请确认需求。"
    fi

    echo "$size_mb"
    return 0
}

check_disk_space() {
    local required_mb="$1"
    local mount_point="${2:-/}"

    local available_kb
    available_kb=$(df -Pk "$mount_point" | awk 'FNR == 2 {print $4}')
    if [[ -z "$available_kb" || ! "$available_kb" =~ ^[0-9]+$ ]]; then
        error_exit "无法获取挂载点 '$mount_point' 的可用磁盘空间。"
    fi
    local available_mb=$((available_kb / 1024))

    local buffer_mb=$((required_mb / 20))
    [[ "$buffer_mb" -lt 100 ]] && buffer_mb=100

    local total_needed_mb=$((required_mb + buffer_mb))
    if [[ $available_mb -lt $total_needed_mb ]]; then
        error_exit "磁盘空间不足。在 '$mount_point' 上创建Swap需约 ${required_mb}MB (加缓冲 ${buffer_mb}MB, 共 ${total_needed_mb}MB), 当前仅 ${available_mb}MB 可用。"
    fi

    log_info "磁盘空间检查通过: 在 '$mount_point' 上需要 ${required_mb}MB (总计 ${total_needed_mb}MB 包含缓冲)，可用 ${available_mb}MB。"
}

# --- Swappiness 配置 ---
configure_swappiness() {
    log_info "开始配置 vm.swappiness。"
    local current_swappiness
    current_swappiness=$(sysctl -n vm.swappiness 2>/dev/null)
    if [[ -z "$current_swappiness" ]]; then
        log_warning "无法获取当前的 vm.swappiness 值。"
        current_swappiness="未知"
    fi

    echo "--- 配置内核交换倾向 (vm.swappiness) ---"
    echo "vm.swappiness 控制系统将内存数据交换到磁盘的积极程度 (0-100)。"
    echo -e "当前值: ${YELLOW}${current_swappiness}${NC}"

    local suggested_swappiness=60
    if lsblk -d -o name,rota --noheadings 2>/dev/null | grep -q '0$'; then
        log_info "检测到系统中可能存在SSD。"
        suggested_swappiness=10
        echo -e "检测到系统可能使用SSD，建议将 swappiness 设置为较低的值 (如 ${GREEN}10${NC}) 以减少写入，延长寿命。"
    else
        log_info "未明确检测到SSD，或lsblk不可用。默认建议值为60。"
        echo -e "对于传统HDD硬盘，通常建议值为 ${GREEN}60${NC}。"
    fi

    read -p $"请输入新的 swappiness 值 (0-100) [按回车使用建议值 ${suggested_swappiness}, 或输入 'skip' 跳过]: " -r new_swappiness_input

    if [[ "$new_swappiness_input" =~ ^[Ss][Kk][Ii][Pp]$ || ( -z "$new_swappiness_input" && "$current_swappiness" == "$suggested_swappiness" ) ]]; then
        if [[ "$new_swappiness_input" =~ ^[Ss][Kk][Ii][Pp]$ ]]; then
            log_info "用户选择跳过 swappiness 配置。"
            echo "已跳过 swappiness 配置。"
        else
            log_info "用户选择保留当前建议的 swappiness 值: $suggested_swappiness。"
            echo "Swappiness 值未改变。"
        fi
        return 0
    fi

    new_swappiness_input="${new_swappiness_input:-$suggested_swappiness}"

    if ! [[ "$new_swappiness_input" =~ ^[0-9]+$ ]] || [[ "$new_swappiness_input" -lt 0 ]] || [[ "$new_swappiness_input" -gt 100 ]]; then
        log_error "无效的 swappiness 值: '$new_swappiness_input'。请输入0到100之间的数字。"
        echo -e "${RED}输入无效，swappiness 配置未更改。${NC}"
        return 1
    fi

    log_info "用户选择设置 swappiness 为: $new_swappiness_input"
    echo -e "准备将 vm.swappiness 设置为: ${GREEN}$new_swappiness_input${NC}"

    if [[ ! -d /etc/sysctl.d ]]; then
        log_info "/etc/sysctl.d 目录不存在，正在尝试创建..."
        mkdir -p /etc/sysctl.d || {
            log_error "创建 /etc/sysctl.d 目录失败。无法持久化 swappiness 设置。"
            echo -e "${RED}无法创建 /etc/sysctl.d，swappiness 设置可能不会持久。${NC}"
        }
    fi

    local sysctl_conf_content="vm.swappiness = $new_swappiness_input"
    log_info "正在将 '$sysctl_conf_content' 写入到 '$SYSCTL_SWAPPINESS_CONF'"
    if echo "$sysctl_conf_content" > "$SYSCTL_SWAPPINESS_CONF"; then
        log_success "成功将 swappiness 配置写入到 '$SYSCTL_SWAPPINESS_CONF'。"
        log_info "正在应用新的 sysctl 配置 (sysctl -p '$SYSCTL_SWAPPINESS_CONF')..."
        if sysctl -p "$SYSCTL_SWAPPINESS_CONF" &>> "$LOG_FILE"; then
            log_success "vm.swappiness 已成功设置为 $new_swappiness_input 并已生效。"
            echo -e "${GREEN}vm.swappiness 已成功设置为 $new_swappiness_input 并已生效。${NC}"
        else
            log_warning "执行 'sysctl -p $SYSCTL_SWAPPINESS_CONF' 失败。可能需要手动应用或重启。"
            echo -e "${YELLOW}配置已写入，但可能需要手动执行 'sudo sysctl -p $SYSCTL_SWAPPINESS_CONF' 或重启后生效。${NC}"
        fi
    else
        log_error "无法写入 swappiness 配置到 '$SYSCTL_SWAPPINESS_CONF'。请检查权限。"
        echo -e "${RED}无法写入配置文件，swappiness 设置未持久化。${NC}"
        log_info "尝试临时设置 vm.swappiness = $new_swappiness_input"
        if sysctl -w "vm.swappiness=$new_swappiness_input" &>> "$LOG_FILE"; then
            log_success "vm.swappiness 已临时设置为 $new_swappiness_input (非持久)。"
            echo -e "${GREEN}vm.swappiness 已临时设置为 $new_swappiness_input (重启后失效)。${NC}"
        else
            log_error "临时设置 vm.swappiness 也失败了。"
        fi
    fi
    return 0
}


# --- Swap 创建操作 ---
create_swap_file() {
    local size_mb="$1"
    local swap_path="$2"

    log_info "准备创建交换文件: '$swap_path' (大小: ${size_mb}MB)"

    if [[ "${IS_CONTAINER_ENV:-0}" == "1" ]]; then
        if ! prompt_for_confirmation "您在容器环境中。创建Swap可能无效或不被允许。是否继续?"; then
            return 1
        fi
    fi

    if [[ -e "$swap_path" ]]; then
        if [[ -f "$swap_path" ]]; then
            if ! prompt_for_confirmation "交换文件 '$swap_path' 已存在。是否覆盖?"; then
                return 1
            fi
            log_info "检测到已存在的交换文件 '$swap_path'。尝试关闭并移除..."
            swapoff "$swap_path" 2>/dev/null || true
            rm -f "$swap_path" || error_exit "移除旧交换文件 '$swap_path' 失败。"
        else
            error_exit "指定路径 '$swap_path' 已存在但不是普通文件。"
        fi
    fi

    local swap_dir
    swap_dir=$(dirname "$swap_path")
    if [[ ! -d "$swap_dir" ]]; then
        error_exit "交换文件所在的目录 '$swap_dir' 不存在。"
    fi

    check_disk_space "$size_mb" "$swap_dir"

    log_info "正在分配空间用于交换文件 (大小: ${size_mb}MB)..."

    local fallocate_used=0
    local fs_type
    fs_type=$(df -T "$swap_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    log_info "目标目录 '$swap_dir' 的文件系统类型为: ${fs_type:-未知}"

    if [[ "$fs_type" == "btrfs" ]]; then
        log_warning "检测到Btrfs文件系统。'fallocate' 可能不适用于创建交换文件。将强制使用 'dd'。"
        echo -e "${YELLOW}警告: 目标位于Btrfs文件系统，将使用 'dd' 创建交换文件以确保兼容性。这可能需要更长时间。${NC}"
        fallocate_used=0
    elif command -v fallocate &> /dev/null; then
        log_info "检测到 'fallocate' 命令，尝试快速分配空间。"
        if fallocate -l "${size_mb}M" "$swap_path" &>>"$LOG_FILE"; then
            log_info "'fallocate' 成功分配空间。"
            fallocate_used=1
        else
            log_warning "'fallocate' 执行失败。回退到 'dd'。这可能需要更长时间。"
            rm -f "$swap_path" 2>/dev/null
        fi
    else
        log_info "未找到 'fallocate' 命令，将使用 'dd'。这可能需要一些时间。"
    fi

    if [[ "$fallocate_used" -eq 0 ]]; then
        if dd --help 2>&1 | grep -q 'status=LEVEL'; then
            log_info "'dd' 支持 'status=progress'，将显示进度。"
            if ! dd if=/dev/zero of="$swap_path" bs=1M count="$size_mb" status=progress 2>>"$LOG_FILE"; then
                rm -f "$swap_path" 2>/dev/null
                error_exit "使用 'dd' (带进度) 创建交换文件 '$swap_path' 失败。"
            fi
        else
            log_info "'dd' 不支持 'status=progress'。完成后显示摘要。"
            if ! dd if=/dev/zero of="$swap_path" bs=1M count="$size_mb" >>"$LOG_FILE"; then
                rm -f "$swap_path" 2>/dev/null
                error_exit "使用 'dd' 创建交换文件 '$swap_path' 失败。"
            fi
        fi
    fi

    chmod 600 "$swap_path" || error_exit "设置交换文件权限 (chmod 600 '$swap_path') 失败。"

    log_info "正在将文件 '$swap_path' 格式化为Swap..."
    if ! mkswap "$swap_path" &>>"$LOG_FILE"; then
        rm -f "$swap_path" 2>/dev/null
        error_exit "格式化交换文件 (mkswap '$swap_path') 失败。"
    fi

    log_info "正在启用交换文件 '$swap_path'..."
    if ! swapon "$swap_path" &>>"$LOG_FILE"; then
        local swap_uuid_val
        swap_uuid_val=$(blkid -s UUID -o value "$swap_path" 2>/dev/null)
        if [[ -n "$swap_uuid_val" ]]; then
            if ! [[ "$swap_uuid_val" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
                log_warning "从 '$swap_path' 获取的UUID '$swap_uuid_val' 格式不正确。"
            else
                mkswap -U "$swap_uuid_val" "$swap_path" &>/dev/null
            fi
        fi
        rm -f "$swap_path" 2>/dev/null
        error_exit "启用交换文件 (swapon '$swap_path') 失败。"
    fi

    add_to_fstab "$swap_path" "none" "swap" "defaults" "0" "0"

    log_success "交换文件创建并启用成功: '$swap_path' (大小: ${size_mb}MB)。"
    if [[ "$IS_INTERACTIVE_MODE" -eq 1 ]]; then
        configure_swappiness
    fi
    return 0
}

format_partition_as_swap() {
    local device="$1"

    log_info "准备在设备 '$device' 上设置交换分区。"

    if [[ "${IS_CONTAINER_ENV:-0}" == "1" ]]; then
        if ! prompt_for_confirmation "您在容器环境中。操作物理分区可能不允许或导致问题。是否继续?"; then
            return 1
        fi
    fi

    if [[ ! -b "$device" ]]; then
        error_exit "指定路径 '$device' 不是有效的块设备。"
    fi

    if [[ ! "$device" =~ [0-9]$ && "$device" =~ /dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|xvd[a-z]+|vd[a-z]+)$ ]]; then
        echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 极度危险操作警告 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
        echo -e "${RED}您输入的设备路径 '${device}' 看起来像一个【整个磁盘】而不是一个分区！${NC}"
        echo -e "${RED}继续操作将会【永久删除该磁盘上的所有数据】，包括所有分区和操作系统！${NC}"
        echo -e "${YELLOW}如果您确定要格式化整个磁盘 '${device}' 作为Swap (极不推荐，通常是错误操作)，${NC}"
        read -p $"请重新输入完整的设备路径 '${device}' 以确认此毁灭性操作，或输入其他任何内容取消: " -r confirm_whole_disk_format
        if [[ "$confirm_whole_disk_format" != "$device" ]]; then
            log_warning "用户取消了对整个磁盘 '${device}' 的格式化操作。"
            echo "操作已取消。未对 '${device}' 进行任何更改。"
            return 1
        fi
        log_warning "用户已二次确认对整个磁盘 '${device}' 进行格式化。风险自负！"
    fi

    local real_device_path
    real_device_path=$(readlink -f "$device")
    if mount | grep -q "^${real_device_path}[[:space:]]"; then
        error_exit "设备 '$device' (实际: '$real_device_path') 已被挂载。请先卸载。"
    fi

    if swapon --show | grep -q "^${real_device_path}[[:space:]]"; then
        log_info "设备 '$device' (实际: '$real_device_path') 已是活动Swap。将先关闭，再重格式化。"
        swapoff "$real_device_path" 2>/dev/null || error_exit "关闭现有Swap '$real_device_path' 失败。"
    fi

    echo -e "${RED}重要警告: 在 '$device' 上设置交换分区将格式化该分区！${NC}"
    echo -e "${RED}该分区上的【所有数据都将被永久删除】。${NC}"
    echo -e "${YELLOW}请确认 '$device' 未被使用或其数据不再需要。${NC}"

    local confirm_format_input
    read -p "您确定要继续吗? (请输入 'YES' 确认): " -r confirm_format_input 
    if [[ "$confirm_format_input" != "YES" ]]; then
        echo "操作已取消。未对 '$device' 进行更改。"
        return 1
    fi

    log_info "正在将分区 '$device' 格式化为Swap (mkswap -f '$device')..."
    if ! mkswap -f "$device" &>>"$LOG_FILE"; then
        error_exit "格式化交换分区 (mkswap '$device') 失败。"
    fi

    log_info "正在启用交换分区 '$device' (swapon '$device')..."
    if ! swapon "$device" &>>"$LOG_FILE"; then
        error_exit "启用交换分区 (swapon '$device') 失败。"
    fi

    local uuid_val
    uuid_val=$(blkid -s UUID -o value "$device" 2>/dev/null)
    if [[ -n "$uuid_val" ]]; then
        if ! [[ "$uuid_val" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
            log_warning "从设备 '$device' 获取的UUID '$uuid_val' 格式不正确。将用设备路径添加fstab。"
            uuid_val=""
        fi
    fi

    if [[ -n "$uuid_val" ]]; then
        log_info "获取到设备 '$device' 的 UUID: $uuid_val。将用UUID添加fstab。"
        add_to_fstab "UUID=$uuid_val" "none" "swap" "sw" "0" "0"
    else
        log_warning "无法获取 '$device' 的有效UUID。将用设备路径 '$device' 添加fstab。"
        add_to_fstab "$device" "none" "swap" "sw" "0" "0"
    fi

    log_success "交换分区设置成功: '$device'。"
    if [[ "$IS_INTERACTIVE_MODE" -eq 1 ]]; then
        configure_swappiness
    fi
    return 0
}

# --- fstab 管理 ---
_handle_fstab_update_failure() {
    local operation_desc="$1"
    local backup_fstab_file="$2"

    log_error "关键步骤: 移动临时fstab文件以覆盖原 /etc/fstab 失败！ ($operation_desc)"
    if [[ -n "$backup_fstab_file" && -f "$backup_fstab_file" ]]; then
        if prompt_for_confirmation "警告: 更新 /etc/fstab 失败。是否尝试从备份文件\n$backup_fstab_file\n恢复 /etc/fstab 到操作前状态?"; then
            log_info "用户同意从备份 '$backup_fstab_file' 恢复 /etc/fstab。"
            if cp "$backup_fstab_file" /etc/fstab; then
                log_success "/etc/fstab 已成功从备份 '$backup_fstab_file' 恢复。"
                echo -e "${GREEN}/etc/fstab 已从备份恢复。${NC}"
            else
                log_error "从备份 '$backup_fstab_file' 恢复 /etc/fstab 失败！系统fstab可能处于不一致状态。"
                echo -e "${RED}恢复 /etc/fstab 失败！请立即手动检查并修复 /etc/fstab。备份文件位于: $backup_fstab_file ${NC}"
            fi
        else
            log_warning "用户选择不从备份恢复 /etc/fstab。文件可能已损坏或未被修改。"
            echo -e "${YELLOW}未从备份恢复。请手动检查 /etc/fstab (备份: $backup_fstab_file)。${NC}"
        fi
    else
        log_error "/etc/fstab 更新失败，且没有可用的备份文件进行恢复。"
        echo -e "${RED}/etc/fstab 更新失败且无备份可恢复。请立即手动检查！${NC}"
    fi
}

add_to_fstab() {
    local fstab_device="$1"
    local mount_point="$2"
    local fs_type="$3"
    local options="$4"
    local dump="$5"
    local pass="$6"

    local current_backup_fstab
    current_backup_fstab=$(get_backup_fstab_name)

    if [[ ! -f /etc/fstab ]]; then
        log_warning "重要: /etc/fstab 文件不存在。无法设为开机自启。"
        return 1
    fi

    local fstab_backup_done=0
    if [[ -z "$current_backup_fstab" ]]; then
        log_warning "无法生成fstab备份名。继续操作但无备份。"
    elif ! cp /etc/fstab "$current_backup_fstab" 2>>"$LOG_FILE"; then
        log_warning "无法备份 /etc/fstab 到 '$current_backup_fstab'。继续但无备份。"
    else
        log_info "已备份 /etc/fstab 到 '$current_backup_fstab'。"
        fstab_backup_done=1
    fi

    local grep_device_pattern
    grep_device_pattern=$(echo "$fstab_device" | sed 's/[\/\.&]/\\&/g')

    if grep -qE "^[[:blank:]]*${grep_device_pattern}[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]]" /etc/fstab; then
        log_info "设备/UUID '$fstab_device' 的Swap条目已存在于 /etc/fstab。不重复添加。"
        return 0
    fi

    local fstab_entry="$fstab_device\t$mount_point\t$fs_type\t$options\t$dump\t$pass"
    log_info "正在添加以下条目到 /etc/fstab:"
    log_info "$fstab_entry"

    local temp_fstab_edit
    temp_fstab_edit=$(mktemp "/tmp/fstab_add.XXXXXX")
    if [[ -z "$temp_fstab_edit" ]]; then
        log_error "创建用于修改fstab的临时文件失败。"
        return 1
    fi

    cat /etc/fstab > "$temp_fstab_edit" || { log_error "读取/etc/fstab到临时文件失败。"; rm -f "$temp_fstab_edit"; return 1; }

    if [[ $(tail -c1 "$temp_fstab_edit" | wc -l) -eq 0 ]]; then
        echo >> "$temp_fstab_edit" || { log_error "在临时fstab文件末尾添加新行失败。"; rm -f "$temp_fstab_edit"; return 1; }
    fi

    if ! echo -e "$fstab_entry" >> "$temp_fstab_edit"; then
        log_error "无法将条目写入临时fstab文件。"
        rm -f "$temp_fstab_edit"
        return 1
    fi

    if mv "$temp_fstab_edit" /etc/fstab; then
        log_info "已成功添加条目到 /etc/fstab。"
        rm -f "$temp_fstab_edit"
        return 0
    else
        _handle_fstab_update_failure "添加条目到" "$current_backup_fstab"
        rm -f "$temp_fstab_edit"
        return 1
    fi
}

remove_from_fstab() {
    local target_id="$1"
    local original_target_path_for_uuid_lookup="${2:-}"

    log_info "准备从 /etc/fstab 移除Swap条目。目标: '$target_id'"

    if [[ ! -f /etc/fstab ]]; then
        log_warning "/etc/fstab 文件不存在，无需移除条目。"
        return 0
    fi

    local current_backup_fstab
    current_backup_fstab=$(get_backup_fstab_name)
    local fstab_backup_done=0

    if [[ -z "$current_backup_fstab" ]]; then
        log_warning "无法生成fstab备份名。继续操作但无备份。"
    elif ! cp /etc/fstab "$current_backup_fstab" 2>>"$LOG_FILE"; then
        log_warning "无法备份 /etc/fstab 到 '$current_backup_fstab'。继续但无备份。"
    else
        log_info "已备份 /etc/fstab 到 '$current_backup_fstab'。"
        fstab_backup_done=1
    fi

    local temp_fstab_edit
    temp_fstab_edit=$(mktemp "/tmp/fstab_remove.XXXXXX")
    if [[ -z "$temp_fstab_edit" ]]; then
        log_error "创建用于修改fstab的临时文件失败。"
        return 1
    fi

    local sed_pattern=""
    if [[ "$target_id" == "all" ]]; then
        sed_pattern='/^[[:blank:]]*[^#][^[:space:]]\+[[:space:]]\+[^[:space:]]\+[[:space:]]\+swap\([[:space:]]\+.*\|$\)/d'
        log_info "将移除 /etc/fstab 中所有Swap条目。"
    else
        local sed_escaped_target
        local uuid_of_target=""

        if [[ "$target_id" =~ ^UUID= ]]; then
            sed_escaped_target=$(echo "$target_id" | sed 's/[\/\.&]/\\&/g')
        elif [[ -b "$target_id" || -n "$original_target_path_for_uuid_lookup" ]]; then
            local path_to_check_uuid="${original_target_path_for_uuid_lookup:-$target_id}"
            if [[ -b "$path_to_check_uuid" ]]; then
                 uuid_of_target=$(blkid -s UUID -o value "$path_to_check_uuid" 2>/dev/null)
                 if [[ -n "$uuid_of_target" ]] && ! [[ "$uuid_of_target" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
                    log_warning "从设备 '$path_to_check_uuid' 获取的UUID '$uuid_of_target' 格式不正确，将忽略。"
                    uuid_of_target=""
                 fi
            fi
            sed_escaped_target=$(echo "$target_id" | sed 's/[\/\.&]/\\&/g')
        else
            sed_escaped_target=$(echo "$target_id" | sed 's/[\/\.&]/\\&/g')
        fi

        if [[ -n "$uuid_of_target" ]]; then
            local sed_escaped_uuid="UUID=${uuid_of_target}"
            sed_pattern="/^[[:blank:]]*\(${sed_escaped_uuid}\|${sed_escaped_target}\)[[:space:]]\+[^[:space:]]\+[[:space:]]\+swap\([[:space:]]\+.*\|$\)/d"
            log_info "将尝试移除与路径 '$target_id' 或其UUID '$uuid_of_target' 相关的Swap条目。"
        else
            sed_pattern="/^[[:blank:]]*${sed_escaped_target}[[:space:]]\+[^[:space:]]\+[[:space:]]\+swap\([[:space:]]\+.*\|$\)/d"
            log_info "将尝试移除与路径 '$target_id' 相关的Swap条目。"
        fi
    fi

    if ! grep -qE "${sed_pattern%'/d'}" /etc/fstab && [[ "$target_id" != "all" ]]; then
        if [[ "$target_id" != "all" ]]; then
            log_info "在 /etc/fstab 中未找到与 '$target_id' 匹配的Swap条目进行删除。"
        else
            log_info "/etc/fstab 中没有活动的Swap条目。"
        fi
        rm -f "$temp_fstab_edit"
        return 0
    fi


    if sed -E "$sed_pattern" /etc/fstab > "$temp_fstab_edit"; then
        if ! diff -q /etc/fstab "$temp_fstab_edit" &>/dev/null; then
            if mv "$temp_fstab_edit" /etc/fstab; then
                log_success "/etc/fstab 中的Swap条目已成功移除 (目标: '$target_id')。"
                rm -f "$temp_fstab_edit"
                return 0
            else
                _handle_fstab_update_failure "移除条目从" "$current_backup_fstab"
                rm -f "$temp_fstab_edit"
                return 1
            fi
        else
            log_info "/etc/fstab 中没有与 '$target_id' 匹配的Swap条目被实际删除 (文件未改变)。"
            rm -f "$temp_fstab_edit"
            return 0
        fi
    else
        log_error "从 /etc/fstab 移除Swap条目 (sed操作) 失败 (目标: '$target_id')。"
        rm -f "$temp_fstab_edit"
        if [[ "$fstab_backup_done" -eq 1 ]]; then
            log_error "原始 /etc/fstab 已备份到 '$current_backup_fstab'。"
        fi
        return 1
    fi
}


# --- Swap 删除操作 (已重构) ---
remove_swap() {
    local target_to_remove="${1:-}"
    local user_input_target=""

    echo "--- 删除Swap ---"
    
    if ! swapon --show 2>/dev/null | grep -q .; then
        get_current_swap # 即使没有活动的，也显示一下状态（例如 "当前没有活动的Swap。"）
        if [[ -f /etc/fstab ]] && grep -qE '^[[:blank:]]*[^#][^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]+.*|$)' /etc/fstab; then
            log_warning "当前没有活动的Swap，但在 /etc/fstab 中检测到残留的Swap条目。"
            local confirm_fstab_clean_msg="是否尝试从 /etc/fstab 中移除这些残留条目?"
            if [[ -n "$target_to_remove" && "$target_to_remove" == "all" ]]; then
                log_info "非交互式模式：将尝试从 /etc/fstab 清理所有残留Swap条目。"
                remove_from_fstab "all"
            elif [[ -z "$target_to_remove" ]]; then 
                if prompt_for_confirmation "$confirm_fstab_clean_msg"; then
                    remove_from_fstab "all" 
                fi
            else 
                log_info "非交互式模式：目标 '$target_to_remove' 不活动，将尝试从 /etc/fstab 清理其对应条目。"
                remove_from_fstab "$target_to_remove" "$target_to_remove"
            fi
        else
             echo "当前系统没有活动的Swap，/etc/fstab中也未检测到Swap条目。无需删除。"
        fi
        return 0
    fi
    
    get_current_swap # 如果有活动的Swap，则显示当前状态

    if [[ -n "$target_to_remove" ]]; then
        user_input_target="$target_to_remove"
        log_info "非交互式删除模式，目标: '$user_input_target'"
    else
        read -p "请输入要删除的Swap设备/文件路径 (例如 /dev/sdb1 或 /swapfile)，或输入 'all' 删除所有: " -r user_input_target
    fi

    if [[ -z "$user_input_target" ]]; then
        log_error "未输入任何目标，操作取消。"
        return 1
    fi

    if [[ "$user_input_target" == "all" ]]; then
        local active_swap_files=()
        log_info "准备删除所有活动的Swap..."

        if [[ -f /proc/swaps ]]; then
            tail -n +2 /proc/swaps | while IFS= read -r line; do
                local path type
                path=$(echo "$line" | awk '{print $1}')
                type=$(echo "$line" | awk '{print $2}')
                if [[ "$type" == "file" && -n "$path" && "$path" != "[SWAP]" && -f "$path" ]]; then
                    active_swap_files+=("$path")
                    log_info "记录到活动交换文件 (来自 /proc/swaps): '$path'"
                fi
            done
        fi

        log_info "正在关闭所有活动的Swap设备 (swapoff -a)..."
        if ! swapoff -a; then
            log_warning "'swapoff -a' 执行时遇到问题，但脚本将继续尝试清理。"
        fi

        remove_from_fstab "all"

        if [[ ${#active_swap_files[@]} -gt 0 ]]; then
            log_info "正在删除之前记录的 ${#active_swap_files[@]} 个交换文件..."
            for file_to_delete in "${active_swap_files[@]}"; do
                if [[ -f "$file_to_delete" ]]; then
                    log_info "正在删除交换文件: '$file_to_delete'"
                    if rm -f "$file_to_delete"; then
                        log_success "已成功删除交换文件: '$file_to_delete'"
                    else
                        log_warning "删除交换文件 '$file_to_delete' 失败。"
                    fi
                fi
            done
        fi
        log_success "已尝试移除所有Swap。"

    else
        local target_path_resolved
        target_path_resolved=$(readlink -f "$user_input_target" 2>/dev/null || echo "$user_input_target")

        local is_active_swap=0
        # 改进: 使用更精确的 grep 匹配
        if swapon --show --noheadings | awk '{print $1}' | grep -qE "^${target_path_resolved}$"; then
            is_active_swap=1
        fi
        
        if [[ ! -b "$target_path_resolved" && ! -f "$target_path_resolved" && "$is_active_swap" -eq 0 ]]; then
             # 错误提示时，get_current_swap 已在函数开始时被调用过（如果存在活动swap）
             log_error "指定的Swap '$user_input_target' (解析为 '$target_path_resolved') 不存在，也不是活动的Swap。"
             echo -e "${YELLOW}请检查输入的路径是否正确。参考上面列出的当前活动的Swap设备。${NC}"
             return 1 
        fi

        log_info "正在关闭指定的Swap: '$target_path_resolved'..."
        if ! swapoff "$target_path_resolved"; then
            if ! swapoff "$user_input_target" 2>/dev/null; then
                 log_warning "关闭Swap '$user_input_target' (或 '$target_path_resolved') 失败。可能已被关闭或路径问题。"
            fi
        else
            log_info "Swap '$target_path_resolved' 已成功关闭。"
        fi

        remove_from_fstab "$target_path_resolved" "$target_path_resolved"

        if [[ -f "$target_path_resolved" ]]; then
            log_info "正在删除交换文件: '$target_path_resolved'..."
            if rm -f "$target_path_resolved"; then
                log_success "已成功删除交换文件: '$target_path_resolved'。"
            else
                log_warning "删除交换文件 '$target_path_resolved' 失败。"
            fi
        elif [[ -b "$target_path_resolved" ]]; then
            log_info "目标 '$target_path_resolved' 是块设备。已从Swap配置移除，分区本身未删除。"
        fi

        log_success "已成功移除Swap: '$user_input_target'。"
    fi
    return 0
}

# --- 帮助与菜单 ---
show_help() {
    cat << EOF

${MAGENTA}Linux Swap 智能设置脚本 (版本: 1.6.3)${NC}
${YELLOW}作者: ${AUTHOR_NAME}${NC}

${CYAN}简介:${NC}
  此脚本用于在Linux系统上快速、安全地创建、管理和删除Swap（交换空间）。
  支持使用交换文件或独立分区作为Swap。包含内核参数(swappiness)调整、
  Btrfs兼容性处理、防止误格式化整个磁盘、操作前摘要确认等增强功能。

${CYAN}用法:${NC}
  sudo $0 [选项] [参数]

${CYAN}选项:${NC}
  -h, --help                     显示此帮助信息并退出。
  -v, --verbose                  启用详细输出模式。
  -f, --file SIZE                创建指定大小的交换文件。
                                   SIZE: 如 1G, 512M, 2048 (MB)。默认路径: '$SWAP_FILE_DEFAULT'。
  -p, --partition DEVICE         将指定分区格式化为Swap。
                                   DEVICE: 如 /dev/sdb1。
                                   ${RED}警告: 此操作会格式化目标分区，数据将丢失！${NC}
                                   ${RED}脚本会加强对误格式化整个磁盘的防范。${NC}
  -r, --remove [TARGET | "all"]  删除Swap。
                                   TARGET: Swap设备或文件路径。 "all": 删除所有。
  -s, --show                     仅显示当前系统Swap状态和磁盘信息。
  --swappiness VALUE             非交互式设置 vm.swappiness (0-100)。
                                   会写入 '$SYSCTL_SWAPPINESS_CONF' 并立即生效。

${CYAN}交互模式:${NC}
  sudo $0                        # 启动交互式菜单 (包含操作前摘要确认)

${CYAN}示例:${NC}
  sudo $0 -f 2G                  # 创建2GB交换文件。
  sudo $0 -p /dev/sdc1           # 将 /dev/sdc1 格式化为Swap。
  sudo $0 -r /swapfile           # 删除 /swapfile。
  sudo $0 -r all                 # 删除所有Swap。
  sudo $0 --swappiness 10        # 设置 swappiness 为 10。

${CYAN}重要注意事项:${NC}
  - ${YELLOW}必须以root权限运行 (使用 sudo)。${NC}
  - ${RED}格式化分区 (-p) 会永久删除数据，请务必小心！${NC}
  - /etc/fstab 修改前会自动备份。旧备份会定期清理。
  - 日志文件位于 /tmp/ 目录下。

${YELLOW}技术支持与反馈: 请联系 ${AUTHOR_NAME}${NC}
EOF
}

# 新增: 显示操作摘要并请求最终确认 (交互模式专用)
confirm_final_action() {
    local action_description="$1"
    local details="$2" # 多行详情字符串

    echo -e "\n--- ${YELLOW}最终操作确认${NC} ---"
    echo -e "${CYAN}即将执行以下操作:${NC}"
    echo -e "${action_description}"
    if [[ -n "$details" ]]; then
        echo -e "${CYAN}详情:${NC}\n$details"
    fi
    echo "--------------------------"
    
    return $(prompt_for_confirmation "您确定要执行以上操作吗?")
}


interactive_menu() {
    IS_INTERACTIVE_MODE=1
    while true; do
        print_main_title
        get_current_swap

        echo "--- 请选择要执行的操作 ---"
        echo -e "  ${GREEN}1)${NC} 创建新的【交换文件】"
        echo -e "  ${GREEN}2)${NC} 将现有【分区】格式化为Swap"
        echo -e "  ${GREEN}3)${NC} ${RED}删除${NC} Swap (文件或分区)"
        echo -e "  ${GREEN}4)${NC} 配置内核交换倾向 (vm.swappiness)"
        echo -e "  ${GREEN}5)${NC} 显示详细的磁盘与分区信息"
        echo -e "  ${GREEN}6)${NC} 退出脚本"
        print_separator

        read -p "请输入选项编号 (1-6): " choice
        echo

        case $choice in
            1) # 创建交换文件
                echo "--- 1. 创建新的交换文件 ---"
                local mem_total_kb_val mem_total_mb_val suggested_swap_mb_val size_input_val swap_path_input_val
                mem_total_kb_val=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
                mem_total_mb_val=$((mem_total_kb_val / 1024))

                if [[ "$mem_total_mb_val" -le 1024 ]]; then suggested_swap_mb_val=$((mem_total_mb_val * 2));
                elif [[ "$mem_total_mb_val" -le 8192 ]]; then suggested_swap_mb_val="$mem_total_mb_val";
                elif [[ "$mem_total_mb_val" -le 32768 ]]; then suggested_swap_mb_val=$((mem_total_mb_val / 2));
                else suggested_swap_mb_val=16384; fi
                [[ "$suggested_swap_mb_val" -lt 64 ]] && suggested_swap_mb_val=64
                [[ "$suggested_swap_mb_val" -gt 32768 ]] && suggested_swap_mb_val=32768

                echo "当前系统物理内存: $((mem_total_mb_val / 1024)) GB (${mem_total_mb_val} MB)"
                echo -e "建议Swap大小: ${YELLOW}${suggested_swap_mb_val}M${NC}"
                read -p "请输入交换文件大小 [回车用建议值 ${suggested_swap_mb_val}M]: " size_input_val
                size_input_val="${size_input_val:-${suggested_swap_mb_val}M}"

                local validated_size_mb_val
                validated_size_mb_val=$(validate_size "$size_input_val")
                if [[ $? -ne 0 || -z "$validated_size_mb_val" ]]; then
                    log_error "输入的大小 '$size_input_val' 无效。"
                else
                    read -p "请输入交换文件路径 [回车用 '$SWAP_FILE_DEFAULT']: " swap_path_input_val
                    local swap_file_to_create_val="${swap_path_input_val:-$SWAP_FILE_DEFAULT}"
                    
                    # 新增: 操作摘要与最终确认
                    local action_desc="创建交换文件"
                    local action_details="  路径: ${swap_file_to_create_val}\n  大小: ${validated_size_mb_val} MB\n  配置: 将添加条目到 /etc/fstab"
                    if confirm_final_action "$action_desc" "$action_details"; then
                        create_swap_file "$validated_size_mb_val" "$swap_file_to_create_val"
                    fi
                fi
                ;;
            2) # 格式化分区为Swap
                echo "--- 2. 将现有分区格式化为Swap ---"
                show_disk_info
                read -p "请输入要格式化为Swap的分区设备路径 (如 /dev/sdb1): " device_path_val

                if [[ -z "$device_path_val" ]]; then
                    log_error "设备路径不能为空。"
                elif [[ ! "$device_path_val" =~ ^/dev/ ]]; then
                    log_error "无效设备路径 '$device_path_val'。应以 /dev/ 开头。"
                else
                    # 新增: 操作摘要与最终确认
                    local action_desc="${RED}将分区格式化为Swap (数据将丢失！)${NC}"
                    local action_details="  设备: ${device_path_val}\n  配置: 将添加条目到 /etc/fstab"
                     # 这里的 confirm_final_action 只是第一层确认，format_partition_as_swap 内部还有更严格的确认
                    if confirm_final_action "$action_desc" "$action_details"; then
                        format_partition_as_swap "$device_path_val"
                    fi
                fi
                ;;
            3) # 删除Swap
                echo "--- 3. 删除Swap ---"
                # remove_swap 函数内部已有其确认逻辑，此处不加额外摘要
                remove_swap
                ;;
            4) # 配置Swappiness
                echo "--- 4. 配置内核交换倾向 (vm.swappiness) ---"
                configure_swappiness
                ;;
            5) # 显示磁盘信息
                echo "--- 5. 显示详细磁盘与分区信息 ---"
                show_disk_info
                ;;
            6) # 退出
                echo "感谢使用 ${AUTHOR_NAME} 提供的Swap设置工具。正在退出..."
                exit 0
                ;;
            *)
                log_error "无效选项 '$choice'。请输入 1 到 6 之间的数字。"
                ;;
        esac

        echo
        read -p "按【回车键】返回主菜单..."
    done
}

# --- 主函数 (脚本入口) ---
main() {
    LOG_FILE=$(mktemp "/tmp/${SCRIPT_NAME%.*}.XXXXXX.log") || {
        echo -e "${RED}错误: 无法创建日志文件。脚本无法继续。${NC}" >&2
        exit 1
    }
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    echo "Log for $SCRIPT_NAME run at $(date) by User: $(whoami)" > "$LOG_FILE"
    log "脚本启动: $SCRIPT_NAME $@"

    initialize_fstab_backup_location
    check_root
    check_environment
    cleanup_old_fstab_backups

    local action_taken_flag=0

    if [[ $# -eq 0 ]]; then
        IS_INTERACTIVE_MODE=1
        interactive_menu
        exit 0
    fi

    local cli_file_size_arg=""
    local cli_partition_device_arg=""
    local cli_remove_target_arg=""
    local cli_show_info_flag=0
    local cli_swappiness_value_arg=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                log_info "详细输出模式已启用。"
                shift
                ;;
            -f|--file)
                if [[ -z "${2:-}" ]]; then error_exit "选项 -f/--file 需要大小参数。"; fi
                cli_file_size_arg="$2"
                action_taken_flag=1
                shift 2
                ;;
            -p|--partition)
                if [[ -z "${2:-}" ]]; then error_exit "选项 -p/--partition 需要设备路径参数。"; fi
                if [[ ! "${2:-}" =~ ^/dev/ ]]; then error_exit "设备参数 '${2:-}' 格式错误。"; fi
                cli_partition_device_arg="$2"
                action_taken_flag=1
                shift 2
                ;;
            -r|--remove)
                if [[ -z "${2:-}" ]]; then error_exit "选项 -r/--remove 需要目标参数。"; fi
                cli_remove_target_arg="$2"
                action_taken_flag=1
                shift 2
                ;;
            -s|--show)
                cli_show_info_flag=1
                action_taken_flag=1
                shift
                ;;
            --swappiness)
                if [[ -z "${2:-}" ]]; then error_exit "选项 --swappiness 需要一个值 (0-100)。"; fi
                cli_swappiness_value_arg="$2"
                action_taken_flag=1
                shift 2
                ;;
            *)
                error_exit "未知选项或参数: '$1'。使用 '$0 --help' 查看帮助。"
                ;;
        esac
    done

    if [[ "$cli_show_info_flag" -eq 1 ]]; then
        print_main_title
        get_current_swap
        show_disk_info
    fi
    if [[ -n "$cli_file_size_arg" ]]; then
        print_main_title
        log_info "非交互式模式: 创建交换文件。"
        local size_mb_for_cli
        size_mb_for_cli=$(validate_size "$cli_file_size_arg")
        if [[ $? -ne 0 || -z "$size_mb_for_cli" ]]; then
             error_exit "命令行提供的交换文件大小 '$cli_file_size_arg' 无效。"
        fi
        create_swap_file "$size_mb_for_cli" "$SWAP_FILE_DEFAULT"
        get_current_swap
    fi
    if [[ -n "$cli_partition_device_arg" ]]; then
        print_main_title
        log_info "非交互式模式: 设置交换分区。"
        format_partition_as_swap "$cli_partition_device_arg"
        get_current_swap
    fi
    if [[ -n "$cli_remove_target_arg" ]]; then
        print_main_title
        log_info "非交互式模式: 删除Swap。目标: '$cli_remove_target_arg'"
        remove_swap "$cli_remove_target_arg"
        get_current_swap
    fi

    if [[ -n "$cli_swappiness_value_arg" ]]; then
        print_main_title
        log_info "非交互式模式: 设置 vm.swappiness 为 '$cli_swappiness_value_arg'"
        if ! [[ "$cli_swappiness_value_arg" =~ ^[0-9]+$ ]] || [[ "$cli_swappiness_value_arg" -lt 0 ]] || [[ "$cli_swappiness_value_arg" -gt 100 ]]; then
            error_exit "无效的 swappiness 值: '$cli_swappiness_value_arg'。请输入0到100之间的数字。"
        fi
        local sysctl_conf_content="vm.swappiness = $cli_swappiness_value_arg"
        if [[ ! -d /etc/sysctl.d ]]; then mkdir -p /etc/sysctl.d || log_warning "无法创建 /etc/sysctl.d"; fi

        log_info "正在将 '$sysctl_conf_content' 写入到 '$SYSCTL_SWAPPINESS_CONF'"
        if echo "$sysctl_conf_content" > "$SYSCTL_SWAPPINESS_CONF"; then
            log_success "成功将 swappiness 配置写入到 '$SYSCTL_SWAPPINESS_CONF'。"
            log_info "正在应用新的 sysctl 配置 (sysctl -p '$SYSCTL_SWAPPINESS_CONF')..."
            if sysctl -p "$SYSCTL_SWAPPINESS_CONF" &>> "$LOG_FILE"; then
                log_success "vm.swappiness 已成功设置为 $cli_swappiness_value_arg 并已生效。"
                echo -e "${GREEN}vm.swappiness 已成功设置为 $cli_swappiness_value_arg 并已生效 (非交互模式)。${NC}"
            else
                log_warning "执行 'sysctl -p $SYSCTL_SWAPPINESS_CONF' 失败 (非交互模式)。"
                 echo -e "${YELLOW}配置已写入，但可能需要手动执行 'sudo sysctl -p $SYSCTL_SWAPPINESS_CONF' 或重启后生效。${NC}"
            fi
        else
            log_error "无法写入 swappiness 配置到 '$SYSCTL_SWAPPINESS_CONF' (非交互模式)。"
            echo -e "${RED}无法写入配置文件，swappiness 设置未持久化。${NC}"
        fi
    fi


    if [[ "$action_taken_flag" -eq 0 && "$VERBOSE" -eq 1 ]]; then
        log_info "仅指定了详细输出模式，未执行其他操作。如需帮助，请使用 '$0 --help'。"
    elif [[ "$action_taken_flag" -eq 0 && "$VERBOSE" -eq 0 ]]; then
        if [[ $# -eq 0 && -z "$cli_file_size_arg" && -z "$cli_partition_device_arg" && -z "$cli_remove_target_arg" && "$cli_show_info_flag" -eq 0 && -z "$cli_swappiness_value_arg" ]]; then
             echo "提示: 未指定具体操作。如需管理Swap，请运行 '$0' 进入交互模式，或使用 '$0 --help' 查看选项。"
        fi
    fi

    log "脚本执行完成。"
    if [[ "$VERBOSE" == "1" ]]; then
        echo -e "${BLUE}脚本所有操作已执行完毕。日志文件位于: ${CYAN}$LOG_FILE${NC}"
    fi
    exit 0
}

# --- 脚本开始执行 ---
main "$@"