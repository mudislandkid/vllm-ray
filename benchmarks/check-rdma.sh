#!/bin/bash
#===============================================================================
#  RDMA / RoCE CAPABILITY CHECK
#  Run on each node to identify RDMA hardware and driver status
#===============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

section() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
    echo ""
}

section "HOSTNAME & KERNEL"
hostname
uname -r

section "RDMA-CAPABLE NICs (lspci)"
lspci 2>/dev/null | grep -iE "mellanox|connectx|infiniband|ethernet controller" || echo "  No Mellanox/ConnectX NICs found"

section "NETWORK INTERFACES"
ip link show 2>/dev/null | grep -E "^[0-9]+:|mtu" || ifconfig 2>/dev/null

section "IP ADDRESSES (25G interfaces)"
ip -br addr show 2>/dev/null || ip addr show 2>/dev/null

section "INTERFACE DETAILS (ethtool)"
for iface in $(ip -br link show 2>/dev/null | awk '{print $1}' | grep -v "lo\|docker\|br-\|veth"); do
    speed=$(ethtool "$iface" 2>/dev/null | grep "Speed:" || echo "  Speed: unknown")
    driver=$(ethtool -i "$iface" 2>/dev/null | grep "driver:" || echo "  driver: unknown")
    echo -e "  ${BOLD}${iface}${NC}: $speed / $driver"
done

section "RDMA DEVICES (rdma link)"
rdma link 2>/dev/null || echo "  rdma command not available (install rdma-core)"

section "INFINIBAND STATUS (ibstat)"
ibstat 2>/dev/null || echo "  ibstat not available (install infiniband-diags)"

section "INFINIBAND DEVICES (ibv_devices)"
ibv_devices 2>/dev/null || echo "  ibv_devices not available (install libibverbs1)"

section "RDMA KERNEL MODULES"
lsmod 2>/dev/null | grep -iE "rdma|mlx|ib_|roce|rxe" || echo "  No RDMA modules loaded"

section "AVAILABLE RDMA MODULES (not loaded)"
modinfo mlx5_core 2>/dev/null | head -3 || echo "  mlx5_core module not found"
echo ""
modinfo rdma_cm 2>/dev/null | head -3 || echo "  rdma_cm module not found"
echo ""
modinfo ib_core 2>/dev/null | head -3 || echo "  ib_core module not found"

section "RDMA/OFED PACKAGES INSTALLED"
dpkg -l 2>/dev/null | grep -iE "rdma|ibverbs|mellanox|mlnx|ofed|perftest" | awk '{print "  "$2" "$3}' || \
rpm -qa 2>/dev/null | grep -iE "rdma|ibverbs|mellanox|mlnx|ofed" || \
echo "  No RDMA packages found"

section "NCCL RELATED"
# Check if nccl-tests is available
which nccl_tests 2>/dev/null || echo "  nccl-tests not installed"
# Check for NCCL rdma plugin
find /usr -name "libnccl-net*" 2>/dev/null || echo "  No NCCL net plugins found"
ldconfig -p 2>/dev/null | grep -i nccl || echo "  No NCCL libs in ldconfig"

section "DOCKER NVIDIA RUNTIME"
docker info 2>/dev/null | grep -i "runtime" || echo "  Cannot query docker info"

section "GPU INFO"
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader 2>/dev/null || echo "  nvidia-smi not available"

section "SUMMARY"
echo ""

# Quick verdict
HAS_RDMA_NIC=false
HAS_RDMA_DRIVER=false
HAS_RDMA_TOOLS=false
ROCE_ACTIVE=false

lspci 2>/dev/null | grep -qiE "mellanox|connectx" && HAS_RDMA_NIC=true
lsmod 2>/dev/null | grep -qiE "mlx5_core|mlx4_core" && HAS_RDMA_DRIVER=true
command -v ibv_devices &>/dev/null && HAS_RDMA_TOOLS=true
rdma link 2>/dev/null | grep -qi "ACTIVE" && ROCE_ACTIVE=true

if $HAS_RDMA_NIC; then
    echo -e "  ${GREEN}✓${NC} RDMA-capable NIC detected"
else
    echo -e "  ${RED}✗${NC} No RDMA-capable NIC found"
fi

if $HAS_RDMA_DRIVER; then
    echo -e "  ${GREEN}✓${NC} RDMA kernel drivers loaded"
else
    echo -e "  ${YELLOW}○${NC} RDMA kernel drivers not loaded"
fi

if $HAS_RDMA_TOOLS; then
    echo -e "  ${GREEN}✓${NC} RDMA userspace tools installed"
else
    echo -e "  ${YELLOW}○${NC} RDMA userspace tools not installed (apt install rdma-core ibverbs-utils)"
fi

if $ROCE_ACTIVE; then
    echo -e "  ${GREEN}✓${NC} RoCE link is ACTIVE"
else
    echo -e "  ${YELLOW}○${NC} RoCE link not active"
fi

echo ""
