#!/bin/bash
#===============================================================================
#  NETWORK TUNING FOR HIGH-SPEED VMXNET3
#  Optimizes TCP, buffers, and vmxnet3 settings for 25Gbps links
#  Run on BOTH nodes with: sudo ./tune-network.sh <interface>
#===============================================================================

IFACE="${1:-ens33}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo $0 ${IFACE}${NC}"
    exit 1
fi

if ! ip link show "$IFACE" &>/dev/null; then
    echo -e "${RED}Interface '${IFACE}' not found${NC}"
    echo "Available interfaces:"
    ip -br link show | grep -v "lo\|docker\|br-\|veth"
    exit 1
fi

section() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
    echo ""
}

applied() {
    echo -e "  ${GREEN}✓${NC} $1"
}

skipped() {
    echo -e "  ${YELLOW}○${NC} $1"
}

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           NETWORK TUNING FOR HIGH-SPEED LINKS                    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Interface: ${BOLD}${IFACE}${NC}"

# Current speed
SPEED=$(ethtool "$IFACE" 2>/dev/null | grep "Speed:" | awk '{print $2}')
echo -e "  Speed:     ${BOLD}${SPEED:-unknown}${NC}"
echo ""

#-------------------------------------------------------------------------------
section "JUMBO FRAMES (MTU 9000)"
#-------------------------------------------------------------------------------

CURRENT_MTU=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
if [ "$CURRENT_MTU" -lt 9000 ]; then
    ip link set "$IFACE" mtu 9000
    applied "MTU set to 9000 (was ${CURRENT_MTU})"

    # Make persistent via netplan if available
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    if [[ -n "$NETPLAN_FILE" ]]; then
        if ! grep -q "mtu:" "$NETPLAN_FILE"; then
            echo -e "  ${YELLOW}⚠${NC}  Add 'mtu: 9000' to ${NETPLAN_FILE} under ${IFACE} to persist across reboots"
        fi
    fi
else
    skipped "MTU already ${CURRENT_MTU}"
fi

#-------------------------------------------------------------------------------
section "TCP BUFFER SIZES"
#-------------------------------------------------------------------------------

# Increase TCP buffer sizes for high-bandwidth links
sysctl -w net.core.rmem_max=67108864 > /dev/null
sysctl -w net.core.wmem_max=67108864 > /dev/null
sysctl -w net.core.rmem_default=1048576 > /dev/null
sysctl -w net.core.wmem_default=1048576 > /dev/null
sysctl -w net.ipv4.tcp_rmem="4096 1048576 67108864" > /dev/null
sysctl -w net.ipv4.tcp_wmem="4096 1048576 67108864" > /dev/null
applied "TCP buffers: 64MB max, 1MB default"

# TCP window scaling (should be on by default)
sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null
applied "TCP window scaling enabled"

# Increase max backlog for high-speed
sysctl -w net.core.netdev_max_backlog=250000 > /dev/null
applied "Net device max backlog: 250000"

# Increase socket buffer max
sysctl -w net.core.optmem_max=67108864 > /dev/null
applied "Socket option memory max: 64MB"

#-------------------------------------------------------------------------------
section "TCP CONGESTION & PERFORMANCE"
#-------------------------------------------------------------------------------

# Use BBR congestion control if available
if modprobe tcp_bbr 2>/dev/null; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
    sysctl -w net.core.default_qdisc=fq > /dev/null
    applied "TCP congestion control: BBR with fq qdisc"
else
    skipped "BBR not available, using $(sysctl -n net.ipv4.tcp_congestion_control)"
fi

# Disable slow start after idle (helps sustained transfers)
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null
applied "Disabled TCP slow start after idle"

# Enable TCP timestamps for better RTT estimation
sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null
applied "TCP timestamps enabled"

# Disable TCP metrics cache (prevents stale cached values)
sysctl -w net.ipv4.tcp_no_metrics_save=1 > /dev/null
applied "TCP metrics cache disabled"

#-------------------------------------------------------------------------------
section "VMXNET3 RING BUFFER & QUEUES"
#-------------------------------------------------------------------------------

# Increase ring buffer sizes
CURRENT_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current/{found=1} found && /RX:/{print $2; exit}')
MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set/{found=1} found && /RX:/{print $2; exit}')

