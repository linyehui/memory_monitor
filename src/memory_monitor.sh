#!/bin/bash

# 配置
THRESHOLD_MB=50  # 增量报警阈值 (MB)，增量超过此值将变红
INTERVAL=10      # 刷新间隔 (秒)

# 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
CLEAR_LINE='\033[K'

# 全局变量存储初始状态
INITIAL_RAM=0
INITIAL_SWAP=0
MODE="" # "SYSTEM" 或 "PROCESS"
TARGET_PID=""
PROCESS_NAME=""
START_TIME_EPOCH=0
START_TIME_STR=""

# 格式化时长函数
format_duration() {
    local seconds=$1
    if [ $seconds -lt 60 ]; then
        echo "${seconds}s"
    elif [ $seconds -lt 3600 ]; then
        local m=$((seconds / 60))
        local s=$((seconds % 60))
        echo "${m}m ${s}s"
    elif [ $seconds -lt 86400 ]; then
        local h=$((seconds / 3600))
        local m=$(( (seconds % 3600) / 60 ))
        local s=$((seconds % 60))
        echo "${h}h ${m}m ${s}s"
    else
        local d=$((seconds / 86400))
        local h=$(( (seconds % 86400) / 3600 ))
        local m=$(( (seconds % 3600) / 60 ))
        local s=$((seconds % 60))
        echo "${d}d ${h}h ${m}m ${s}s"
    fi
}

# 帮助信息
usage() {
    echo "用法: $0 [PID]"
    echo "  如果不指定 PID，默认监控系统整体内存。"
    echo "  如果指定 PID，监控该进程的内存使用情况。"
    exit 1
}

# 获取系统内存 (返回: RAM_MB SWAP_MB)
get_system_memory() {
    # 1. 获取 Swap Used - 使用更健壮的解析方式
    # sysctl vm.swapusage 输出格式: vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)
    local swap_info=$(sysctl vm.swapusage)
    local swap_used_raw=$(echo "$swap_info" | grep -oE "used = [0-9.]+[MG]" | awk '{print $3}')

    # 提取数值和单位
    local swap_value=$(echo "$swap_used_raw" | grep -oE "[0-9.]+")
    local swap_unit=$(echo "$swap_used_raw" | grep -oE "[MG]")

    # 转换为 MB
    local swap_used=0
    if [ -n "$swap_value" ]; then
        if [ "$swap_unit" == "G" ]; then
            # 使用 awk 进行浮点数运算: GB -> MB
            swap_used=$(echo "$swap_value * 1024" | awk '{printf "%.0f", $1 * $3}')
        else
            # 单位是 M 或无单位，转换为整数
            swap_used=$(echo "$swap_value" | awk '{printf "%.0f", $1}')
        fi
    fi

    # 2. 获取 RAM (使用 vm_stat)
    local vm_stats=$(vm_stat)
    local page_size=4096
    # 获取 pages - 移除末尾的点号
    local pages_active=$(echo "$vm_stats" | grep "Pages active" | awk '{print $3}' | sed 's/\.//')
    local pages_wired=$(echo "$vm_stats" | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//')
    local pages_compressed=$(echo "$vm_stats" | grep "Pages occupied by compressor" | awk '{print $5}' | sed 's/\.//')

    # 计算已用 RAM (Active + Wired + Compressed)
    # 注意：macOS 内存管理复杂，这里取一个近似值作为 "Used"
    local total_pages=$(( pages_active + pages_wired + pages_compressed ))
    local ram_mb=$(( total_pages * page_size / 1024 / 1024 ))

    echo "$ram_mb $swap_used"
}

# 获取进程名称
get_process_name() {
    local pid=$1
    # 使用 ps -o command 获取完整命令
    local full_cmd=$(ps -p $pid -o command= 2>/dev/null)
    if [ -z "$full_cmd" ]; then
        echo "unknown"
        return
    fi

    # 提取第一个参数（可执行文件路径）
    local exec_path=$(echo "$full_cmd" | awk '{print $1}')

    # 如果是 .app 应用，尝试从 Info.plist 获取应用名称
    if [[ "$exec_path" == *".app/"* ]]; then
        # 提取 .app 路径
        local app_path=$(echo "$exec_path" | grep -o '.*\.app' | head -1)
        if [ -n "$app_path" ]; then
            # 使用 plutil 读取 CFBundleName（会自动根据系统语言返回本地化名称，且正确处理中文）
            local bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2>/dev/null)
            if [ -n "$bundle_name" ]; then
                echo "$bundle_name"
                return
            fi
        fi
    fi

    # 如果无法获取应用名称，使用 basename 作为回退方案
    local process_name=$(basename "$exec_path")
    echo "$process_name"
}

# 获取进程内存 (返回: RAM_MB VSZ_MB)
get_process_memory() {
    local pid=$1
    # 检查进程是否存在
    if ! ps -p $pid > /dev/null 2>&1; then
        echo "Error"
        return
    fi
    
    # ps -o rss (Resident Set Size - RAM), vsz (Virtual Memory Size)
    # 单位是 KB
    local output=$(ps -p $pid -o rss=,vsz=)
    local rss_kb=$(echo $output | awk '{print $1}')
    local vsz_kb=$(echo $output | awk '{print $2}')
    
    local rss_mb=$(( rss_kb / 1024 ))
    local vsz_mb=$(( vsz_kb / 1024 ))
    
    echo "$rss_mb $vsz_mb"
}

