#!/usr/bin/env bash
#
# 流媒体解锁自动配置脚本
# 用于自动检测本地流媒体解锁状态，并配置最优节点路由
# 支持多种代理类型：shadowsocks, trojan, http, socks
#
# 使用方法：
#   sudo ./stream.sh --API <api_url>              # 基本使用
#   sudo ./stream.sh --API <api_url> --M 4        # 强制使用 IPv4
#   sudo ./stream.sh --API <api_url> --M 6        # 强制使用 IPv6
#

set -euo pipefail  # 严格模式：遇到错误立即退出，未定义变量报错，管道错误传播

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# 基本配置
readonly VERSION='1.0.0'
readonly LOG_DIR="/opt/stream"
readonly STREAM_CHECK_URL="https://github.com/HuTuTuOnO/RegionRestrictionCheck/raw/main/check.sh"
readonly TCPING_INSTALL_URL="https://raw.githubusercontent.com/nodeseeker/tcping/main/install.sh"

# 全局变量
API_URL=""
IP_TYPE=""
NODES=""
PLATFORMS=""
LOCKED_PLATFORMS=()
declare -A ROUTES


# 打印函数
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_title() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

# 显示帮助信息
show_help() {
    cat << EOF
流媒体解锁自动配置脚本 v${VERSION}

用法: $0 [选项]

必需参数:
    --API <url>         API 地址，用于获取节点和平台信息

可选参数:
    --M <4|6>           IP 类型 (4=IPv4, 6=IPv6)
    --H                 显示此帮助信息

功能说明:
    - 自动检测本地流媒体解锁状态
    - 根据延迟选择最优节点
    - 生成 soga 路由配置文件
    - 支持多种代理类型 (ss, trojan, http, socks)

示例:
    sudo $0 --API https://api.example.com/stream
    sudo $0 --API https://api.example.com/stream --M 4

注意:
    - 需要 root 权限运行
    - 需要安装 jq, bc, curl 等依赖
    - 会自动安装 tcping 工具

EOF
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    local deps=(jq bc curl)
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warning "缺少以下依赖程序: ${missing_deps[*]}"
        install_dependencies "${missing_deps[@]}"
    fi
}

# 安装软件包
install_dependencies() {
    local deps=("$@")
    print_info "正在安装依赖: ${deps[*]}"
    
    if command -v apt &> /dev/null; then
        apt-get update -y > /dev/null && apt-get install -y "${deps[@]}" > /dev/null
    elif command -v apk &> /dev/null; then
        apk add --no-cache "${deps[@]}" > /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y "${deps[@]}" > /dev/null
    elif command -v dnf &> /dev/null; then
        dnf install -y "${deps[@]}" > /dev/null
    else
        print_error "不支持的包管理器，请手动安装: ${deps[*]}"
        exit 1
    fi
    
    print_success "依赖安装完成"
}

# 确保 tcping 可用
check_tcping() {
    if ! command -v tcping &> /dev/null; then
        print_info "tcping 未安装，正在尝试安装..."
        if bash <(curl -Ls "$TCPING_INSTALL_URL") --force > /dev/null 2>&1; then
            print_success "tcping 安装成功"
        else
            print_error "安装 tcping 失败，请手动安装"
            exit 1
        fi
    fi
}

# 检测 dig 命令
check_dig() {
    if ! command -v dig &> /dev/null; then
        print_info "dig 未安装，正在尝试安装..."
        if command -v apt &> /dev/null; then
            install_dependencies bind9-dnsutils || {
                print_error "安装 dig 失败，请手动安装"
                exit 1
            }
        elif command -v apk &> /dev/null; then
            install_dependencies bind-tools || {
                print_error "安装 dig 失败，请手动安装"
                exit 1
            }
        else
            print_error "不支持的包管理器，请手动安装 dig"
            exit 1
        fi
        print_success "dig 安装成功"
    fi
}

# 获取 API 数据 并解析到 PLATFORMS NODES
fetch_api_data() {
    local api_url="$1"
    local api_response
    
    api_response=$(curl -s "$api_url" 2>&1)
    
    if [[ -z "$api_response" ]]; then
        print_error "无法连接到 API"
        exit 1
    fi
    
    local code
    code=$(echo "$api_response" | jq -r '.code // empty' 2>/dev/null)
    
    if [[ "$code" != "200" ]]; then
        local msg
        msg=$(echo "$api_response" | jq -r '.msg // "未知错误"' 2>/dev/null)
        print_error "API 返回错误: $msg"
        exit 1
    fi
    
    # 解析节点数据和平台数据到全局变量
    if ! NODES=$(echo "$api_response" | jq -c '.data.node // {}' 2>/dev/null); then
        print_error "无法解析节点数据"
        exit 1
    fi
    
    if ! PLATFORMS=$(echo "$api_response" | jq -c '.data.platform // {}' 2>/dev/null); then
        print_error "无法解析平台数据"
        exit 1
    fi
    
    if [[ "$NODES" == "{}" ]]; then
        print_error "节点数据为空"
        exit 1
    fi
    
    if [[ "$PLATFORMS" == "{}" ]]; then
        print_error "平台数据为空"
        exit 1
    fi
}

