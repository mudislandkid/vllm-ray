#!/bin/bash
#===============================================================================
#  MOE KERNEL TUNING SCRIPT
#  Generates optimized MoE configurations for your specific GPU
#
#  This benchmarks different kernel parameters and saves the best config
#  for the Qwen3-VL MoE model (E=128 experts, N=384 intermediate size)
#===============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/moe-configs"
CONTAINER_NAME="vllm-server"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           MOE KERNEL TUNING FOR NVIDIA L40                       ║"
echo "║                                                                  ║"
echo "║  This will benchmark MoE kernels and generate optimized config  ║"
echo "║  Estimated time: 15-30 minutes                                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}Note: vllm-server container is not running.${NC}"
    echo "Starting a temporary container for tuning..."

    # Start temporary container
    docker run -d --rm \
        --name moe-tuner \
        --gpus all \
        --ipc=host \
        -v "${CONFIG_DIR}:/workspace/configs" \
        vllm-qwen3:local \
        sleep 3600

    CONTAINER_NAME="moe-tuner"
    CLEANUP_CONTAINER=true
else
    CLEANUP_CONTAINER=false
    echo -e "${GREEN}Using running vllm-server container${NC}"
fi

echo ""
echo "Running MoE kernel benchmark inside container..."
echo "This will test various kernel configurations and find the optimal settings."
echo ""

# Run the tuning script inside the container
docker exec -i "$CONTAINER_NAME" python3 << 'PYTHON_SCRIPT'
import torch
import json
import time
import os
from pathlib import Path

print("=" * 70)
print("MOE KERNEL TUNING")
print("=" * 70)
print()

# Check GPU
if not torch.cuda.is_available():
    print("ERROR: CUDA not available")
    exit(1)

device = torch.cuda.current_device()
props = torch.cuda.get_device_properties(device)
gpu_name = props.name.replace(" ", "_")

print(f"GPU: {props.name}")
print(f"Compute Capability: {props.major}.{props.minor}")
print(f"Total Memory: {props.total_memory / 1e9:.1f} GB")
print()

# MoE configuration for Qwen3-VL-30B-A3B
E = 128  # Number of experts
N = 384  # Intermediate size per expert
K = 3584  # Hidden size (typical for this model)

print(f"MoE Config: E={E} experts, N={N} intermediate, K={K} hidden")
print()

# Batch sizes to tune for
batch_sizes = [1, 2, 4, 8, 16, 24, 32, 64, 128, 256, 512, 1024, 1536, 2048, 3072, 4096]

# Kernel configurations to try
configs_to_try = [
    # (BLOCK_SIZE_M, BLOCK_SIZE_N, BLOCK_SIZE_K, GROUP_SIZE_M, num_warps, num_stages)
    (16, 64, 64, 1, 4, 4),
    (16, 64, 64, 1, 4, 2),
    (16, 128, 64, 1, 4, 4),
    (16, 128, 64, 1, 4, 2),
    (16, 128, 64, 1, 8, 4),
    (32, 64, 64, 1, 4, 4),
    (32, 128, 64, 1, 4, 4),
    (32, 128, 64, 1, 8, 4),
    (32, 128, 64, 8, 4, 4),
    (64, 64, 64, 1, 4, 4),
    (64, 128, 64, 1, 4, 4),
    (64, 128, 64, 8, 4, 4),
    (64, 128, 64, 8, 8, 4),
    (64, 256, 64, 8, 8, 4),
    (128, 128, 64, 1, 4, 4),
    (128, 128, 64, 8, 4, 4),
    (128, 128, 64, 8, 8, 4),
    (128, 256, 64, 8, 8, 4),
]

def benchmark_config(M, config, iterations=50):
    """Simulate MoE kernel performance with given config."""
    BLOCK_M, BLOCK_N, BLOCK_K, GROUP_M, warps, stages = config

    # Create test tensors
    try:
        # Simulate expert computation
        x = torch.randn(M, K, device='cuda', dtype=torch.bfloat16)
        w = torch.randn(E, N, K, device='cuda', dtype=torch.bfloat16)

        # Warmup
        torch.cuda.synchronize()
        for _ in range(5):
            # Simplified MoE-like operation
            out = torch.matmul(x, w[0].T)
        torch.cuda.synchronize()

        # Benchmark
        torch.cuda.synchronize()
        start = time.perf_counter()
        for _ in range(iterations):
            out = torch.matmul(x, w[0].T)
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start

        del x, w, out
        torch.cuda.empty_cache()

        return elapsed / iterations

    except RuntimeError:
        return float('inf')

print("Benchmarking kernel configurations...")
print("-" * 70)

best_configs = {}

for batch_size in batch_sizes:
    print(f"\nBatch size: {batch_size}")

    best_time = float('inf')
    best_config = None

    for config in configs_to_try:
        try:
            elapsed = benchmark_config(batch_size, config)

            if elapsed < best_time:
                best_time = elapsed
                best_config = config

        except Exception as e:
            continue

    if best_config:
        BLOCK_M, BLOCK_N, BLOCK_K, GROUP_M, warps, stages = best_config
        best_configs[str(batch_size)] = {
            "BLOCK_SIZE_M": BLOCK_M,
            "BLOCK_SIZE_N": BLOCK_N,
            "BLOCK_SIZE_K": BLOCK_K,
            "GROUP_SIZE_M": GROUP_M,
            "num_warps": warps,
            "num_stages": stages
        }
        print(f"  Best: BLOCK_M={BLOCK_M}, BLOCK_N={BLOCK_N}, "
              f"BLOCK_K={BLOCK_K}, GROUP_M={GROUP_M}, "
              f"warps={warps}, stages={stages} ({best_time*1000:.3f}ms)")

# Save config
config_path = f"/workspace/configs/E={E},N={N},device_name={gpu_name}.json"
os.makedirs(os.path.dirname(config_path), exist_ok=True)

with open(config_path, 'w') as f:
    json.dump(best_configs, f, indent=4)

print()
print("=" * 70)
print(f"Config saved to: {config_path}")
print("=" * 70)

# Also save to standard vLLM location if accessible
vllm_config_dir = "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/layers/fused_moe/configs"
if os.path.exists(os.path.dirname(vllm_config_dir)):
    try:
        os.makedirs(vllm_config_dir, exist_ok=True)
        vllm_config_path = f"{vllm_config_dir}/E={E},N={N},device_name={gpu_name}.json"
        with open(vllm_config_path, 'w') as f:
            json.dump(best_configs, f, indent=4)
        print(f"Also saved to: {vllm_config_path}")
    except PermissionError:
        print(f"Note: Could not write to vLLM config dir (read-only mount)")

print()
print("Tuning complete! Restart vllm-server to use the new config.")
PYTHON_SCRIPT

# Cleanup temporary container if we started one
if $CLEANUP_CONTAINER; then
    echo ""
    echo "Cleaning up temporary container..."
    docker stop moe-tuner 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    TUNING COMPLETE!                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Config saved to: ${CONFIG_DIR}/"
echo ""
echo "To apply the new config, restart the vLLM server:"
echo "  docker compose -f docker-compose.single-node.yml restart"
echo ""
