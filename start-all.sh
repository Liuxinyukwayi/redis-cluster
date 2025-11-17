#!/bin/bash

# ========== 配置区 ==========
SSH_USER=root
SSH_PASS=admin@123
REDIS_SERVER_BIN=/usr/bin/redis-server
REDIS_CLI_BIN=/usr/bin/redis-cli
REDIS_PASSWORD=admin@123
REMOTE_BASE_DIR=/redis-cluster
NODE_IPS=("192.168.194.130" "192.168.194.129" "192.168.194.131")
INSTANCES_PER_NODE=2
BASE_PORT=6380

LOG_FILE="/tmp/redis-start.log"

echo "=== Redis 集群启动脚本 ==="
> "$LOG_FILE"

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
        echo "✔ 已启动"
    else
        echo "❌ 未启动"
    fi
}

# ========== 主逻辑：启动所有实例 ==========
for index in "${!NODE_IPS[@]}"; do
    NODE_ID=$((index + 1))
    IP=${NODE_IPS[$index]}

    for inst in $(seq 1 $INSTANCES_PER_NODE); do
	PORT=$((BASE_PORT + (index * INSTANCES_PER_NODE) + inst - 1))
        INSTANCE_DIR="$REMOTE_BASE_DIR/node-$NODE_ID/inst-$inst"

        echo "----------------------------------------"
        echo "➡ 启动 Node-$NODE_ID Instance-$inst ($IP:$PORT)"

        # 启动 redis-server
        remote_exec $IP "nohup $REDIS_SERVER_BIN $INSTANCE_DIR/redis.conf > $INSTANCE_DIR/logs/startup.log 2>&1 &"

        sleep 2
        check_port $IP $PORT
    done
done

echo "=== 启动完成 ==="

