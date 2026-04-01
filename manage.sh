#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -z "$HF_TOKEN" ]; then
    TOKEN_FILE="/home/vectir/.cache/huggingface/token"
    [ -f "$TOKEN_FILE" ] && export HF_TOKEN=$(cat "$TOKEN_FILE")
fi

print_header() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}       vLLM Cluster Manager             ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

cmd_serve() {
    local model="${1:-$MODEL_NAME}"
    local tp="${2:-$TENSOR_PARALLEL_SIZE}"
    local pp="${3:-$PIPELINE_PARALLEL_SIZE}"
    local max_len="${4:-$MAX_MODEL_LEN}"
    local gpu_util="${5:-$GPU_MEMORY_UTILIZATION}"

    if [ -z "$model" ]; then
        echo -e "${RED}No model specified. Usage: $0 serve <model_name>${NC}"
        exit 1
    fi

    if ! docker exec ray-head ray status &>/dev/null; then
        echo -e "${RED}Ray cluster not ready. Start with: $0 up${NC}"
        exit 1
    fi

    if docker exec ray-head pgrep -f "vllm serve" &>/dev/null; then
        echo -e "${YELLOW}Stopping current model...${NC}"
        docker exec ray-head pkill -f "vllm serve" 2>/dev/null || true
        sleep 5
    fi

    echo -e "${BLUE}Starting model: ${model}${NC}"
    echo -e "${BLUE}  TP=${tp} PP=${pp} MaxLen=${max_len} GPUUtil=${gpu_util}${NC}"

    # Clear old log
    docker exec ray-head bash -c "> /tmp/vllm-serve.log" 2>/dev/null

    docker exec -d ray-head bash -c \
        "HF_TOKEN=${HF_TOKEN} vllm serve '${model}' \
            --tensor-parallel-size ${tp} \
            --pipeline-parallel-size ${pp} \
            --max-model-len ${max_len} \
            --gpu-memory-utilization ${gpu_util} \
            --distributed-executor-backend ray \
            --host 0.0.0.0 \
            --port ${VLLM_PORT:-8000} \
            2>&1 | tee /tmp/vllm-serve.log"

    echo ""
    echo -e "${BLUE}Waiting for vLLM to start (tailing logs)...${NC}"
    echo -e "${BLUE}Press Ctrl+C to stop watching (server continues in background)${NC}"
    echo ""

    # Give vLLM a moment to create the log file
    sleep 2

    # Tail the log in background, colorizing key lines
    docker exec ray-head tail -f /tmp/vllm-serve.log 2>/dev/null | while IFS= read -r line; do
        # Detect errors and fatal messages
        if echo "$line" | grep -qiE "(error|exception|traceback|failed|fatal|CUDA out of memory|OOM)"; then
            echo -e "  ${RED}✗ ${line}${NC}"
        # Detect download/fetch progress
        elif echo "$line" | grep -qiE "(downloading|fetching|download|\.safetensors|\.bin|%\|)"; then
            echo -e "  ${CYAN}↓ ${line}${NC}"
        # Detect model loading stages
        elif echo "$line" | grep -qiE "(loading|loaded|initializ|warming up|profiling|creating|starting|memory|weight)"; then
            echo -e "  ${YELLOW}⟳ ${line}${NC}"
        # Detect ready / serving state
        elif echo "$line" | grep -qiE "(started server|uvicorn running|application startup complete|serving)"; then
            echo -e "  ${GREEN}✓ ${line}${NC}"
        # Detect warnings
        elif echo "$line" | grep -qiE "(warning|warn)"; then
            echo -e "  ${YELLOW}⚠ ${line}${NC}"
        # Detect Ray cluster info
        elif echo "$line" | grep -qiE "(ray|worker|node|gpu|placement)"; then
            echo -e "  ${BLUE}◆ ${line}${NC}"
        else
            echo "  $line"
        fi
    done &
    local tail_pid=$!

    # Poll health endpoint in parallel
    local attempts=0
    local max_attempts=300
    while [ $attempts -lt $max_attempts ]; do
        if curl -s "http://localhost:${VLLM_PORT:-8000}/health" &>/dev/null; then
            # Kill the tail process
            kill $tail_pid 2>/dev/null
            wait $tail_pid 2>/dev/null

            echo ""
            echo -e "${GREEN}════════════════════════════════════════${NC}"
            echo -e "${GREEN}  Model is ready! (took ~${attempts}s)${NC}"
            echo -e "${GREEN}════════════════════════════════════════${NC}"
            echo ""
            echo -e "  API:           http://${HEAD_NODE_IP}:${VLLM_PORT:-8000}/v1"
            echo -e "  Chat UI:       http://${HEAD_NODE_IP}:${WEBUI_PORT:-3000}"
            echo -e "  Ray Dashboard: http://${HEAD_NODE_IP}:8265"
            echo -e "  Grafana:       http://${HEAD_NODE_IP}:${GRAFANA_PORT:-4000}"
            echo -e "  Model:         ${model}"
            echo ""
            return 0
        fi

        # Check if vLLM process died
        if ! docker exec ray-head pgrep -f "vllm serve" &>/dev/null; then
            kill $tail_pid 2>/dev/null
            wait $tail_pid 2>/dev/null

            echo ""
            echo -e "${RED}════════════════════════════════════════${NC}"
            echo -e "${RED}  vLLM process died during startup!${NC}"
            echo -e "${RED}════════════════════════════════════════${NC}"
            echo ""
            echo -e "${RED}Last 20 lines of log:${NC}"
            docker exec ray-head tail -n 20 /tmp/vllm-serve.log 2>/dev/null
            echo ""
            return 1
        fi

        attempts=$((attempts + 1))
        sleep 1
    done

    kill $tail_pid 2>/dev/null
    wait $tail_pid 2>/dev/null

    echo ""
    echo -e "${YELLOW}Server hasn't responded after ${max_attempts}s.${NC}"
    echo -e "${YELLOW}It may still be loading. Check: $0 logs-follow${NC}"
}

