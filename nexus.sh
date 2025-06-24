#!/bin/bash
set -e

BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"

# 检查 Docker 是否安装
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "检测到未安装 Docker，正在安装..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update
        apt install -y docker-ce
        systemctl enable docker
        systemctl start docker
    fi
}

# 检查并安装 cron 服务
function check_cron() {
    if ! command -v cron >/dev/null 2>&1; then
        echo "检测到未安装 cron，正在安装..."
        apt update
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi
}

# 构建docker镜像函数
function build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \
    curl \
    screen \
    bash \
    && rm -rf /var/lib/apt/lists/*

# 自动下载安装最新版 nexus-network
RUN curl -sSL https://cli.nexus.xyz/ | NONINTERACTIVE=1 sh \
    && ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$NODE_ID" ]; then
    echo "错误：未设置 NODE_ID 环境变量"
    exit 1
fi

echo "\$NODE_ID" > "\$PROVER_ID_FILE"
echo "使用的 node-id: \$NODE_ID"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "错误：nexus-network 未安装或不可用"
    exit 1
fi

screen -S nexus -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network 节点..."
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

sleep 3

if screen -list | grep -q "nexus"; then
    echo "节点已在后台启动。"
    echo "日志文件：/root/nexus.log"
    echo "可以使用 docker logs \$CONTAINER_NAME 查看日志"
else
    echo "节点启动失败，请检查日志。"
    cat /root/nexus.log
    exit 1
fi

tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .

    cd -
    rm -rf "$WORKDIR"
}

# 启动容器（挂载宿主机日志文件，并设置每日删除日志的cron任务）
function run_container() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-rotate"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"

    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "检测到旧容器 $container_name，先删除..."
        docker rm -f "$container_name"
    fi

    # 确保日志目录存在
    mkdir -p "$LOG_DIR"
    
    # 确保宿主机日志文件存在并有写权限
    if [ ! -f "$log_file" ]; then
        touch "$log_file"
        chmod 644 "$log_file"
    fi

    # 启动容器
    docker run -d --name "$container_name" -e NODE_ID="$node_id" "$IMAGE_NAME"
    echo "容器 $container_name 已启动！"

    # 检查并安装 cron
    check_cron

    # 设置每日删除日志文件的 cron 任务
    local cron_job="0 0 * * * rm -f $log_file"
    local cron_file="/etc/cron.d/nexus-log-cleanup-${node_id}"

    # 清理旧的同名 cron 任务
    if [ -f "$cron_file" ]; then
        rm -f "$cron_file"
    fi

    # 创建新的 cron 任务
    echo "$cron_job" > "$cron_file"
    chmod 0644 "$cron_file"
    echo "已为节点 $node_id 设置每日凌晨删除日志文件的 cron 任务"
}

# 停止并卸载容器和镜像、删除日志及相关cron任务
function uninstall_node() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    local log_file="${LOG_DIR}/nexus-${node_id}.log"
    local cron_file="/etc/cron.d/nexus-log-cleanup-${node_id}"

    echo "停止并删除容器 $container_name..."
    docker rm -f "$container_name" 2>/dev/null || echo "容器不存在或已停止"

    if [ -f "$log_file" ]; then
        echo "删除日志文件 $log_file ..."
        rm -f "$log_file"
    else
        echo "日志文件不存在：$log_file"
    fi

    if [ -f "$cron_file" ]; then
        echo "删除 cron 任务 $cron_file ..."
        rm -f "$cron_file"
    else
        echo "cron 任务不存在：$cron_file"
    fi

    echo "节点 $node_id 已卸载完成。"
}

# 显示所有运行中的节点
function list_nodes() {
    echo "当前节点状态："
    echo "------------------------------------------------------------------------------------------------------------------------"
    printf "%-6s %-20s %-10s %-10s %-10s %-20s %-20s\n" "序号" "节点ID" "CPU使用率" "内存使用" "内存限制" "状态" "启动时间"
    echo "------------------------------------------------------------------------------------------------------------------------"
    
    local all_nodes=($(get_all_nodes))
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local container_info=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" $container_name 2>/dev/null)
        
        if [ -n "$container_info" ]; then
            # 解析容器信息
            IFS=',' read -r cpu_usage mem_usage mem_limit mem_perc <<< "$container_info"
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            
            # 格式化内存显示
            mem_usage=$(echo $mem_usage | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            mem_limit=$(echo $mem_limit | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            
            # 显示节点信息
            printf "%-6d %-20s %-10s %-10s %-10s %-20s %-20s\n" \
                $((i+1)) \
                "$node_id" \
                "$cpu_usage" \
                "$mem_usage" \
                "$mem_limit" \
                "$(echo $status | cut -d' ' -f1)" \
                "$created_time"
        else
            # 如果容器不存在或未运行
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            local created_time=$(docker ps -a --filter "name=$container_name" --format "{{.CreatedAt}}")
            if [ -n "$status" ]; then
                printf "%-6d %-20s %-10s %-10s %-10s %-20s %-20s\n" \
                    $((i+1)) \
                    "$node_id" \
                    "N/A" \
                    "N/A" \
                    "N/A" \
                    "$(echo $status | cut -d' ' -f1)" \
                    "$created_time"
            fi
        fi
    done
    echo "------------------------------------------------------------------------------------------------------------------------"
    echo "提示："
    echo "- CPU使用率：显示容器CPU使用百分比"
    echo "- 内存使用：显示容器当前使用的内存"
    echo "- 内存限制：显示容器内存使用限制"
    echo "- 状态：显示容器的运行状态"
    echo "- 启动时间：显示容器的创建时间"
    read -p "按任意键返回菜单"
}

# 获取所有运行中的节点ID
function get_running_nodes() {
    docker ps --filter "name=${BASE_CONTAINER_NAME}" --filter "status=running" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# 获取所有节点ID（包括已停止的）
function get_all_nodes() {
    docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# 查看节点日志
function view_node_logs() {
    local node_id=$1
    local container_name="${BASE_CONTAINER_NAME}-${node_id}"
    
    if docker ps -a --format '{{.Names}}' | grep -qw "$container_name"; then
        echo "请选择日志查看模式："
        echo "1. 原始日志（可能包含颜色代码）"
        echo "2. 清理后的日志（移除颜色代码）"
        read -rp "请选择(1-2): " log_mode

        echo "查看日志，按 Ctrl+C 退出日志查看"
        if [ "$log_mode" = "2" ]; then
            docker logs -f "$container_name" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[?25l//g' | sed 's/\x1b\[?25h//g'
        else
            docker logs -f "$container_name"
        fi
    else
        echo "容器未运行，请先安装并启动节点（选项1）"
        read -p "按任意键返回菜单"
    fi
}

# 批量启动多个节点
function batch_start_nodes() {
    echo "请输入多个 node-id，每行一个，输入空行结束："
    echo "（输入完成后按回车键，然后按 Ctrl+D 结束输入）"
    
    local node_ids=()
    while read -r line; do
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "未输入任何 node-id，返回主菜单"
        read -p "按任意键继续"
        return
    fi

    echo "开始构建镜像..."
    build_image

    echo "开始启动节点..."
    for node_id in "${node_ids[@]}"; do
        echo "正在启动节点 $node_id ..."
        run_container "$node_id"
        sleep 2  # 添加短暂延迟，避免同时启动太多容器
    done

    echo "所有节点启动完成！"
    read -p "按任意键返回菜单"
}

# 选择要查看的节点
function select_node_to_view() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "当前没有节点"
        read -p "按任意键返回菜单"
        return
    fi

    echo "请选择要查看的节点："
    echo "0. 返回主菜单"
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
        if [[ $status == Up* ]]; then
            echo "$((i+1)). 节点 $node_id [运行中]"
        else
            echo "$((i+1)). 节点 $node_id [已停止]"
        fi
    done

    read -rp "请输入选项(0-${#all_nodes[@]}): " choice

    if [ "$choice" = "0" ]; then
        return
    fi

    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_nodes[@]} ]; then
        local selected_node=${all_nodes[$((choice-1))]}
        view_node_logs "$selected_node"
    else
        echo "无效的选项"
        read -p "按任意键继续"
    fi
}

# 批量停止并卸载节点
function batch_uninstall_nodes() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "当前没有节点"
        read -p "按任意键返回菜单"
        return
    fi

    echo "当前节点状态："
    echo "----------------------------------------"
    echo "序号  节点ID                状态"
    echo "----------------------------------------"
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
        if [[ $status == Up* ]]; then
            printf "%-6d %-20s [运行中]\n" $((i+1)) "$node_id"
        else
            printf "%-6d %-20s [已停止]\n" $((i+1)) "$node_id"
        fi
    done
    echo "----------------------------------------"

    echo "请选择要删除的节点（可多选，输入数字，用空格分隔）："
    echo "0. 返回主菜单"
    
    read -rp "请输入选项(0 或 数字，用空格分隔): " choices

    if [ "$choices" = "0" ]; then
        return
    fi

    # 将输入的选项转换为数组
    read -ra selected_choices <<< "$choices"
    
    # 验证输入并执行卸载
    for choice in "${selected_choices[@]}"; do
        if [ "$choice" -ge 1 ] && [ "$choice" -le ${#all_nodes[@]} ]; then
            local selected_node=${all_nodes[$((choice-1))]}
            echo "正在卸载节点 $selected_node ..."
            uninstall_node "$selected_node"
        else
            echo "跳过无效选项: $choice"
        fi
    done

    echo "批量卸载完成！"
    read -p "按任意键返回菜单"
}

# 删除全部节点
function uninstall_all_nodes() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "当前没有节点"
        read -p "按任意键返回菜单"
        return
    fi

    echo "警告：此操作将删除所有节点！"
    echo "当前共有 ${#all_nodes[@]} 个节点："
    for node_id in "${all_nodes[@]}"; do
        echo "- $node_id"
    done
    
    read -rp "确定要删除所有节点吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消操作"
        read -p "按任意键返回菜单"
        return
    fi

    echo "开始删除所有节点..."
    for node_id in "${all_nodes[@]}"; do
        echo "正在卸载节点 $node_id ..."
        uninstall_node "$node_id"
    done

    echo "所有节点已删除完成！"
    read -p "按任意键返回菜单"
}

# 主菜单
while true; do
    clear
    echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
    echo "如有问题，可联系推特，仅此只有一个号"
    echo "========== Nexus 多节点管理 =========="
    echo "1. 安装并启动新节点"
    echo "2. 显示所有节点状态"
    echo "3. 批量停止并卸载指定节点"
    echo "4. 查看指定节点日志"
    echo "5. 删除全部节点"
    echo "6. 退出"
    echo "==================================="

    read -rp "请输入选项(1-6): " choice

    case $choice in
        1)
            check_docker
            read -rp "请输入您的 node-id: " NODE_ID
            if [ -z "$NODE_ID" ]; then
                echo "node-id 不能为空，请重新选择。"
                read -p "按任意键继续"
                continue
            fi
            echo "开始构建镜像并启动容器..."
            build_image
            run_container "$NODE_ID"
            echo "使用 docker logs --tail 1000 nexus-node-rotate 查看日志..."
            read -p "按任意键返回菜单"
            ;;
        2)
            list_nodes
            ;;
        3)
            batch_uninstall_nodes
            ;;
        4)
            select_node_to_view
            ;;
        5)
            uninstall_all_nodes
            ;;
        6)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            read -p "按任意键继续"
            ;;
    esac
done
