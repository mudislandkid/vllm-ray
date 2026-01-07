#!/bin/bash
#===============================================================================
#  MEMORY (RAM) BANDWIDTH BENCHMARK
#  Tests: Read/Write/Copy bandwidth, Latency
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
BOLD='\033[1m'
NC='\033[0m'

QUICK_MODE=false
TEST_SIZE="4G"

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
            TEST_SIZE="1G"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Get memory info
TOTAL_MEM=$(free -h | awk '/^Mem:/{print $2}')
AVAIL_MEM=$(free -h | awk '/^Mem:/{print $7}')
MEM_SPEED=$(dmidecode -t memory 2>/dev/null | grep -m1 "Speed:" | grep -v "Configured" | awk '{print $2, $3}')

echo ""
echo "  Total Memory:     $TOTAL_MEM"
echo "  Available:        $AVAIL_MEM"
[[ -n "$MEM_SPEED" ]] && echo "  Memory Speed:     $MEM_SPEED"
echo "  Test Size:        $TEST_SIZE"
echo ""

#-------------------------------------------------------------------------------
# SYSBENCH MEMORY TEST (if available)
#-------------------------------------------------------------------------------
if command -v sysbench &> /dev/null; then
    print_subheader "Memory Bandwidth Test (sysbench)"

    RUNTIME="10"
    $QUICK_MODE && RUNTIME="5"

    # Sequential Read
    print_info "Sequential Read test..."
    READ_RESULT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G \
        --memory-oper=read --memory-access-mode=seq --time="$RUNTIME" run 2>/dev/null)

    READ_BW=$(echo "$READ_RESULT" | grep "transferred" | grep -oP '[\d.]+\s+MiB/sec' | head -1)
    READ_BW=${READ_BW:-$(echo "$READ_RESULT" | grep -oP '[\d.]+\s+GiB/sec' | head -1)}

    print_result "Sequential Read" "${READ_BW:-N/A}" ""

    # Sequential Write
    print_info "Sequential Write test..."
    WRITE_RESULT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G \
        --memory-oper=write --memory-access-mode=seq --time="$RUNTIME" run 2>/dev/null)

    WRITE_BW=$(echo "$WRITE_RESULT" | grep "transferred" | grep -oP '[\d.]+\s+MiB/sec' | head -1)
    WRITE_BW=${WRITE_BW:-$(echo "$WRITE_RESULT" | grep -oP '[\d.]+\s+GiB/sec' | head -1)}

    print_result "Sequential Write" "${WRITE_BW:-N/A}" ""

    # Random Read
    print_info "Random Read test..."
    RAND_READ=$(sysbench memory --memory-block-size=1M --memory-total-size=10G \
        --memory-oper=read --memory-access-mode=rnd --time="$RUNTIME" run 2>/dev/null)

    RAND_READ_BW=$(echo "$RAND_READ" | grep "transferred" | grep -oP '[\d.]+\s+MiB/sec' | head -1)

    print_result "Random Read" "${RAND_READ_BW:-N/A}" ""

    # Random Write
    print_info "Random Write test..."
    RAND_WRITE=$(sysbench memory --memory-block-size=1M --memory-total-size=10G \
        --memory-oper=write --memory-access-mode=rnd --time="$RUNTIME" run 2>/dev/null)

    RAND_WRITE_BW=$(echo "$RAND_WRITE" | grep "transferred" | grep -oP '[\d.]+\s+MiB/sec' | head -1)

    print_result "Random Write" "${RAND_WRITE_BW:-N/A}" ""

else
    print_subheader "Memory Bandwidth Test (dd fallback)"
    echo "  Note: Install sysbench for more accurate results"
    echo "    apt install sysbench  # Debian/Ubuntu"
    echo ""
fi

#-------------------------------------------------------------------------------
# STREAM-LIKE BENCHMARK (Python)
#-------------------------------------------------------------------------------
print_subheader "STREAM-like Benchmark"
print_info "Testing memory bandwidth with array operations..."

