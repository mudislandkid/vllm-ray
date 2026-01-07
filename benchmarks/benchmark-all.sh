#!/bin/bash
#===============================================================================
#  NODE PERFORMANCE BENCHMARK SUITE
#  Comprehensive benchmarks for: Network, Disk, Memory, GPU
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname)
REPORT_FILE="${REPORT_DIR}/${HOSTNAME}_benchmark_${TIMESTAMP}.txt"

# Default settings
REMOTE_HOST="${REMOTE_HOST:-}"
RUN_NETWORK=true
RUN_DISK=true
RUN_MEMORY=true
RUN_GPU=true
QUICK_MODE=false

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           NODE PERFORMANCE BENCHMARK SUITE                       ║"
    echo "║                                                                  ║"
    echo "║  Tests: Network • Disk I/O • Memory • GPU/VRAM                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${YELLOW}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_result() {
    local label="$1"
    local value="$2"
    local unit="$3"
    printf "  ${GREEN}%-30s${NC} ${BOLD}%s${NC} %s\n" "$label:" "$value" "$unit"
}

print_info() {
    echo -e "  ${CYAN}ℹ${NC}  $1"
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC}  $1"
}

print_error() {
    echo -e "  ${RED}✗${NC}  $1"
}

print_success() {
    echo -e "  ${GREEN}✓${NC}  $1"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -r, --remote HOST    Remote host for network tests (required for network benchmark)"
    echo "  -q, --quick          Quick mode (shorter tests)"
    echo "  --no-network         Skip network benchmarks"
    echo "  --no-disk            Skip disk benchmarks"
    echo "  --no-memory          Skip memory benchmarks"
    echo "  --no-gpu             Skip GPU benchmarks"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -r 10.15.105.107           # Full benchmark with network to remote host"
    echo "  $0 --no-network               # All benchmarks except network"
    echo "  $0 -r 10.15.105.107 --quick   # Quick benchmark"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--remote)
            REMOTE_HOST="$2"
            shift 2
            ;;
        -q|--quick)
            QUICK_MODE=true
            shift
            ;;
        --no-network)
            RUN_NETWORK=false
            shift
            ;;
        --no-disk)
            RUN_DISK=false
            shift
            ;;
        --no-memory)
            RUN_MEMORY=false
            shift
            ;;
        --no-gpu)
            RUN_GPU=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Create report directory
mkdir -p "$REPORT_DIR"

# Start report
{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           NODE PERFORMANCE BENCHMARK REPORT                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Date:     $(date)"
    echo "Hostname: $HOSTNAME"
    echo "Kernel:   $(uname -r)"
    echo ""
} > "$REPORT_FILE"

print_header

print_section "SYSTEM INFORMATION"

# Gather system info
echo "  Hostname:       $HOSTNAME"
echo "  Date:           $(date)"
echo "  Kernel:         $(uname -r)"
echo "  CPU:            $(lscpu 2>/dev/null | grep 'Model name' | cut -d':' -f2 | xargs || echo 'Unknown')"
echo "  CPU Cores:      $(nproc 2>/dev/null || echo 'Unknown')"
echo "  Total RAM:      $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo 'Unknown')"

if command -v nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
    echo "  GPUs:           $GPU_COUNT x ${GPU_INFO%%,*}"
    echo "  GPU Memory:     ${GPU_INFO##*,}"
fi

# Run benchmarks
if $RUN_DISK; then
    print_section "DISK I/O BENCHMARK"
    if [[ -x "${SCRIPT_DIR}/benchmark-disk.sh" ]]; then
        DISK_ARGS=""
        $QUICK_MODE && DISK_ARGS="--quick"
        "${SCRIPT_DIR}/benchmark-disk.sh" $DISK_ARGS | tee -a "$REPORT_FILE"
    else
        print_error "benchmark-disk.sh not found or not executable"
    fi
fi

if $RUN_MEMORY; then
    print_section "MEMORY BANDWIDTH BENCHMARK"
    if [[ -x "${SCRIPT_DIR}/benchmark-memory.sh" ]]; then
        MEM_ARGS=""
        $QUICK_MODE && MEM_ARGS="--quick"
        "${SCRIPT_DIR}/benchmark-memory.sh" $MEM_ARGS | tee -a "$REPORT_FILE"
    else
        print_error "benchmark-memory.sh not found or not executable"
    fi
fi

if $RUN_GPU; then
    print_section "GPU / VRAM BENCHMARK"
    if [[ -x "${SCRIPT_DIR}/benchmark-gpu.sh" ]]; then
        GPU_ARGS=""
        $QUICK_MODE && GPU_ARGS="--quick"
        "${SCRIPT_DIR}/benchmark-gpu.sh" $GPU_ARGS | tee -a "$REPORT_FILE"
    else
        print_error "benchmark-gpu.sh not found or not executable"
    fi
fi

if $RUN_NETWORK; then
    print_section "NETWORK BENCHMARK"
    if [[ -z "$REMOTE_HOST" ]]; then
        print_warning "No remote host specified. Skipping network benchmark."
        print_info "Use -r <remote_ip> to enable network testing"
    elif [[ -x "${SCRIPT_DIR}/benchmark-network.sh" ]]; then
        NET_ARGS="-r $REMOTE_HOST"
        $QUICK_MODE && NET_ARGS="$NET_ARGS --quick"
        "${SCRIPT_DIR}/benchmark-network.sh" $NET_ARGS | tee -a "$REPORT_FILE"
    else
        print_error "benchmark-network.sh not found or not executable"
    fi
fi

print_section "BENCHMARK COMPLETE"

echo ""
print_success "All benchmarks completed!"
echo ""
print_info "Report saved to: $REPORT_FILE"
echo ""

# Append summary to report
{
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  BENCHMARK COMPLETE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Completed at: $(date)"
} >> "$REPORT_FILE"
