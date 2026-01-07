#!/bin/bash
#===============================================================================
#  BENCHMARK SUITE - DEPENDENCY INSTALLER
#  Installs required tools for comprehensive benchmarking
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

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
echo "Setting up Python virtual environment..."
echo ""

# Check for python3-venv
if ! python3 -m venv --help &> /dev/null; then
    print_installing "python3-venv"
    $SUDO $PKG_INSTALL python3-venv
fi

# Create virtual environment
if [[ ! -d "$VENV_DIR" ]]; then
    print_installing "virtual environment at .venv/"
    python3 -m venv "$VENV_DIR"
    print_status "Virtual environment created"
else
    print_skip "virtual environment (.venv/)"
fi

# Activate venv
source "$VENV_DIR/bin/activate"
print_status "Virtual environment activated"

echo ""
echo "Installing Python packages in venv..."
echo ""

# Upgrade pip
pip install --upgrade pip --quiet

# numpy
if ! python -c "import numpy" 2>/dev/null; then
    print_installing "numpy"
    pip install numpy --quiet
    print_status "numpy installed"
else
    print_skip "numpy"
fi

# Check for PyTorch
if ! python -c "import torch" 2>/dev/null; then
    print_installing "torch (PyTorch with CUDA)"
    pip install torch --index-url https://download.pytorch.org/whl/cu124 --quiet
    print_status "torch installed"
fi

# Verify PyTorch CUDA
if python -c "import torch" 2>/dev/null; then
    print_skip "torch (PyTorch)"
    TORCH_CUDA=$(python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)
    if [[ "$TORCH_CUDA" == "True" ]]; then
        echo "         CUDA support: ✓"
    else
        echo "         CUDA support: ✗ (CPU only)"
    fi
fi

# Deactivate venv
deactivate

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