cmd_stop() {
    echo -e "${BLUE}Stopping model...${NC}"
    docker exec ray-head pkill -f "vllm serve" 2>/dev/null || true
    sleep 3
    docker exec ray-head pkill -9 -f "vllm serve" 2>/dev/null || true
    echo -e "${GREEN}Model stopped. Cluster still running.${NC}"
}

cmd_status() {
    print_header

    echo -e "${CYAN}--- Ray Cluster ---${NC}"
    if docker exec ray-head ray status &>/dev/null; then
        docker exec ray-head python3 -c "
import ray; ray.init(address='auto')
nodes = [n for n in ray.nodes() if n['Alive']]
gpus = sum(n['Resources'].get('GPU', 0) for n in nodes)
cpus = sum(n['Resources'].get('CPU', 0) for n in nodes)
print(f'  Status: UP | Nodes: {len(nodes)} | GPUs: {int(gpus)} | CPUs: {int(cpus)}')
" 2>/dev/null
    else
        echo -e "  ${RED}Cluster is DOWN${NC}"
    fi

    echo -e "${CYAN}--- vLLM Server ---${NC}"
    if curl -s "http://localhost:${VLLM_PORT:-8000}/health" &>/dev/null; then
        curl -s "http://localhost:${VLLM_PORT:-8000}/v1/models" 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for m in data.get('data',[]): print(f'  Model: {m[\"id\"]}')
" 2>/dev/null
    else
        echo -e "  ${YELLOW}No model loaded${NC}"
    fi

    echo -e "${CYAN}--- Local GPUs ---${NC}"
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | while read line; do echo "  $line"; done

    echo -e "${CYAN}--- Services ---${NC}"
    echo "  API:           http://${HEAD_NODE_IP}:${VLLM_PORT:-8000}/v1"
    echo "  Chat UI:       http://${HEAD_NODE_IP}:${WEBUI_PORT:-3000}"
    echo "  Ray Dashboard: http://${HEAD_NODE_IP}:8265"
    echo "  Grafana:       http://${HEAD_NODE_IP}:${GRAFANA_PORT:-4000}"
    echo "  Prometheus:    http://${HEAD_NODE_IP}:${PROMETHEUS_PORT:-9090}"
    echo ""
}

cmd_logs() { docker exec ray-head tail -n "${1:-100}" /tmp/vllm-serve.log 2>/dev/null || echo "No logs found."; }
cmd_logs_follow() { docker exec ray-head tail -f /tmp/vllm-serve.log 2>/dev/null || echo "No logs found."; }