# 初始化
init() {
    if [ -n "$1" ]; then
        # 验证 PID 是否为有效数字
        if [[ ! "$1" =~ ^[0-9]+$ ]]; then
            echo "错误: PID 必须是正整数。"
            echo ""
            usage
        fi

        MODE="PROCESS"
        TARGET_PID=$1
        PROCESS_NAME=$(get_process_name $TARGET_PID)
        echo "初始化: 正在监控进程 PID=$TARGET_PID ($PROCESS_NAME) ..."
        local mem=$(get_process_memory $TARGET_PID)
        if [ "$mem" == "Error" ]; then
            echo "错误: 进程 $TARGET_PID 未找到。"
            exit 1
        fi
        INITIAL_RAM=$(echo $mem | awk '{print $1}')
        INITIAL_SWAP=$(echo $mem | awk '{print $2}')  # 注意：这里实际是 VSZ
    else
        MODE="SYSTEM"
        echo "初始化: 正在监控系统内存 ..."
        local mem=$(get_system_memory)
        INITIAL_RAM=$(echo $mem | awk '{print $1}')
        INITIAL_SWAP=$(echo $mem | awk '{print $2}')
    fi

    # 记录初始时间
    START_TIME_EPOCH=$(date +%s)
    START_TIME_STR=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 清屏并打印表头
    clear
    echo "============================================================"
    echo "                macOS 内存监控器 (Memory Monitor)"
    echo "============================================================"
    if [ "$MODE" == "PROCESS" ]; then
        echo "监控对象: 进程 PID $TARGET_PID ($PROCESS_NAME)"
    else
        echo "监控对象: 系统整体 (System)"
    fi
    echo "刷新间隔: ${INTERVAL}s | 报警阈值: > ${THRESHOLD_MB}MB (增量)"
    echo "------------------------------------------------------------"
    # 打印静态标签
    printf "%-10s %-15s %-15s %-20s\n" "类型" "RAM (MB)" "Swap/VSZ (MB)" "时间"
    echo "------------------------------------------------------------"
    # 预留3行用于刷新：初始，当前，增量
    echo "" 
    echo ""
    echo ""
    echo "------------------------------------------------------------"
    echo "按 Ctrl+C 退出"
}

# 主循环
run() {
    init $1
    
    # 隐藏光标
    tput civis
    
    # 捕获 Ctrl+C 恢复光标
    trap 'tput cnorm; echo ""; exit' INT
    
    while true; do
        local current_ram=0
        local current_swap=0
        
        if [ "$MODE" == "PROCESS" ]; then
            local mem=$(get_process_memory $TARGET_PID)
            if [ "$mem" == "Error" ]; then
                # 进程已结束，先显示最后一次的增量信息（使用上一次循环的数据）
                # 然后在第11行（第4行数据）显示提示
                tput cup 11 0
                printf "${CLEAR_LINE}${RED}进程 $TARGET_PID ($PROCESS_NAME) 已结束。监控停止。${NC}\n"
                tput cnorm
                exit 0
            fi
            current_ram=$(echo $mem | awk '{print $1}')
            current_swap=$(echo $mem | awk '{print $2}')
        else
            local mem=$(get_system_memory)
            current_ram=$(echo $mem | awk '{print $1}')
            current_swap=$(echo $mem | awk '{print $2}')
        fi
        
        # 计算增量
        # 由于 bash 不支持浮点数运算，这里使用整数。如果 swap 是浮点数 (0.00M)，awk 处理比较好
        # 为简单起见，这里假设系统返回的是整数或我们可以接受整数运算的误差
        # 注意: get_system_memory 中的 swap 可能是浮点数，这里用 bc 或者 awk 再次处理
        
        local diff_ram=$(echo "$current_ram - $INITIAL_RAM" | bc)
        local diff_swap=$(echo "$current_swap - $INITIAL_SWAP" | bc)
        
        # 确定增量显示的颜色
        local ram_color=$NC
        local swap_color=$NC
        
        if (( $(echo "$diff_ram > $THRESHOLD_MB" | bc -l) )); then
            ram_color=$RED
        fi
        
        # 格式化增量显示 (增加 + 号)
        local diff_ram_fmt=$diff_ram
        if (( $(echo "$diff_ram > 0" | bc -l) )); then
            diff_ram_fmt="+${diff_ram}"
        fi
        
        local diff_swap_fmt=$diff_swap
        if (( $(echo "$diff_swap > 0" | bc -l) )); then
            diff_swap_fmt="+${diff_swap}"
        fi
        
        local current_time=$(date "+%Y-%m-%d %H:%M:%S")
        local current_epoch=$(date +%s)
        local elapsed_seconds=$((current_epoch - START_TIME_EPOCH))
        local elapsed_str=$(format_duration $elapsed_seconds)

        # 移动光标到第 8 行 (假设表头占用了之前的行)
        # 具体的行号需要根据 init 中的 echo 数量调整
        # init 输出行数:
        # 1. ====
        # 2. Title
        # 3. ====
        # 4. Object
        # 5. Interval
        # 6. ----
        # 7. Header (Type...)
        # 8. ----
        # 9. (Initial)  <-- 目标位置
        # 10. (Current)
        # 11. (Diff)
        
        tput cup 8 0
        # 初始状态显示开始时间
        printf "${CLEAR_LINE}%-10s %-15s %-15s %-20s\n" "初始状态" "$INITIAL_RAM" "$INITIAL_SWAP" "$START_TIME_STR"
        printf "${CLEAR_LINE}%-10s %-15s %-15s %-20s\n" "当前状态" "$current_ram" "$current_swap" "$current_time"
        
        # 打印增量行 (显示时长)
        tput cup 10 0
        printf "${CLEAR_LINE}%-10s ${ram_color}%-15s${NC} %-15s %-20s\n" "内存增量" "${diff_ram_fmt}" "${diff_swap_fmt}" "$elapsed_str"
        
        sleep $INTERVAL
    done
}

# 启动
run $1
