#!/bin/bash

ver='1.0.0'

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

# 检查并安装 JQ 
if ! command -v jq &> /dev/null; then
  echo "提示：JQ 未安装，正在安装..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update
    apt-get install -y jq
  else
    echo "错误：不支持的操作系统，请手动安装 JQ"
    exit 1
  fi
fi

# 解析传入的参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --API)
      api="$2"
      shift 2
      ;;
    --ID)
      id="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 定义配置文件路径
config_file="/opt/stream/service.json"

# 读取配置文件设置默认值
if [[ -f "$config_file" ]]; then
  api=${api:-$(jq -r '.api' "$config_file")}
  id=${id:-$(jq -r '.id' "$config_file")}
  exclude_platforms=$(jq -r '.exclude // empty' "$config_file")
fi

# 如果传入了 API 或 ID 参数，更新本地配置文件
if [[ -n "$api" || -n "$id" ]]; then
  mkdir -p "$(dirname "$config_file")"
  jq -n --arg api "$api" --arg id "$id" --arg exclude "$exclude_platforms" '{api: $api, id: $id, exclude: $exclude}' > "$config_file"
  echo "配置已更新到 $config_file"
fi

# 如果未传入API或ID且配置文件中也没有相应值，则报错
if [[ -z "$api" || -z "$id" ]]; then
  echo "错误：未提供 API,ID，且配置文件中也不存在，无法继续。"
  exit 1
fi

# 获取流媒体解锁状态
echo "提示：正在检测流媒体解锁状态..."
for attempt in {1..3}; do
  media_content=$(echo | bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh) -M 4 2>&1)
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
mapfile -t unlocked_platforms < <(echo "$media_content" | \
  grep '\[32m' | \
  grep ':' | \
  sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
  sed -E 's/^[[:space:]]+//; s/:\[[^]]*\]//; s/\t.*$//; s/[[:space:]]{2,}.*$//; s/[[:space:]]+$//; s/:$//' | \
  grep -v -E '(反馈|使用|推广|详情|频道|价格|解锁|音乐|http|t\.me|TG|BUG|脚本|测试|网络)' | \
  sort | uniq
)

# 标准化平台名称映射
# 平台原名以 lmc999 提供的名称为准
# [平台原名]="标准化名称"
declare -A platform_map=(
  # ["Netflix"]="Netflix"
)

for platform in "${unlocked_platforms[@]}"; do
  std_platform=${platform_map[$platform]:-$platform}
  standardized_platforms+=("$std_platform")
done

# 过滤 exclude_platforms 平台
for platform in "${standardized_platforms[@]}"; do
  if [[ ! " $exclude_platforms " =~ " $platform " ]]; then
    filtered_platforms+=("$platform")
  fi
done

echo "解锁的平台数量: ${#filtered_platforms[@]}"
echo "解锁的平台列表:"
for platform in "${filtered_platforms[@]}"; do
  echo "  - $platform"
done

# 提交到stream平台
res_body=$(curl -X POST -H "Content-Type: application/json" -d "$(jq -n --arg id "$id" --argjson platforms "$(printf '%s\n' "${filtered_platforms[@]}" | jq -R . | jq -s .)" '{id: $id, platform: $platforms}')" "$api")
echo "流媒体状态更新结果：$res_body"
