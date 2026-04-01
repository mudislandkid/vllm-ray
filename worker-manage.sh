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
    echo -e "${CYAN}       vLLM Worker Node Manager         ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

cmd_up() {
    echo -e "${BLUE}Starting worker node...${NC}"
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose-worker.yml up -d --build
    echo -e "${GREEN}Worker node started.${NC}"
    echo ""
    echo -e "Connecting to head node at ${HEAD_NODE_IP:-10.50.100.100}:6379"
    echo ""
    echo "Check connection with:"
    echo "  $0 status"
}

cmd_down() {
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose-worker.yml down
    echo -e "${GREEN}Worker node stopped.${NC}"
}

cmd_status() {
    print_header

    echo -e "${CYAN}--- Worker Container ---${NC}"
    if docker ps --format '{{.Names}}' | grep -q ray-worker; then
        echo -e "  ${GREEN}ray-worker is running${NC}"
        docker exec ray-worker ray status 2>/dev/null || echo -e "  ${YELLOW}Cannot reach Ray cluster${NC}"
    else
        echo -e "  ${RED}ray-worker is not running${NC}"
    fi

    echo -e "${CYAN}--- Local GPUs ---${NC}"
    nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | while read line; do echo "  $line"; done

    echo -e "${CYAN}--- Connection ---${NC}"
    echo "  Head node: ${HEAD_NODE_IP:-10.50.100.100}:6379"
    echo "  Worker IP: ${WORKER_NODE_IP:-not set}"
    echo ""
}

cmd_logs() {
    docker compose -f docker-compose-worker.yml logs --tail "${1:-100}" ray-worker
}

cmd_logs_follow() {
    docker compose -f docker-compose-worker.yml logs -f ray-worker
}

cmd_help() {
    print_header
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "  up              Start worker node"
    echo "  down            Stop worker node"
    echo "  status          Show worker status and GPU info"
    echo "  logs [lines]    Show worker logs"
    echo "  logs-follow     Follow worker logs live"
    echo ""
    echo "Examples:"
    echo "  $0 up           # Start and connect to head node"
    echo "  $0 status       # Check connection to cluster"
    echo "  $0 logs-follow  # Watch worker logs"
    echo ""
}

case "${1:-help}" in
    up) cmd_up ;; down) cmd_down ;; status) cmd_status ;;
    logs) shift; cmd_logs "$@" ;; logs-follow) cmd_logs_follow ;;
    *) cmd_help ;;
esac