# 处理IP类型参数 和 修改 NODES 数据 添加 time 字段
process_nodes() {
    local ip_opt=""
    # 设置 IP 类型选项
    if [[ -n "$IP_TYPE" ]]; then
        case "$IP_TYPE" in
            4) 
                ip_opt="-4" 
                print_info "正在解析节点 IPv4 地址..."
                ;;
            6) 
                ip_opt="-6"
                print_info "正在解析节点 IPv6 地址..."
                ;;
        esac
    fi
    
    # 遍历所有节点
    while IFS= read -r node_alias; do
        local host port output ipaddr latency # upload_at upload_time time_diff
        
        host=$(echo "$NODES" | jq -r --arg alias "$node_alias" '.[$alias].host // empty')
        port=$(echo "$NODES" | jq -r --arg alias "$node_alias" '.[$alias].port // empty')
        
        if [[ -z "$host" || -z "$port" ]]; then
            # 移除无效节点
            NODES=$(echo "$NODES" | jq "del(.\"$node_alias\")")
            continue
        fi

        # 先进行 PING 测试，获取延迟
        if [[ -n "$ip_opt" ]]; then
            output=$(ping "$ip_opt" -c 4 -W 2 "$host" 2>&1 || true)
        else
            output=$(ping -c 4 -W 2 "$host" 2>&1 || true)
        fi
        latency=$(echo "$output" | grep -E 'avg' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
        
        # 如果 PING 失败，使用 TCPING
        if [[ -z "$latency" ]]; then
            # 检查并安装 tcping
            check_tcping
            output=$(tcping -n 4 ${ip_opt:+$ip_opt }"$host" -p "$port" 2>&1 || true)
            latency=$(echo "$output" | grep '平均' | awk -F'= ' '{print $2}' | grep -oE '[0-9.]+' || true)
            # 如果仍然失败，先使用 DIG 解析 IP 再测一次
            if [[ -z "$latency" ]]; then
                check_dig
                local resolved_ip
                if [[ -n "$ip_opt" ]]; then
                    if [[ "$IP_TYPE" == "4" ]]; then
                        resolved_ip=$(dig +tcp +short "$host" -t A @8.8.8.8 | head -1 || true)
                    elif [[ "$IP_TYPE" == "6" ]]; then
                        resolved_ip=$(dig +tcp +short "$host" -t AAAA @8.8.8.8 | head -1 || true)
                    else
                        resolved_ip=$(dig +tcp +short "$host" @8.8.8.8 | head -1 || true)
                    fi
                else
                    resolved_ip=$(dig +tcp +short "$host" @8.8.8.8  | head -1 || true)
                fi
                if [[ -n "$resolved_ip" ]]; then
                    output=$(tcping -n 4 ${ip_opt:+$ip_opt }"$resolved_ip" -p "$port" 2>&1 || true)
                    # 打印 命令
                    latency=$(echo "$output" | grep '平均' | awk -F'= ' '{print $2}' | grep -oE '[0-9.]+' || true)
                else
                    print_warning "无法解析节点 $node_alias ($host) 的 IP 地址"
                fi
            fi
        fi
        
        if [[ -z "$latency" ]]; then
            # 延迟测试失败，移除节点
            NODES=$(echo "$NODES" | jq "del(.\"$node_alias\")")
            print_warning "节点 $node_alias 延迟测试失败，已移除"
            continue
        fi
        
        # 如果指定了 IP 类型，从输出中提取并替换 host
        if [[ -n "$IP_TYPE" ]]; then
            ipaddr=$(echo "$output" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -1 || true)
            if [[ -n "$ipaddr" ]]; then
                NODES=$(echo "$NODES" | jq --arg alias "$node_alias" --arg ip "$ipaddr" '.[$alias].host = $ip')
                print_info "节点 $node_alias: $host -> $ipaddr (${latency}ms)"
            else
                print_warning "无法解析节点 $node_alias ($host) 的 IP 地址"
            fi
        else
            print_info "节点 $node_alias: $host -> ${latency}ms"
        fi
        
        # 添加延迟字段
        NODES=$(echo "$NODES" | jq --arg alias "$node_alias" --arg time "$latency" '.[$alias].time = $time')
    done < <(echo "$NODES" | jq -r 'keys[]')
    
    # 检查是否还有可用节点
    if [[ "$NODES" == "{}" ]]; then
        print_error "所有节点均不可用"
        exit 1
    fi

    # 打印处理后的节点数据（调试用）
    # echo "$NODES" | jq .
}

