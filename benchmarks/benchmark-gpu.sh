#!/bin/bash
#===============================================================================
#  GPU / VRAM PERFORMANCE BENCHMARK
#  Tests: VRAM Bandwidth, Host<->Device, GPU-to-GPU, Compute
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

# Activate virtual environment if it exists
if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    source "${VENV_DIR}/bin/activate"
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

QUICK_MODE=false

print_result() {
    local label="$1"
    local value="$2"
    local unit="$3"
    printf "  ${GREEN}%-30s${NC} ${BOLD}%s${NC} %s\n" "$label:" "$value" "$unit"
}

print_info() {
    echo -e "  ${CYAN}ℹ${NC}  $1"
}

print_subheader() {
    echo ""
    echo -e "  ${YELLOW}▸ $1${NC}"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

#-------------------------------------------------------------------------------
# CHECK FOR NVIDIA GPU
#-------------------------------------------------------------------------------
if ! command -v nvidia-smi &> /dev/null; then
    echo "  ✗ nvidia-smi not found. No NVIDIA GPU detected."
    exit 1
fi

#-------------------------------------------------------------------------------
# GPU INFORMATION
#-------------------------------------------------------------------------------
print_subheader "GPU Information"

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)

nvidia-smi --query-gpu=index,name,memory.total,pcie.link.gen.current,pcie.link.width.current \
    --format=csv,noheader 2>/dev/null | while IFS=',' read -r idx name mem pcie_gen pcie_width; do
    echo "  GPU $idx: $name"
    echo "         Memory: $mem"
    echo "         PCIe:   Gen${pcie_gen} x${pcie_width}"
done

# Show topology if multiple GPUs
if [[ "$GPU_COUNT" -gt 1 ]]; then
    print_subheader "GPU Topology"
    nvidia-smi topo -m 2>/dev/null | head -20
fi

#-------------------------------------------------------------------------------
# CUDA BANDWIDTH TEST (if available)
#-------------------------------------------------------------------------------
if command -v /usr/local/cuda/samples/1_Utilities/bandwidthTest/bandwidthTest &> /dev/null; then
    print_subheader "CUDA Bandwidth Test"

    BW_TEST="/usr/local/cuda/samples/1_Utilities/bandwidthTest/bandwidthTest"

    print_info "Host to Device bandwidth..."
    H2D=$($BW_TEST --htod 2>/dev/null | grep "Host to Device" | tail -1 | awk '{print $(NF-1), $NF}')
    print_result "Host → Device" "${H2D:-N/A}" ""

    print_info "Device to Host bandwidth..."
    D2H=$($BW_TEST --dtoh 2>/dev/null | grep "Device to Host" | tail -1 | awk '{print $(NF-1), $NF}')
    print_result "Device → Host" "${D2H:-N/A}" ""

    print_info "Device to Device bandwidth..."
    D2D=$($BW_TEST --dtod 2>/dev/null | grep "Device to Device" | tail -1 | awk '{print $(NF-1), $NF}')
    print_result "Device → Device" "${D2D:-N/A}" ""
fi

#-------------------------------------------------------------------------------
# PYTHON/PYTORCH GPU BENCHMARK
#-------------------------------------------------------------------------------
print_subheader "GPU Memory Bandwidth (PyTorch)"
print_info "Running VRAM bandwidth tests..."

python3 << 'PYTHON_SCRIPT'
import torch
import time

if not torch.cuda.is_available():
    print("  ✗ CUDA not available in PyTorch")
    exit(1)

device_count = torch.cuda.device_count()

for device_id in range(device_count):
    torch.cuda.set_device(device_id)
    device = torch.device(f'cuda:{device_id}')
    props = torch.cuda.get_device_properties(device_id)

    print(f"\n  GPU {device_id}: {props.name}")
    print(f"  {'─' * 50}")

    # Test sizes
    sizes_gb = [0.5, 1.0, 2.0]
    iterations = 10

    for size_gb in sizes_gb:
        size_bytes = int(size_gb * 1024 * 1024 * 1024)
        elements = size_bytes // 4  # float32

        try:
            # Allocate tensors
            a = torch.randn(elements, device=device, dtype=torch.float32)
            b = torch.empty_like(a)

            # Warmup
            torch.cuda.synchronize()
            b.copy_(a)
            torch.cuda.synchronize()

            # VRAM Copy bandwidth (read + write)
            torch.cuda.synchronize()
            start = time.perf_counter()
            for _ in range(iterations):
                b.copy_(a)
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - start

            bandwidth = (2 * size_bytes * iterations) / elapsed / 1e9
            print(f"  {'VRAM Copy (' + str(size_gb) + 'GB)':<30} {bandwidth:.1f} GB/s")

            del a, b
            torch.cuda.empty_cache()

        except RuntimeError as e:
            print(f"  {size_gb}GB test: Skipped (OOM)")

    # Host <-> Device bandwidth
    print(f"\n  Host ↔ Device Transfer:")

    size_mb = 256
    size_bytes = size_mb * 1024 * 1024
    elements = size_bytes // 4

    # Host to Device (pinned memory)
    host_tensor = torch.randn(elements, dtype=torch.float32).pin_memory()
    device_tensor = torch.empty(elements, device=device, dtype=torch.float32)

    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(10):
        device_tensor.copy_(host_tensor)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start
    h2d_bw = (size_bytes * 10) / elapsed / 1e9
    print(f"  {'Host → Device (pinned)':<30} {h2d_bw:.1f} GB/s")

    # Device to Host
    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(10):
        host_tensor.copy_(device_tensor)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start
    d2h_bw = (size_bytes * 10) / elapsed / 1e9
    print(f"  {'Device → Host (pinned)':<30} {d2h_bw:.1f} GB/s")

    del host_tensor, device_tensor
    torch.cuda.empty_cache()