python3 << 'PYTHON_SCRIPT'
import numpy as np
import time

# Test size (adjust based on available memory)
SIZE = 100_000_000  # 100M elements = 800MB for float64

print("  Allocating test arrays...")
a = np.ones(SIZE, dtype=np.float64)
b = np.ones(SIZE, dtype=np.float64)
c = np.ones(SIZE, dtype=np.float64)

bytes_per_element = 8  # float64
array_bytes = SIZE * bytes_per_element

# COPY: c = a
print("  Running COPY test (c = a)...")
start = time.perf_counter()
for _ in range(3):
    np.copyto(c, a)
elapsed = (time.perf_counter() - start) / 3
copy_bw = (2 * array_bytes) / elapsed / 1e9
print(f"  {'COPY Bandwidth':<30} {copy_bw:.1f} GB/s")

# SCALE: b = scalar * c
print("  Running SCALE test (b = 3.0 * c)...")
start = time.perf_counter()
for _ in range(3):
    b = 3.0 * c
elapsed = (time.perf_counter() - start) / 3
scale_bw = (2 * array_bytes) / elapsed / 1e9
print(f"  {'SCALE Bandwidth':<30} {scale_bw:.1f} GB/s")

# ADD: c = a + b
print("  Running ADD test (c = a + b)...")
start = time.perf_counter()
for _ in range(3):
    c = a + b
elapsed = (time.perf_counter() - start) / 3
add_bw = (3 * array_bytes) / elapsed / 1e9
print(f"  {'ADD Bandwidth':<30} {add_bw:.1f} GB/s")

# TRIAD: a = b + scalar * c
print("  Running TRIAD test (a = b + 3.0 * c)...")
start = time.perf_counter()
for _ in range(3):
    a = b + 3.0 * c
elapsed = (time.perf_counter() - start) / 3
triad_bw = (3 * array_bytes) / elapsed / 1e9
print(f"  {'TRIAD Bandwidth':<30} {triad_bw:.1f} GB/s")

# Summary
print("")
print(f"  {'Peak Bandwidth (TRIAD)':<30} {triad_bw:.1f} GB/s")
PYTHON_SCRIPT

#-------------------------------------------------------------------------------
# MEMORY LATENCY TEST
#-------------------------------------------------------------------------------
print_subheader "Memory Latency Test"
print_info "Measuring random access latency..."

python3 << 'PYTHON_SCRIPT'
import numpy as np
import time
import random

# Allocate array larger than L3 cache (typically 30-50MB)
SIZE = 64 * 1024 * 1024  # 64MB
ITERATIONS = 1_000_000

# Create array and random indices
arr = np.zeros(SIZE // 8, dtype=np.int64)  # 8 bytes per int64
indices = np.random.randint(0, len(arr), ITERATIONS)

# Warm up
_ = arr[indices[:1000]].sum()

# Measure random access
start = time.perf_counter()
total = 0
for idx in indices:
    total += arr[idx]
elapsed = time.perf_counter() - start

latency_ns = (elapsed / ITERATIONS) * 1e9
print(f"  {'Random Access Latency':<30} {latency_ns:.1f} ns")

# Theoretical bandwidth at this latency
theoretical_bw = 8 / (latency_ns / 1e9) / 1e9  # 8 bytes per access
print(f"  {'Implied Bandwidth (8B/access)':<30} {theoretical_bw:.2f} GB/s")
PYTHON_SCRIPT

#-------------------------------------------------------------------------------
# NUMA INFO (if applicable)
#-------------------------------------------------------------------------------
if command -v numactl &> /dev/null; then
    print_subheader "NUMA Topology"

    NUMA_NODES=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}')
    if [[ "$NUMA_NODES" -gt 1 ]]; then
        echo "  NUMA Nodes: $NUMA_NODES"
        numactl --hardware 2>/dev/null | grep -E "node [0-9]+ cpus:|node [0-9]+ size:" | while read line; do
            echo "    $line"
        done
    else
        echo "  Single NUMA node (UMA system)"
    fi
fi

echo ""
