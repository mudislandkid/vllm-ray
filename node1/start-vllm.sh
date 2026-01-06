#!/bin/bash
# Start vLLM server after Ray cluster is ready
# Run this script on Node 1 AFTER both Ray nodes are connected

set -e

# Configuration (override via environment or edit here)
MODEL_NAME="${MODEL_NAME:-meta-llama/Llama-3.1-70B-Instruct}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-2}"
PIPELINE_PARALLEL_SIZE="${PIPELINE_PARALLEL_SIZE:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-4096}"
VLLM_PORT="${VLLM_PORT:-8000}"

echo "============================================"
echo "Checking Ray cluster status..."
echo "============================================"

# Check cluster status
docker exec ray-head ray status

echo ""
echo "============================================"
echo "Verifying GPU count..."
echo "============================================"

GPU_COUNT=$(docker exec ray-head ray status 2>/dev/null | grep -oP '\d+\.\d+ GPU' | head -1 | grep -oP '^\d+' || echo "0")
REQUIRED_GPUS=$((TENSOR_PARALLEL_SIZE * PIPELINE_PARALLEL_SIZE))

echo "Found: ${GPU_COUNT} GPUs"
echo "Required: ${REQUIRED_GPUS} GPUs (TP=${TENSOR_PARALLEL_SIZE} x PP=${PIPELINE_PARALLEL_SIZE})"

if [ "$GPU_COUNT" -lt "$REQUIRED_GPUS" ]; then
    echo ""
    echo "ERROR: Not enough GPUs in cluster!"
    echo "Make sure Node 2 worker is connected before starting vLLM."
    echo ""
    echo "Check Node 2 with: docker compose logs -f"
    exit 1
fi

echo ""
echo "============================================"
echo "Starting vLLM server..."
echo "============================================"
echo "Model: $MODEL_NAME"
echo "Tensor Parallel: $TENSOR_PARALLEL_SIZE"
echo "Pipeline Parallel: $PIPELINE_PARALLEL_SIZE"
echo "Max Model Len: $MAX_MODEL_LEN"
echo "Port: $VLLM_PORT"
echo "============================================"

# Start vLLM inside the ray-head container
docker exec -it ray-head vllm serve "$MODEL_NAME" \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE" \
    --pipeline-parallel-size "$PIPELINE_PARALLEL_SIZE" \
    --distributed-executor-backend ray \
    --trust-remote-code \
    --dtype auto \
    --max-model-len "$MAX_MODEL_LEN"
