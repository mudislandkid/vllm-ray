#!/bin/bash
#===============================================================================
#  BENCHMARK SUITE - DEPENDENCY INSTALLER
#  Installs required tools for comprehensive benchmarking
#===============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           BENCHMARK SUITE - DEPENDENCY INSTALLER                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_installing() {
    echo -e "  ${YELLOW}→${NC} Installing $1..."
}

print_skip() {
    echo -e "  ${CYAN}○${NC} $1 already installed"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_header

echo ""
echo "This script will install the following tools:"
echo "  • iperf3     - Network bandwidth testing"
echo "  • fio        - Disk I/O benchmarking"
echo "  • sysbench   - Memory and CPU benchmarking"
echo "  • hdparm     - Direct disk read testing"
echo "  • numactl    - NUMA topology tools"
echo "  • python3    - Required for GPU benchmarks"
echo "  • numpy      - Python numerical library"
echo "  • torch      - PyTorch for GPU benchmarks"
echo ""

# Detect package manager
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum makecache"
    PKG_INSTALL="yum install -y"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf makecache"
    PKG_INSTALL="dnf install -y"
else
    print_error "Unsupported package manager. Please install dependencies manually."
    exit 1
fi

echo "Detected package manager: $PKG_MANAGER"
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
    echo "Note: Will use sudo for package installation"
else
    SUDO=""
fi

echo ""
echo "Updating package lists..."
$SUDO $PKG_UPDATE

echo ""
echo "Installing system packages..."
echo ""

# iperf3
if ! command -v iperf3 &> /dev/null; then
    print_installing "iperf3"
    $SUDO $PKG_INSTALL iperf3
    print_status "iperf3 installed"
else
    print_skip "iperf3"
fi

# fio
if ! command -v fio &> /dev/null; then
    print_installing "fio"
    $SUDO $PKG_INSTALL fio
    print_status "fio installed"
else
    print_skip "fio"
fi

# sysbench
if ! command -v sysbench &> /dev/null; then
    print_installing "sysbench"
    $SUDO $PKG_INSTALL sysbench
    print_status "sysbench installed"
else
    print_skip "sysbench"
fi

# hdparm
if ! command -v hdparm &> /dev/null; then
    print_installing "hdparm"
    $SUDO $PKG_INSTALL hdparm
    print_status "hdparm installed"
else
    print_skip "hdparm"
fi

# numactl
if ! command -v numactl &> /dev/null; then
    print_installing "numactl"
    $SUDO $PKG_INSTALL numactl
    print_status "numactl installed"
else
    print_skip "numactl"
fi

# dmidecode (for memory info)
if ! command -v dmidecode &> /dev/null; then
    print_installing "dmidecode"
    $SUDO $PKG_INSTALL dmidecode
    print_status "dmidecode installed"
else
    print_skip "dmidecode"
fi

echo ""
echo "Installing Python packages..."
echo ""

# Check for pip
if ! command -v pip3 &> /dev/null; then
    print_installing "python3-pip"
    $SUDO $PKG_INSTALL python3-pip
fi

# numpy
if ! python3 -c "import numpy" 2>/dev/null; then
    print_installing "numpy"
    pip3 install --user numpy
    print_status "numpy installed"
else
    print_skip "numpy"
fi

# Check for PyTorch
if ! python3 -c "import torch" 2>/dev/null; then
    echo ""
    echo "  PyTorch not installed. For GPU benchmarks, install with:"
    echo ""
    echo "    pip3 install torch  # CPU only"
    echo ""
    echo "  Or for CUDA support:"
    echo "    pip3 install torch --index-url https://download.pytorch.org/whl/cu124"
    echo ""
else
    print_skip "torch (PyTorch)"
    TORCH_CUDA=$(python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)
    if [[ "$TORCH_CUDA" == "True" ]]; then
        echo "         CUDA support: ✓"
    else
        echo "         CUDA support: ✗ (CPU only)"
    fi
fi

echo ""
echo "Making benchmark scripts executable..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR"/*.sh
print_status "Scripts are now executable"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    SETUP COMPLETE!                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "To run benchmarks:"
echo ""
echo "  # Full benchmark (no network)"
echo "  ./benchmark-all.sh"
echo ""
echo "  # With network test to remote host"
echo "  ./benchmark-all.sh -r <remote_ip>"
echo ""
echo "  # Quick mode"
echo "  ./benchmark-all.sh --quick"
echo ""
echo "For network tests, start iperf3 server on the remote host:"
echo "  iperf3 -s"
echo ""
