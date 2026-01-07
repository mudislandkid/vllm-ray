#!/bin/bash
#===============================================================================
#  NETWORK PERFORMANCE BENCHMARK
#  Tests: Latency, Bandwidth (TCP/UDP), Multi-stream throughput
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

REMOTE_HOST=""
QUICK_MODE=false
TEST_DURATION=10
PARALLEL_STREAMS=4

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
        -r|--remote)
            REMOTE_HOST="$2"
            shift 2
            ;;
        --quick)
            QUICK_MODE=true
            TEST_DURATION=5
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$REMOTE_HOST" ]]; then
    echo "Error: Remote host required. Use -r <host>"
    exit 1
fi

echo ""
echo "  Testing network to: $REMOTE_HOST"
echo ""

#-------------------------------------------------------------------------------
# PING LATENCY TEST
#-------------------------------------------------------------------------------
print_subheader "Ping Latency Test"

if ping -c 1 "$REMOTE_HOST" &> /dev/null; then
    PING_RESULT=$(ping -c 10 -i 0.2 "$REMOTE_HOST" 2>/dev/null | tail -1)
    if [[ -n "$PING_RESULT" ]]; then
        # Extract min/avg/max/mdev
        LATENCY=$(echo "$PING_RESULT" | awk -F'/' '{print $5}')
        MIN_LAT=$(echo "$PING_RESULT" | awk -F'/' '{print $4}')
        MAX_LAT=$(echo "$PING_RESULT" | awk -F'/' '{print $6}')

        print_result "Average Latency" "$LATENCY" "ms"
        print_result "Min Latency" "$MIN_LAT" "ms"
        print_result "Max Latency" "$MAX_LAT" "ms"
    fi
else
    echo "  ✗ Cannot reach $REMOTE_HOST"
    exit 1
fi

#-------------------------------------------------------------------------------
# IPERF3 BANDWIDTH TEST
#-------------------------------------------------------------------------------
if command -v iperf3 &> /dev/null; then
    print_subheader "TCP Bandwidth Test (Single Stream)"
    print_info "Running ${TEST_DURATION}s test..."

    # Try to connect to iperf3 server
    IPERF_RESULT=$(iperf3 -c "$REMOTE_HOST" -t "$TEST_DURATION" -J 2>/dev/null)

    if [[ $? -eq 0 ]] && [[ -n "$IPERF_RESULT" ]]; then
        # Parse JSON output
        SEND_BPS=$(echo "$IPERF_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bps = data.get('end', {}).get('sum_sent', {}).get('bits_per_second', 0)
print(f'{bps/1e9:.2f}')
" 2>/dev/null)

        RECV_BPS=$(echo "$IPERF_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bps = data.get('end', {}).get('sum_received', {}).get('bits_per_second', 0)
print(f'{bps/1e9:.2f}')
" 2>/dev/null)

        print_result "Send Bandwidth" "$SEND_BPS" "Gbps"
        print_result "Receive Bandwidth" "$RECV_BPS" "Gbps"

        # Multi-stream test
        print_subheader "TCP Bandwidth Test (${PARALLEL_STREAMS} Parallel Streams)"
        print_info "Running ${TEST_DURATION}s test..."

        IPERF_MULTI=$(iperf3 -c "$REMOTE_HOST" -t "$TEST_DURATION" -P "$PARALLEL_STREAMS" -J 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            MULTI_BPS=$(echo "$IPERF_MULTI" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bps = data.get('end', {}).get('sum_sent', {}).get('bits_per_second', 0)
print(f'{bps/1e9:.2f}')
" 2>/dev/null)
            print_result "Aggregate Bandwidth" "$MULTI_BPS" "Gbps"
        fi

        # UDP test for jitter
        if ! $QUICK_MODE; then
            print_subheader "UDP Test (Jitter & Packet Loss)"
            print_info "Running ${TEST_DURATION}s test at 1Gbps..."

            UDP_RESULT=$(iperf3 -c "$REMOTE_HOST" -t "$TEST_DURATION" -u -b 1G -J 2>/dev/null)

            if [[ $? -eq 0 ]]; then
                UDP_STATS=$(echo "$UDP_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
udp = data.get('end', {}).get('sum', {})
jitter = udp.get('jitter_ms', 0)
lost = udp.get('lost_percent', 0)
print(f'{jitter:.3f},{lost:.2f}')
" 2>/dev/null)

                JITTER=$(echo "$UDP_STATS" | cut -d',' -f1)
                LOSS=$(echo "$UDP_STATS" | cut -d',' -f2)

                print_result "Jitter" "$JITTER" "ms"
                print_result "Packet Loss" "$LOSS" "%"
            fi
        fi

        # Reverse test (download)
        print_subheader "Reverse Test (Download from Remote)"
        print_info "Running ${TEST_DURATION}s test..."

        IPERF_REV=$(iperf3 -c "$REMOTE_HOST" -t "$TEST_DURATION" -R -J 2>/dev/null)

        if [[ $? -eq 0 ]]; then
            REV_BPS=$(echo "$IPERF_REV" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bps = data.get('end', {}).get('sum_received', {}).get('bits_per_second', 0)
print(f'{bps/1e9:.2f}')
" 2>/dev/null)
            print_result "Download Bandwidth" "$REV_BPS" "Gbps"
        fi

    else
        echo ""
        echo "  ⚠ iperf3 server not running on $REMOTE_HOST"
        echo ""
        echo "  To enable bandwidth tests, run on the remote host:"
        echo "    iperf3 -s"
        echo ""
    fi
else
    echo ""
    echo "  ⚠ iperf3 not installed. Install with:"
    echo "    apt install iperf3  # Debian/Ubuntu"
    echo "    yum install iperf3  # RHEL/CentOS"
    echo ""
fi

#-------------------------------------------------------------------------------
# MTU CHECK
#-------------------------------------------------------------------------------
print_subheader "MTU & Path Analysis"

# Get local MTU
LOCAL_IF=$(ip route get "$REMOTE_HOST" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
if [[ -n "$LOCAL_IF" ]]; then
    LOCAL_MTU=$(ip link show "$LOCAL_IF" 2>/dev/null | grep -oP 'mtu \K\d+')
    print_result "Local Interface" "$LOCAL_IF" ""
    print_result "Local MTU" "$LOCAL_MTU" "bytes"
fi

# Test path MTU with large ping
if ping -c 1 -M do -s 8972 "$REMOTE_HOST" &> /dev/null; then
    print_result "Jumbo Frames (9000)" "Supported" "✓"
elif ping -c 1 -M do -s 1472 "$REMOTE_HOST" &> /dev/null; then
    print_result "Standard MTU (1500)" "Supported" "✓"
    print_result "Jumbo Frames" "Not supported" ""
fi

echo ""