# 检测未解锁平台并记录到 LOCKED_PLATFORMS
check_stream_locked() {
    print_info "正在检测流媒体解锁状态..."
    # 创建日志目录
    mkdir -p "$LOG_DIR"

    local media_temp
    local media_content=""

    for round in {1..3}; do
        for attempt in {1..3}; do
            media_temp=$(bash <(curl -L -s "$STREAM_CHECK_URL") -M 4 -R 66 2>&1 || true)
            if [[ -n "$media_temp" ]]; then
                print_success "流媒体检测完成（第 ${round} 轮）"
                break
            fi
            print_warning "流媒体检测失败（第 ${round} 轮，重试 $attempt/3）"
            sleep 2
        done
        
        if [[ -n "$media_temp" ]]; then
            echo "$media_temp" > "${LOG_DIR}/stream.${round}.log"
            media_content+="$media_temp"$'\n'
        fi
    done

    if [[ -z "$media_content" ]]; then
        print_error "流媒体检测失败，请检查网络或脚本源"
        exit 1
    fi
    
    mapfile -t LOCKED_PLATFORMS < <(echo "$media_content" | \
        grep -E '\[3[1|3]m' | \
        grep ':' | \
        sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
        sed -E 's/^[[:space:]]+//; s/:\[[^]]*\]//; s/\t.*$//; s/[[:space:]]{2,}.*$//; s/[[:space:]]+$//; s/:$//' | \
        grep -v -E '(反馈|使用|推广|详情|频道|价格|解锁|音乐|http|t\.me|TG|BUG|脚本|测试|网络|输入|版本)' | \
        sort | uniq
    )

    print_info "检测到 ${#LOCKED_PLATFORMS[@]} 个被锁定的平台"
    
    # printf '%s\n' "${LOCKED_PLATFORMS[@]}"
    
}

