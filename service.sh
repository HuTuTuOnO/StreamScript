#!/bin/bash

VER='1.0.0'

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
      API="$2"
      shift 2
      ;;
    --ID)
      ID="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 定义配置文件路径
CONFIG_FILE="/opt/stream/service.json"

# 检查配置目录是否存在，如果不存在则创建一个默认配置目录
if [[ ! -d "$(dirname "$CONFIG_FILE")" ]]; then
  echo "提示：配置目录不存在，正在创建一个默认配置目录。"
  mkdir -p "$(dirname "$CONFIG_FILE")"
fi

# 如果传入了 API 或 ID 参数，更新本地配置文件
if [[ -n "$API" || -n "$ID" ]]; then
  # 读取已有配置文件的值（如果文件存在）
  if [[ -f "$CONFIG_FILE" ]]; then
    [[ -z "$API" ]] && API=$(jq -r '.api // empty' "$CONFIG_FILE")
    [[ -z "$ID" ]] && ID=$(jq -r '.id // empty' "$CONFIG_FILE")
  fi
  
  # 保存更新后的 API 和 ID 到配置文件
  mkdir -p "$(dirname "$CONFIG_FILE")"  # 确保目录存在
  jq -n --arg api "$API" --arg id "$ID" '{api: $api, id: $id}' > "$CONFIG_FILE"
  echo "配置已更新到 $CONFIG_FILE"
fi

# 检查配置文件是否存在并读取
if [[ -f "$CONFIG_FILE" ]]; then
  [[ -z "$API" ]] && API=$(jq -r '.api' "$CONFIG_FILE")
  [[ -z "$ID" ]] && ID=$(jq -r '.id' "$CONFIG_FILE")
fi

# 如果未传入API或ID且配置文件中也没有相应值，则报错
if [[ -z "$API" || -z "$ID" ]]; then
  echo "错误：未提供 API,ID，且配置文件中也不存在，无法继续。"
  exit 1
fi

# 获取流媒体解锁状态
MEDIA_CONTENT=$(bash <(curl -L -s check.unlock.media) -M 4 -R 66 2>&1)
# MEDIA_CONTENT=$(cat stream.log)

# 读取流媒体状态（修正正则表达式）
mapfile -t unlocked_platforms < <(echo "$MEDIA_CONTENT" | \
  grep '\[32m' | \
  grep ':' | \
  sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
  sed -E 's/^[[:space:]]+//; s/:	+.*$//; s/:[[:space:]]{5,}.*$//; s/[[:space:]]+$//' | \
  grep -v -E '(反馈|使用|推广|详情|频道|价格|解锁|音乐|http|t\.me|TG|BUG|脚本|测试|网络)'
)

# 打印解锁的平台列表
echo "解锁的平台数量: ${#unlocked_platforms[@]}"
echo "解锁的平台列表:"
for platform in "${unlocked_platforms[@]}"; do
  echo "  - $platform"
done

# 提交到stream平台
res_body=$(curl -X POST -H "Content-Type: application/json" -d "$(jq -n --arg id "$ID" --argjson platforms "$(printf '%s\n' "${unlocked_platforms[@]}" | jq -R . | jq -s .)" '{id: $id, platform: $platforms}')" "$API")
echo "流媒体状态更新结果：$res_body"
