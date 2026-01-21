#!/bin/bash

ver='1.0.0'

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "错误：必须使用 root 用户运行此脚本！"
  exit 1
fi

# 检查并安装必要的软件包
required_packages=(jq bc curl)
for package in "${required_packages[@]}"; do
  if ! command -v "$package" &> /dev/null; then
    echo "提示：$package 未安装，正在尝试安装..."
    install_cmd=""
    if which apt &> /dev/null; then
      install_cmd="apt-get update -y > /dev/null && apt-get install -y $package > /dev/null"
    elif which apk &> /dev/null; then
      install_cmd="apk add --no-cache $package > /dev/null"
    else
      echo "错误：不支持的包管理器，请手动安装 $package。"
      exit 1
    fi
    eval "$install_cmd" || { echo "错误：安装 $package 失败。"; exit 1; }
  fi
done

# 解析传入参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --API) api="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 检查 API 地址
if [[ -z "$api" ]]; then
  echo "错误：没有传入 API 地址，请使用 --API 传入有效的 API 地址。"
  exit 1
fi

# 获取 API 数据
api_res=$(curl -s "$api")
if [[ $(echo "$api_res" | jq -r '.code') -ne 200 ]]; then
  echo "错误：无法获取流媒体解锁状态，原因: $(echo "$api_res" | jq -r '.msg')"
  exit 1
fi

# 解析 API 数据
if ! nodes_json=$(echo "$api_res" | jq -r '.data.node // {}'); then
  echo "错误：无法解析节点数据。"
  exit 1
fi

if ! platforms_json=$(echo "$api_res" | jq -r '.data.platform // {}'); then
  echo "错误：无法解析平台数据。"
  exit 1
fi

# 获取流媒体解锁状态
echo "提示：正在检测流媒体解锁状态..."
for attempt in {1..3}; do
  media_content=$(bash <(curl -L -s check.unlock.media) -M 4 -R 66 2>&1)
  if [[ -n "$media_content" ]]; then
    echo "提示：流媒体检测脚本执行成功"
    break
  fi
  echo "警告：流媒体检测失败，正在重试 ($attempt/3)..."
  sleep 2
done

if [[ -z "$media_content" ]]; then
  echo "错误：流媒体检测脚本执行失败，请检查网络或脚本源"
  exit 1
fi

#将 media_content 保存到日志
echo "$media_content" > /opt/stream/stream.log

# 读取流媒体状态（修正正则表达式）
mapfile -t locked_media < <(echo "$media_content" | \
  grep -E '\[3[1|3]m' | \
  grep ':' | \
  sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
  sed -E 's/^[[:space:]]+//; s/:\[[^]]*\]//; s/\t.*$//; s/[[:space:]]{2,}.*$//; s/[[:space:]]+$//; s/:$//' | \
  grep -v -E '(反馈|使用|推广|详情|频道|价格|解锁|音乐|http|t\.me|TG|BUG|脚本|测试|网络)' | \
  sort | uniq
)