if [[ -n "$MAX_RX" && -n "$CURRENT_RX" && "$CURRENT_RX" -lt "$MAX_RX" ]]; then
    ethtool -G "$IFACE" rx "$MAX_RX" tx "$MAX_RX" 2>/dev/null
    applied "Ring buffers set to max: ${MAX_RX} (was ${CURRENT_RX})"
else
    skipped "Ring buffers already at max (${CURRENT_RX:-unknown})"
fi

# Enable multi-queue RSS if available
NUM_QUEUES=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Current/{found=1} found && /Combined:/{print $2; exit}')
MAX_QUEUES=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set/{found=1} found && /Combined:/{print $2; exit}')

if [[ -n "$MAX_QUEUES" && -n "$NUM_QUEUES" && "$NUM_QUEUES" -lt "$MAX_QUEUES" ]]; then
    ethtool -L "$IFACE" combined "$MAX_QUEUES" 2>/dev/null
    applied "RSS queues set to max: ${MAX_QUEUES} (was ${NUM_QUEUES})"
else
    skipped "RSS queues already at max (${NUM_QUEUES:-unknown})"
fi

# Increase interrupt coalescing for throughput (trades latency for bandwidth)
ethtool -C "$IFACE" rx-usecs 64 tx-usecs 64 2>/dev/null && \
    applied "Interrupt coalescing: 64us" || \
    skipped "Interrupt coalescing not adjustable"

# Enable GRO/GSO/TSO offloads
ethtool -K "$IFACE" gro on gso on tso on 2>/dev/null
applied "Offloads enabled: GRO, GSO, TSO"

# Enable LRO if available
ethtool -K "$IFACE" lro on 2>/dev/null && \
    applied "LRO enabled" || \
    skipped "LRO not available"

#-------------------------------------------------------------------------------
section "NCCL SOCKET TUNING"
#-------------------------------------------------------------------------------

# These help NCCL when using Socket transport (non-RDMA)
sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null
applied "TCP Fast Open enabled"

# Increase connection tracking for many GPU-to-GPU connections
sysctl -w net.netfilter.nf_conntrack_max=524288 2>/dev/null && \
    applied "Connection tracking max: 524288" || \
    skipped "nf_conntrack not available"

#-------------------------------------------------------------------------------
section "PERSIST SETTINGS"
#-------------------------------------------------------------------------------

SYSCTL_FILE="/etc/sysctl.d/99-network-tuning.conf"
cat > "$SYSCTL_FILE" << 'EOF'
# High-speed network tuning for vLLM/Ray cluster
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 67108864
net.ipv4.tcp_wmem=4096 1048576 67108864
net.ipv4.tcp_window_scaling=1
net.core.netdev_max_backlog=250000
net.core.optmem_max=67108864
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
EOF
applied "Sysctl settings saved to ${SYSCTL_FILE}"

echo ""

#-------------------------------------------------------------------------------
section "VERIFICATION"
#-------------------------------------------------------------------------------

echo -e "  MTU:          ${BOLD}$(ip link show $IFACE | grep -oP 'mtu \K[0-9]+')${NC}"
echo -e "  Speed:        ${BOLD}$(ethtool $IFACE 2>/dev/null | grep 'Speed:' | awk '{print $2}')${NC}"
echo -e "  Congestion:   ${BOLD}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "  TCP rmem max: ${BOLD}$(sysctl -n net.core.rmem_max) bytes${NC}"
echo -e "  TCP wmem max: ${BOLD}$(sysctl -n net.core.wmem_max) bytes${NC}"
echo -e "  Ring RX:      ${BOLD}$(ethtool -g $IFACE 2>/dev/null | awk '/Current/{found=1} found && /RX:/{print $2; exit}')${NC}"
echo -e "  RSS queues:   ${BOLD}$(ethtool -l $IFACE 2>/dev/null | awk '/Current/{found=1} found && /Combined:/{print $2; exit}')${NC}"

echo ""
echo -e "${GREEN}Done! Run on the OTHER node too, then re-run the interconnect benchmark.${NC}"
echo ""
echo -e "${YELLOW}NOTE: MTU 9000 requires jumbo frames enabled on the vSwitch in vSphere.${NC}"
echo -e "${YELLOW}If MTU 9000 breaks connectivity, revert with: sudo ip link set ${IFACE} mtu 1500${NC}"
echo ""
