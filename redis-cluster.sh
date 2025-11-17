#!/bin/bash
# -------------------------------------------------------
# 多机远程部署 Redis Cluster 自动脚本（支持三主三从）
# -------------------------------------------------------
####################【可修改变量区】####################
# Redis 节点 IP（扩容只需增加 IP）
NODE_IPS=("192.168.194.130" "192.168.194.129" "192.168.194.131")
# 每个节点的实例数（为实现 3 主 3 从，总实例数 = IP 数 * 该值，应为 6）
INSTANCES_PER_NODE=2
# 端口基数（每个实例端口 = BASE_PORT + (instance_id - 1)）
BASE_PORT=6380
# SSH 登录账号
SSH_USER="root"
SSH_PASS="admin@123"
# Redis 密码
REDIS_PASSWORD="admin@123"
# 远程部署根目录
REMOTE_BASE_DIR="/redis-cluster"
# Redis 安装路径
REDIS_SERVER_BIN="/usr/bin/redis-server"
REDIS_CLI_BIN="/usr/bin/redis-cli"
# 日志文件（用于捕获错误）
LOG_FILE="/tmp/redis-cluster-deploy.log"
####################【脚本开始执行】####################
echo "=== Redis 多机自动部署脚本启动 ==="
# 清空日志文件
> "$LOG_FILE"

# 函数：远程执行命令并检查退出码
remote_exec() {
    local ip=$1
    local cmd=$2
    # 在远程运行命令，stderr 追加到本地日志
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no $SSH_USER@$ip "$cmd" 2>>"$LOG_FILE"
    return ${PIPESTATUS[0]}
}

# 函数：检查 Redis 实例是否启动（支持指定端口）
check_redis_started() {
    local ip=$1
    local port=$2
    echo "➡ 检查 Redis 是否启动于 $ip:$port"
    # 在远程用 localhost 方式检查，避免因为绑定/路由问题导致连接失败
    remote_exec $ip "$REDIS_CLI_BIN -p $port -a $REDIS_PASSWORD ping" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✔ Redis 已启动于 $ip:$port"
        return 0
    else
        echo "❌ Redis 启动失败于 $ip:$port" | tee -a "$LOG_FILE"
        # 把该节点所有实例的启动日志都抓过来（由远程 shell 展开通配符）
        remote_exec $ip "cat $REMOTE_BASE_DIR/node-*/inst-*/logs/startup.log $REMOTE_BASE_DIR/node-*/inst-*/logs/redis.log" >> "$LOG_FILE" 2>&1
        return 1
    fi
}

# 循环部署每个节点和其实例
all_started=true
instance_counter=0  # 全局实例计数，用于唯一 ID
NODE_ADDRS=""

for index in "${!NODE_IPS[@]}"; do
    NODE_ID=$((index + 1))
    IP=${NODE_IPS[$index]}

    for inst in $(seq 1 $INSTANCES_PER_NODE); do
        instance_counter=$((instance_counter + 1))

        # ---- 使用全局 instance_counter 计算唯一端口 ----
        PORT=$((BASE_PORT + instance_counter - 1))

        INSTANCE_DIR="$REMOTE_BASE_DIR/node-$NODE_ID/inst-$inst"
        echo "----------------------------------------"
        echo "➡ 部署 Node-$NODE_ID Instance-$inst ($IP:$PORT)"

        # 先在远程创建实例目录（包括 logs）
        remote_exec $IP "mkdir -p $INSTANCE_DIR/logs"
        if [ $? -ne 0 ]; then
            echo "❌ 创建目录失败于 $IP:$PORT" | tee -a "$LOG_FILE"
            all_started=false
            continue
        fi

        echo "➡ 生成 redis.conf (本地临时文件: /tmp/redis-$NODE_ID-$inst.conf)"
        # 本地生成配置文件（注意：使用不带引号的 <<EOF 以便变量展开）
        CONF_FILE="/tmp/redis-$NODE_ID-$inst.conf"
        cat > "$CONF_FILE" <<EOF
bind 0.0.0.0
daemonize yes
protected-mode no
port $PORT
requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
appendonly yes
dir $INSTANCE_DIR
logfile "$INSTANCE_DIR/logs/redis.log"
EOF

        # 上传配置文件到远程实例目录
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no "$CONF_FILE" $SSH_USER@$IP:$INSTANCE_DIR/redis.conf 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            echo "❌ 上传配置文件失败于 $IP:$PORT" | tee -a "$LOG_FILE"
            all_started=false
            continue
        fi

        echo "➡ 启动 redis-server ($IP:$PORT)"
        remote_exec $IP "nohup $REDIS_SERVER_BIN $INSTANCE_DIR/redis.conf > $INSTANCE_DIR/logs/startup.log 2>&1 &"
        if [ $? -ne 0 ]; then
            echo "❌ 启动命令执行失败于 $IP:$PORT" | tee -a "$LOG_FILE"
            all_started=false
            continue
        fi

        # 等待以确保启动
        sleep 3

        # 检查是否启动成功
        check_redis_started $IP $PORT
        if [ $? -ne 0 ]; then
            all_started=false
            # 继续部署其他实例，但记录失败
        fi

        # 将该实例地址加入 NODE_ADDRS（用于 later cluster create）
        NODE_ADDRS="$NODE_ADDRS $IP:$PORT"
    done
done

echo "----------------------------------------"
if ! $all_started; then
    echo "❌ 部分或所有 Redis 实例启动失败。请检查日志: $LOG_FILE"
    cat "$LOG_FILE"
    exit 1
fi

echo "➡ 所有 Redis 实例已启动，准备创建集群..."
# trim leading spaces from NODE_ADDRS
NODE_ADDRS=$(echo "$NODE_ADDRS" | xargs)
echo "➡ 集群节点: $NODE_ADDRS"

# 在第一个节点创建集群（按 --cluster-replicas 1）
FIRST_IP=${NODE_IPS[0]}
echo "➡ 在 $FIRST_IP 上运行 cluster create ..."
CREATE_OUTPUT=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no $SSH_USER@$FIRST_IP "
    yes yes | $REDIS_CLI_BIN --cluster create $NODE_ADDRS --cluster-replicas 1 -a $REDIS_PASSWORD 2>&1
")
CREATE_EXIT=$?
echo "$CREATE_OUTPUT" >> "$LOG_FILE"

if [ $CREATE_EXIT -eq 0 ]; then
    echo "✔ Redis Cluster 创建成功！"
    echo "$CREATE_OUTPUT"
else
    echo "❌ Redis Cluster 创建失败！"
    echo "错误日志:"
    cat "$LOG_FILE"
    exit 1
fi

echo "=== 自动部署完成 ==="