# 获取 TikTok 解锁状态
echo "提示：正在检测 TikTok 解锁状态..."
for attempt in {1..3}; do
  tiktok_content=$(bash <(curl -s https://raw.githubusercontent.com/lmc999/TikTokCheck/main/tiktok.sh))
  if [[ -n "$tiktok_content" ]]; then
    echo "提示：TikTok 检测脚本执行成功"
    break
  fi
  echo "警告：TikTok 检测失败，正在重试 ($attempt/3)..."
  sleep 2
done

if [[ -z "$tiktok_content" ]]; then
  echo "错误：TikTok 检测脚本执行失败，请检查网络或脚本源"
  exit 1
fi

# 将 tiktok_content 保存到日志
echo "$tiktok_content" > /opt/stream/tiktok.log

mapfile -t locked_tiktok < <(echo "$tiktok_content" | \
  grep '\[31m' | \
  grep ':' | \
  sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
  sed -E 's/^[[:space:]]+//; s/:\[[^]]*\]//; s/\t.*$//; s/[[:space:]]{2,}.*$//; s/[[:space:]]+$//; s/:$//' | \
  grep -v -E '(反馈|使用|推广|详情|频道|价格|解锁|音乐|http|t\.me|TG|BUG|脚本|测试|网络)' | \
  sort | uniq
)

# 合并未解锁的平台列表
locked_platforms=()
locked_platforms+=("${locked_media[@]}")
locked_platforms+=("${locked_tiktok[@]}")


# 记录已添加的出口节点和规则
declare -A routes

# 本地未解锁的平台与 API 数据对比 并 获取 PING 最低的节点 进行解锁
for platform in "${locked_platforms[@]}"; do
  # 检查是否存在别名和规则，并避免 null 值导致错误
  alias_list=$(echo "$platforms_json" | jq -r --arg platform "$platform" '.[$platform].alias // empty | select(. != null)[]')
  rules_list=$(echo "$platforms_json" | jq -r --arg platform "$platform" '.[$platform].rules // empty | select(. != null)[]')
  if [[ -z "$alias_list" || -z "$rules_list" ]]; then
    echo "警告：平台 $platform 没有找到别名或规则，跳过。"
    continue
  fi

  # 对别名进行 Ping 测试，找出最优的 alias
  declare -A best_node_info=()
  for alias in $alias_list; do
    # 获取当前节点域名
    node_host=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].host // empty')
    if [[ -z "$node_host" ]]; then
      echo "警告：平台 $platform 节点 $alias 的域名为空，跳过。"
      continue
    fi

    # 进行 Ping 测试，添加重试机制
    for attempt in {1..3}; do
      best_node_info[ping_time]=$(ping -c 1 -W 2 "$node_host" | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
      if [[ -n "${best_node_info[ping_time]}" ]]; then
        break
      fi
    done
    if [[ -z "${best_node_info[ping_time]}" ]]; then
      echo "警告：平台 $platform Ping 节点 $alias 失败，已跳过。"
      continue
    fi
    
    # 更新最优 alias
    if [[ -z "${best_node_info[best_ping]}" || "$(echo "${best_node_info[ping_time]} < ${best_node_info[best_ping]}" | bc -l)" -eq 1 ]]; then
      best_node_info[best_alias]="$alias"
      best_node_info[best_ping]="${best_node_info[ping_time]}"
    fi
  done

  # 增加容错判断是否存在 best_alias
  if [[ -z "${best_node_info[best_alias]}" ]]; then
    echo "警告：无法为平台 $platform 找到最优节点，跳过。"
    continue
  fi

  # 提示相关解锁信息
  echo "提示：平台 $platform 最优节点 ${best_node_info[best_alias]}，延时 ${best_node_info[best_ping]} MS"

  # 将 platform 存入 routes 生成配置文件时读取（添加去重）
  if [[ -z "${routes[${best_node_info[best_alias]}]}" ]]; then
    routes[${best_node_info[best_alias]}]="\"# $platform\""
  else
    # 检查平台注释是否已存在
    if [[ ! "${routes[${best_node_info[best_alias]}]}" =~ \"#\ $platform\" ]]; then
      routes[${best_node_info[best_alias]}]+="^\"# $platform\""
    fi
  fi

  # 将 rules_list 存入 routes 生成配置文件时读取（添加去重）
  for rule in $rules_list; do
    # 检查规则是否已存在
    if [[ ! "${routes[${best_node_info[best_alias]}]}" =~ \"$rule\" ]]; then
      routes[${best_node_info[best_alias]}]+="^\"$rule\""
    fi
  done

done

# 生成 soga 配置文件
routes_file="/etc/soga/routes.toml"
# 清空文件
: > "$routes_file"
echo "enable=true" > "$routes_file"
# 写入路由部分
for alias in $(echo "$nodes_json" | jq -r 'keys[]'); do
  if [[ -z "${routes[$alias]}" ]]; then
    echo "警告：节点 $alias 没有任何规则，跳过。"
    continue
  fi

  # 写入路由规则
  echo '' >> "$routes_file"
  echo "# 路由 $alias" >> "$routes_file"
  echo '[[routes]]' >> "$routes_file"
  echo 'rules=[' >> "$routes_file"
  
  # 设置分隔符
  IFS='^'
  for rule in ${routes[$alias]}; do
    echo "  $rule," >> "$routes_file"
  done
  unset IFS
  echo ']' >> "$routes_file"

  # 获取节点信息
  node_type=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].type // empty')
  node_host=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].host // empty')
  node_port=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].port // empty')
  node_value1=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value1 // empty')
  node_value2=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value2 // empty')
  node_value3=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value3 // empty')
  node_value4=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value4 // empty')
  node_value5=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value5 // empty')
  node_value6=$(echo "$nodes_json" | jq -r --arg alias "$alias" '.[$alias].value6 // empty')

  # 写入出口节点
  echo '' >> "$routes_file"
  echo "# 出口 $alias" >> "$routes_file"
  echo '[[routes.Outs]]' >> "$routes_file"
  echo "type=\"$node_type\"" >> "$routes_file"
  echo "server=\"$node_host\"" >> "$routes_file"
  echo "port=$node_port" >> "$routes_file"
  case "$node_type" in
    "ss")
      echo "password=\"$node_value1\"" >> "$routes_file"
      echo "cipher=\"$node_value2\"" >> "$routes_file"
      ;;
    "trojan")
      echo "password=\"$node_value1\"" >> "$routes_file"
      echo "sin=\"$node_value2\"" >> "$routes_file"
      # skip_cert_verify 1/0 转为 true/false
      if [[ "$node_value3" == "1" ]]; then
        echo "skip_cert_verify=true" >> "$routes_file"
      else
        echo "skip_cert_verify=false" >> "$routes_file"
      fi
      ;;
    "http")
      echo "username=\"$node_value1\"" >> "$routes_file"
      echo "password=\"$node_value2\"" >> "$routes_file"
      ;;
    "socks")
      echo "username=\"$node_value1\"" >> "$routes_file"
      echo "password=\"$node_value2\"" >> "$routes_file"
      ;;
    *)
      # 其他类型可扩展
      ;;
  esac
done

# 添加全局路由规则
echo '' >> "$routes_file"
echo '# 路由 ALL' >> "$routes_file"
echo '[[routes]]' >> "$routes_file"
echo 'rules=["*"]' >> "$routes_file"
echo '' >> "$routes_file"
echo '# 出口 ALL' >> "$routes_file"
echo '[[routes.Outs]]' >> "$routes_file"
echo 'type="direct"' >> "$routes_file"


echo "提示：已自动生成 soga 配置文件"