# GPU-to-GPU bandwidth (if multiple GPUs)
if device_count > 1:
    print(f"\n  GPU ↔ GPU Transfer:")

    # Check P2P support
    for i in range(device_count):
        for j in range(device_count):
            if i != j:
                can_p2p = torch.cuda.can_device_access_peer(i, j)
                if can_p2p:
                    # Enable P2P
                    torch.cuda.set_device(i)

                    size_mb = 256
                    size_bytes = size_mb * 1024 * 1024
                    elements = size_bytes // 4

                    src = torch.randn(elements, device=f'cuda:{i}', dtype=torch.float32)
                    dst = torch.empty(elements, device=f'cuda:{j}', dtype=torch.float32)

                    # Warmup
                    torch.cuda.synchronize()
                    dst.copy_(src)
                    torch.cuda.synchronize()

                    # Benchmark
                    torch.cuda.synchronize()
                    start = time.perf_counter()
                    for _ in range(10):
                        dst.copy_(src)
                    torch.cuda.synchronize()
                    elapsed = time.perf_counter() - start

                    p2p_bw = (size_bytes * 10) / elapsed / 1e9
                    print(f"  {'GPU ' + str(i) + ' → GPU ' + str(j) + ' (P2P)':<30} {p2p_bw:.1f} GB/s")

                    del src, dst
                    torch.cuda.empty_cache()
PYTHON_SCRIPT

#-------------------------------------------------------------------------------
# COMPUTE BENCHMARK
#-------------------------------------------------------------------------------
print_subheader "GPU Compute Benchmark"
print_info "Running matrix multiplication benchmark..."

python3 << 'PYTHON_SCRIPT'
import torch
import time

if not torch.cuda.is_available():
    exit(1)

device_count = torch.cuda.device_count()

for device_id in range(device_count):
    torch.cuda.set_device(device_id)
    device = torch.device(f'cuda:{device_id}')
    props = torch.cuda.get_device_properties(device_id)

    print(f"\n  GPU {device_id}: {props.name}")

    # Matrix sizes to test
    sizes = [(4096, 4096), (8192, 8192)]

    for M, N in sizes:
        K = M
        try:
            # FP32 GEMM
            a = torch.randn(M, K, device=device, dtype=torch.float32)
            b = torch.randn(K, N, device=device, dtype=torch.float32)

            # Warmup
            torch.cuda.synchronize()
            c = torch.matmul(a, b)
            torch.cuda.synchronize()

            # Benchmark
            iterations = 10
            torch.cuda.synchronize()
            start = time.perf_counter()
            for _ in range(iterations):
                c = torch.matmul(a, b)
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - start

            # FLOPS: 2 * M * N * K per matmul
            flops = 2 * M * N * K * iterations
            tflops = flops / elapsed / 1e12
            print(f"  {'FP32 GEMM ' + str(M) + 'x' + str(N):<30} {tflops:.2f} TFLOPS")

            del a, b, c
            torch.cuda.empty_cache()

            # FP16 GEMM (Tensor Core)
            a = torch.randn(M, K, device=device, dtype=torch.float16)
            b = torch.randn(K, N, device=device, dtype=torch.float16)

            torch.cuda.synchronize()
            c = torch.matmul(a, b)
            torch.cuda.synchronize()

            torch.cuda.synchronize()
            start = time.perf_counter()
            for _ in range(iterations):
                c = torch.matmul(a, b)
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - start

            tflops = flops / elapsed / 1e12
            print(f"  {'FP16 GEMM ' + str(M) + 'x' + str(N):<30} {tflops:.2f} TFLOPS")

            del a, b, c
            torch.cuda.empty_cache()

            # BF16 GEMM
            a = torch.randn(M, K, device=device, dtype=torch.bfloat16)
            b = torch.randn(K, N, device=device, dtype=torch.bfloat16)

            torch.cuda.synchronize()
            c = torch.matmul(a, b)
            torch.cuda.synchronize()

            torch.cuda.synchronize()
            start = time.perf_counter()
            for _ in range(iterations):
                c = torch.matmul(a, b)
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - start

            tflops = flops / elapsed / 1e12
            print(f"  {'BF16 GEMM ' + str(M) + 'x' + str(N):<30} {tflops:.2f} TFLOPS")

            del a, b, c
            torch.cuda.empty_cache()

        except RuntimeError as e:
            print(f"  {M}x{N} test: Skipped (OOM)")
PYTHON_SCRIPT

#-------------------------------------------------------------------------------
# MEMORY INFO
#-------------------------------------------------------------------------------
print_subheader "GPU Memory Status"

nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total,utilization.memory \
    --format=csv,noheader 2>/dev/null | while IFS=',' read -r idx used free total util; do
    echo "  GPU $idx: $used used / $total total ($util utilization)"
done

echo ""
