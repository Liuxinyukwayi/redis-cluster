#!/bin/bash
# ========== 配置区 ==========
SSH_USER=root
SSH_PASS=admin@123
REDIS_CLI_BIN=/usr/bin/redis-cli
REDIS_PASSWORD=admin@123
REMOTE_BASE_DIR=/redis-cluster
NODE_IPS=("192.168.194.130" "192.168.194.129" "192.168.194.131")
INSTANCES_PER_NODE=2
BASE_PORT=6380
LOG_FILE="/tmp/redis-stop.log"

echo "=== Redis 集群关闭脚本 ==="
> "$LOG_FILE"  # 清空日志文件

# ========== 函数定义 ==========
remote_exec() {
    ip=$1
    cmd=$2
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no $SSH_USER@$ip "$cmd"
    return ${PIPESTATUS[0]}
}

check_port() {
    ip=$1
    port=$2
    echo -n "检查 $ip:$port ... "
    remote_exec $ip "$REDIS_CLI_BIN -h $ip -p $port -a $REDIS_PASSWORD ping" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✔ 仍在运行"
        return 0  # 仍在运行
    else
        echo "❌ 已关闭"
        return 1  # 已关闭
    fi
}

# ========== 主逻辑：关闭所有实例 ==========
for index in "${!NODE_IPS[@]}"; do
    NODE_ID=$((index + 1))
    IP=${NODE_IPS[$index]}
    for inst in $(seq 1 $INSTANCES_PER_NODE); do
        PORT=$((BASE_PORT + (index * INSTANCES_PER_NODE) + inst - 1))
        INSTANCE_DIR="$REMOTE_BASE_DIR/node-$NODE_ID/inst-$inst"
        echo "----------------------------------------"
        echo "➡ 关闭 Node-$NODE_ID Instance-$inst ($IP:$PORT)"

        # 检查是否在运行，如果在运行则关闭
        if check_port $IP $PORT >/dev/null 2>&1; then
            # 使用 redis-cli 发送 SHUTDOWN 命令（优雅关闭）
            remote_exec $IP "$REDIS_CLI_BIN -h $IP -p $PORT -a $REDIS_PASSWORD SHUTDOWN" >> "$LOG_FILE" 2>&1
            sleep 2  # 等待关闭完成
            # 再次检查
            check_port $IP $PORT
        else
            echo "实例已关闭，无需操作"
        fi
    done
done

echo "=== 关闭完成 ==="