cmd_fix_dashboards() {
    echo -e "${BLUE}Copying Ray Grafana dashboards...${NC}"

    # Find the Ray session directory inside the container
    local session
    session=$(docker exec ray-head find /tmp/ray -maxdepth 1 -name "session_*" -type d 2>/dev/null | sort | tail -1)

    if [ -z "$session" ]; then
        echo -e "${RED}No Ray session found. Is the ray-head container running?${NC}"
        exit 1
    fi

    echo -e "${BLUE}Found session: ${session}${NC}"

    # Create temp dir and extract dashboards from ray-head
    rm -rf /tmp/ray-dashboards
    mkdir -p /tmp/ray-dashboards

    for f in $(docker exec ray-head ls "${session}/metrics/grafana/dashboards/"); do
        docker cp "ray-head:${session}/metrics/grafana/dashboards/${f}" /tmp/ray-dashboards/
    done
    
    local count
    count=$(ls /tmp/ray-dashboards/*.json 2>/dev/null | wc -l)

    if [ "$count" -eq 0 ]; then
        echo -e "${RED}No dashboard JSON files found in Ray session.${NC}"
        exit 1
    fi

    echo -e "${BLUE}Found ${count} dashboard(s). Copying to Grafana...${NC}"

    # Copy into Grafana container
    docker cp /tmp/ray-dashboards/. grafana:/var/lib/grafana/dashboards/

    # Restart Grafana to pick them up
    docker restart grafana
    sleep 3

    echo -e "${GREEN}Done! ${count} dashboard(s) loaded into Grafana.${NC}"
    echo -e "${GREEN}View at: http://${HEAD_NODE_IP}:${GRAFANA_PORT:-4000}${NC}"

    # Clean up
    rm -rf /tmp/ray-dashboards
}

cmd_up() {
    echo -e "${BLUE}Starting cluster and services...${NC}"
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose-head.yml up -d --build
    echo -e "${GREEN}Head node started.${NC}"
    echo ""
    echo "Now on VM2 run:"
    echo "  cd ~/vllm-cluster && docker compose -f docker-compose-worker.yml up -d --build"
    echo ""
    echo "Then load a model:"
    echo "  $0 serve <model_name>"
    echo ""
    echo "To set up Grafana dashboards:"
    echo "  $0 fix-dashboards"
}

cmd_down() {
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose-head.yml down
    echo -e "${GREEN}All services stopped.${NC}"
}

cmd_models() {
    echo ""
    echo -e "${CYAN}Recommended models (4x L40 = 192GB VRAM):${NC}"
    echo ""
    echo "  Small:   Qwen/Qwen2.5-7B-Instruct"
    echo "           mistralai/Mistral-7B-Instruct-v0.3"
    echo ""
    echo "  Medium:  Qwen/Qwen2.5-32B-Instruct"
    echo "           deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
    echo "           mistralai/Mixtral-8x7B-Instruct-v0.1"
    echo ""
    echo "  Large:   meta-llama/Llama-3.1-70B-Instruct"
    echo "           neuralmagic/Meta-Llama-3.1-70B-Instruct-FP8 (recommended)"
    echo ""
}

cmd_help() {
    print_header
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "  up                        Start cluster + services"
    echo "  down                      Stop everything"
    echo "  serve <model> [tp] [pp]   Load a model"
    echo "  stop                      Unload model"
    echo "  status                    Show cluster status"
    echo "  logs [lines]              Show vLLM logs"
    echo "  logs-follow               Follow logs live"
    echo "  models                    List recommended models"
    echo "  fix-dashboards            Copy Ray dashboards into Grafana"
    echo ""
    echo "Examples:"
    echo "  $0 up                                           # Start cluster"
    echo "  $0 serve Qwen/Qwen2.5-7B-Instruct              # Quick test"
    echo "  $0 serve meta-llama/Llama-3.1-70B-Instruct      # Full 70B"
    echo "  $0 fix-dashboards                               # Setup Grafana"
    echo ""
}

case "${1:-help}" in
    up) cmd_up ;; down) cmd_down ;; serve) shift; cmd_serve "$@" ;;
    stop) cmd_stop ;; status) cmd_status ;; logs) shift; cmd_logs "$@" ;;
    logs-follow) cmd_logs_follow ;; models) cmd_models ;;
    fix-dashboards) cmd_fix_dashboards ;; *) cmd_help ;;
esac
