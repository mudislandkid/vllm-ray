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

    echo -e "${BLUE}Loading in background. Checking...${NC}"

    local attempts=0
    while [ $attempts -lt 120 ]; do
        if curl -s "http://localhost:${VLLM_PORT:-8000}/health" &>/dev/null; then
            echo ""
            echo -e "${GREEN}Model is ready!${NC}"
            echo -e "  API:           http://${HEAD_NODE_IP}:${VLLM_PORT:-8000}/v1"
            echo -e "  Chat UI:       http://${HEAD_NODE_IP}:${WEBUI_PORT:-3000}"
            echo -e "  Ray Dashboard: http://${HEAD_NODE_IP}:8265"
            echo -e "  Grafana:       http://${HEAD_NODE_IP}:${GRAFANA_PORT:-4000}"
            echo -e "  Model:         ${model}"
            return 0
        fi
        attempts=$((attempts + 1))
        [ $((attempts % 10)) -eq 0 ] && echo -e "${BLUE}Still loading... (${attempts}s)${NC}"
        sleep 1
    done

    echo -e "${YELLOW}Server hasn't responded after 120s. Check: $0 logs${NC}"
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
    echo ""
    echo "Examples:"
    echo "  $0 serve Qwen/Qwen2.5-7B-Instruct"
    echo "  $0 serve meta-llama/Llama-3.1-70B-Instruct"
    echo ""
}

case "${1:-help}" in
    up) cmd_up ;; down) cmd_down ;; serve) shift; cmd_serve "$@" ;;
    stop) cmd_stop ;; status) cmd_status ;; logs) shift; cmd_logs "$@" ;;
    logs-follow) cmd_logs_follow ;; models) cmd_models ;; *) cmd_help ;;
esac