# 处理平台并选择最优节点并记录到 ROUTES
process_platforms() {
    print_info "正在为被锁定的平台配置最优节点..."
    
    if [[ ${#LOCKED_PLATFORMS[@]} -eq 0 ]]; then
        print_info "没有被锁定的平台需要配置"
        return
    fi

    # 声明局部变量
    local alias_list rules_list node_time best_node best_time
    
    # 遍历所有被锁定的平台
    for platform in "${LOCKED_PLATFORMS[@]}"; do
        # 重置最佳节点信息
        best_node=""; best_time=""

        # 检查平台是否在配置中
        if ! echo "$PLATFORMS" | jq -e --arg platform "$platform" '.[$platform]' > /dev/null 2>&1; then
            print_warning "平台 $platform 不在 API 配置中，跳过"
            continue
        fi
        
        # 获取平台支持的节点别名和规则  
        alias_list=$(echo "$PLATFORMS" | jq -r --arg platform "$platform" '.[$platform].alias // [] | .[]' 2>/dev/null)
        rules_list=$(echo "$PLATFORMS" | jq -r --arg platform "$platform" '.[$platform].rules // [] | .[]' 2>/dev/null)
        if [[ -z "$alias_list" || -z "$rules_list" ]]; then
            print_warning "平台 $platform 没有配置节点别名或规则，跳过"
            continue
        fi
        
        # 查找延迟最低的节点
        while IFS= read -r node_alias; do
            # 跳过空别名
            [[ -z "$node_alias" ]] && continue
            # 检查节点是否存在
            if ! echo "$NODES" | jq -e --arg alias "$node_alias" '.[$alias]' > /dev/null 2>&1; then
                continue
            fi

            # 获取节点延迟
            node_time=$(echo "$NODES" | jq -r --arg alias "$node_alias" '.[$alias].time // "999999"')
            
            # 比较延迟
            if [[ -z "$best_time" ]] || (( $(echo "$node_time < $best_time" | bc -l) )); then
                best_node="$node_alias"
                best_time="$node_time"
            fi
        done <<< "$alias_list"
        
        if [[ -z "$best_node" ]]; then
            print_warning "平台 $platform 没有可用节点，跳过"
            continue
        fi
        
        print_success "平台 $platform: 最佳节点 $best_node (${best_time}ms)"
        
        # 添加平台注释
        if [[ -z "${ROUTES[$best_node]:-}" ]]; then
            ROUTES[$best_node]="\"# $platform\""
        else
            if [[ ! "${ROUTES[$best_node]}" =~ \"#\ $platform\" ]]; then
                ROUTES[$best_node]+="^\"# $platform\""
            fi
        fi
        
        # 添加规则到节点
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            if [[ ! "${ROUTES[$best_node]}" =~ \"$rule\" ]]; then
                ROUTES[$best_node]+="^\"$rule\""
            fi
        done <<< "$rules_list"
    done
    
    print_info "平台路由配置完成，共 ${#ROUTES[@]} 个节点"

    # 打印路由规则（调试用）
    # for node in "${!ROUTES[@]}"; do
    #     echo "节点: $node"
    #     echo "${ROUTES[$node]}" | tr '^' '\n'
    #     echo ""
    # done
}

# 生成soga路由配置文件
generate_soga_routes() {
    # 定义文件路径
    local routes_file="/etc/soga/routes.toml"
    local routes_temp="/etc/soga/routes.toml.tmp"
    
    # 声明节点信息变量（在函数开始处统一声明）
    local node_type node_host node_port
    local node_value1 node_value2 node_value3 node_value4 node_value5 node_value6

    # 清空临时文件
    : > "$routes_temp"
    echo "enable=true" > "$routes_temp"
    # 写入路由部分
    for alias in "${!ROUTES[@]}"; do
        if [[ -z "${ROUTES[$alias]}" ]]; then
            print_warning "节点 $alias 没有任何规则，跳过"
            continue
        fi

        # 写入路由规则
        echo '' >> "$routes_temp"
        echo "# 路由 $alias" >> "$routes_temp"
        echo '[[routes]]' >> "$routes_temp"
        echo 'rules=[' >> "$routes_temp"
        IFS='^'
        for rule in ${ROUTES[$alias]}; do
            echo "  $rule," >> "$routes_temp"
        done
        unset IFS
        echo ']' >> "$routes_temp"

        # 获取节点信息（一次性获取所有字段）
        read -r node_type node_host node_port node_value1 node_value2 node_value3 node_value4 node_value5 node_value6 < <(
            echo "$NODES" | jq -r --arg alias "$alias" '
                .[$alias] | 
                [.type // "", .host // "", .port // "", .value1 // "", .value2 // "", .value3 // "", .value4 // "", .value5 // "", .value6 // ""] | 
                @tsv
            '
        )

        # 写入出口节点
        echo '' >> "$routes_temp"
        echo "# 出口 $alias" >> "$routes_temp"
        echo '[[routes.Outs]]' >> "$routes_temp"
        echo "type=\"$node_type\"" >> "$routes_temp"
        echo "server=\"$node_host\"" >> "$routes_temp"
        echo "port=$node_port" >> "$routes_temp"
        case "$node_type" in
            "ss")
                echo "password=\"$node_value1\"" >> "$routes_temp"
                echo "cipher=\"$node_value2\"" >> "$routes_temp"
            ;;
            "trojan")
                echo "password=\"$node_value1\"" >> "$routes_temp"
                echo "sin=\"$node_value2\"" >> "$routes_temp"
                if [[ "$node_value3" == "1" ]]; then
                    echo "skip_cert_verify=true" >> "$routes_temp"
                else
                    echo "skip_cert_verify=false" >> "$routes_temp"
                fi
            ;;
            "http"|"socks")
                echo "username=\"$node_value1\"" >> "$routes_temp"
                echo "password=\"$node_value2\"" >> "$routes_temp"
            ;;
            *)
            # 其他类型可扩展
            ;;
        esac
    done

    # 添加全局路由规则
    echo '' >> "$routes_temp"
    echo '# 路由 ALL' >> "$routes_temp"
    echo '[[routes]]' >> "$routes_temp"
    echo 'rules=["*"]' >> "$routes_temp"
    echo '' >> "$routes_temp"
    echo '# 出口 ALL' >> "$routes_temp"
    echo '[[routes.Outs]]' >> "$routes_temp"
    echo 'type="direct"' >> "$routes_temp"

    # 替换旧的路由文件
    cat "$routes_temp" > "$routes_file"
    rm -f "$routes_temp"

    print_success "soga 路由配置文件生成完成: $routes_file"
}

# 主函数
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --API)
                API_URL="$2"
                shift 2
                ;;
            --M)
                if [[ "$2" != "4" && "$2" != "6" ]]; then
                    print_error "--M 参数只能是 4 或 6"
                    show_help
                    exit 1
                fi
                IP_TYPE="$2"
                shift 2
                ;;
            --H)
                show_help
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查必需参数
    if [[ -z "$API_URL" ]]; then
        print_error "--API 参数是必需的"
        show_help
        exit 1
    fi
    
    check_root
    check_dependencies
    fetch_api_data "$API_URL"
    process_nodes
    check_stream_locked
    process_platforms
    generate_soga_routes

    print_success "脚本执行完成"
}

# 运行主函数
main "$@"
