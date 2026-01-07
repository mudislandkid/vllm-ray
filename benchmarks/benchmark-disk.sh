#!/bin/bash
#===============================================================================
#  DISK I/O PERFORMANCE BENCHMARK
#  Tests: Sequential R/W, Random R/W, IOPS
#===============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

QUICK_MODE=false
TEST_SIZE="1G"
TEST_DIR="${TEST_DIR:-/tmp/disk_benchmark}"
CLEANUP=true

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
            TEST_SIZE="256M"
            shift
            ;;
        --dir)
            TEST_DIR="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Create test directory
mkdir -p "$TEST_DIR"
TEST_FILE="${TEST_DIR}/benchmark_test_file"

# Get disk info
MOUNT_POINT=$(df "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $NF}')
DISK_DEVICE=$(df "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $1}')
DISK_SIZE=$(df -h "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
DISK_FREE=$(df -h "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
FS_TYPE=$(df -T "$TEST_DIR" 2>/dev/null | tail -1 | awk '{print $2}')

echo ""
echo "  Test Directory: $TEST_DIR"
echo "  Mount Point:    $MOUNT_POINT"
echo "  Device:         $DISK_DEVICE"
echo "  Filesystem:     $FS_TYPE"
echo "  Disk Size:      $DISK_SIZE"
echo "  Free Space:     $DISK_FREE"
echo "  Test Size:      $TEST_SIZE"
echo ""

#-------------------------------------------------------------------------------
# SEQUENTIAL WRITE TEST (dd)
#-------------------------------------------------------------------------------
print_subheader "Sequential Write Test"
print_info "Writing $TEST_SIZE with dd..."

# Clear cache
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Sequential write
DD_WRITE=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=${TEST_SIZE%?} conv=fdatasync 2>&1)
WRITE_SPEED=$(echo "$DD_WRITE" | grep -oP '[\d.]+ [GM]B/s' | tail -1)

if [[ -z "$WRITE_SPEED" ]]; then
    # Try alternative parsing
    BYTES=$(echo "$DD_WRITE" | grep -oP '\d+ bytes' | grep -oP '\d+')
    TIME=$(echo "$DD_WRITE" | grep -oP '[\d.]+ s' | grep -oP '[\d.]+')
    if [[ -n "$BYTES" ]] && [[ -n "$TIME" ]]; then
        SPEED_MBS=$(python3 -c "print(f'{$BYTES / $TIME / 1e6:.1f}')" 2>/dev/null)
        WRITE_SPEED="${SPEED_MBS} MB/s"
    fi
fi

print_result "Sequential Write" "${WRITE_SPEED:-N/A}" ""

#-------------------------------------------------------------------------------
# SEQUENTIAL READ TEST (dd)
#-------------------------------------------------------------------------------
print_subheader "Sequential Read Test"
print_info "Reading $TEST_SIZE with dd..."

# Clear cache
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Sequential read
DD_READ=$(dd if="$TEST_FILE" of=/dev/null bs=1M 2>&1)
READ_SPEED=$(echo "$DD_READ" | grep -oP '[\d.]+ [GM]B/s' | tail -1)

if [[ -z "$READ_SPEED" ]]; then
    BYTES=$(echo "$DD_READ" | grep -oP '\d+ bytes' | grep -oP '\d+')
    TIME=$(echo "$DD_READ" | grep -oP '[\d.]+ s' | grep -oP '[\d.]+')
    if [[ -n "$BYTES" ]] && [[ -n "$TIME" ]]; then
        SPEED_MBS=$(python3 -c "print(f'{$BYTES / $TIME / 1e6:.1f}')" 2>/dev/null)
        READ_SPEED="${SPEED_MBS} MB/s"
    fi
fi

print_result "Sequential Read" "${READ_SPEED:-N/A}" ""

#-------------------------------------------------------------------------------
# FIO TESTS (if available)
#-------------------------------------------------------------------------------
if command -v fio &> /dev/null; then
    print_subheader "Random I/O Tests (fio)"

    FIO_SIZE="256M"
    FIO_RUNTIME="10"
    $QUICK_MODE && FIO_RUNTIME="5"

    # Random Read
    print_info "Random 4K Read test (${FIO_RUNTIME}s)..."

    FIO_RANDREAD=$(fio --name=randread --ioengine=libaio --direct=1 --bs=4k \
        --iodepth=64 --size="$FIO_SIZE" --rw=randread --runtime="$FIO_RUNTIME" \
        --filename="$TEST_FILE" --output-format=json 2>/dev/null)

    RANDREAD_IOPS=$(echo "$FIO_RANDREAD" | python3 -c "
import sys, json
data = json.load(sys.stdin)
iops = data['jobs'][0]['read']['iops']
print(f'{iops:.0f}')
" 2>/dev/null)

    RANDREAD_BW=$(echo "$FIO_RANDREAD" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bw = data['jobs'][0]['read']['bw'] / 1024  # KB/s to MB/s
print(f'{bw:.1f}')
" 2>/dev/null)

    RANDREAD_LAT=$(echo "$FIO_RANDREAD" | python3 -c "
import sys, json
data = json.load(sys.stdin)
lat = data['jobs'][0]['read']['lat_ns']['mean'] / 1e6  # ns to ms
print(f'{lat:.2f}')
" 2>/dev/null)

    print_result "Random Read IOPS" "${RANDREAD_IOPS:-N/A}" "IOPS"
    print_result "Random Read Bandwidth" "${RANDREAD_BW:-N/A}" "MB/s"
    print_result "Random Read Latency" "${RANDREAD_LAT:-N/A}" "ms"

    # Random Write
    print_info "Random 4K Write test (${FIO_RUNTIME}s)..."

    FIO_RANDWRITE=$(fio --name=randwrite --ioengine=libaio --direct=1 --bs=4k \
        --iodepth=64 --size="$FIO_SIZE" --rw=randwrite --runtime="$FIO_RUNTIME" \
        --filename="$TEST_FILE" --output-format=json 2>/dev/null)

    RANDWRITE_IOPS=$(echo "$FIO_RANDWRITE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
iops = data['jobs'][0]['write']['iops']
print(f'{iops:.0f}')
" 2>/dev/null)

    RANDWRITE_BW=$(echo "$FIO_RANDWRITE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bw = data['jobs'][0]['write']['bw'] / 1024
print(f'{bw:.1f}')
" 2>/dev/null)

    print_result "Random Write IOPS" "${RANDWRITE_IOPS:-N/A}" "IOPS"
    print_result "Random Write Bandwidth" "${RANDWRITE_BW:-N/A}" "MB/s"

    # Mixed Random R/W
    if ! $QUICK_MODE; then
        print_info "Mixed Random R/W test (70/30 read/write)..."

        FIO_MIXED=$(fio --name=randrw --ioengine=libaio --direct=1 --bs=4k \
            --iodepth=64 --size="$FIO_SIZE" --rw=randrw --rwmixread=70 \
            --runtime="$FIO_RUNTIME" --filename="$TEST_FILE" --output-format=json 2>/dev/null)

        MIXED_IOPS=$(echo "$FIO_MIXED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
read_iops = data['jobs'][0]['read']['iops']
write_iops = data['jobs'][0]['write']['iops']
print(f'{read_iops + write_iops:.0f}')
" 2>/dev/null)

        print_result "Mixed R/W IOPS (70/30)" "${MIXED_IOPS:-N/A}" "IOPS"
    fi

else
    print_subheader "Random I/O Tests"
    echo "  ⚠ fio not installed. Install for detailed random I/O tests:"
    echo "    apt install fio  # Debian/Ubuntu"
    echo "    yum install fio  # RHEL/CentOS"
fi

#-------------------------------------------------------------------------------
# HDPARM TEST (if available and applicable)
#-------------------------------------------------------------------------------
if command -v hdparm &> /dev/null && [[ "$DISK_DEVICE" == /dev/* ]]; then
    print_subheader "Direct Device Test (hdparm)"

    # Get base device (strip partition number)
    BASE_DEVICE=$(echo "$DISK_DEVICE" | sed 's/[0-9]*$//' | sed 's/p$//')

    if [[ -b "$BASE_DEVICE" ]]; then
        HDPARM_RESULT=$(hdparm -t "$BASE_DEVICE" 2>/dev/null | grep "Timing")
        if [[ -n "$HDPARM_RESULT" ]]; then
            HDPARM_SPEED=$(echo "$HDPARM_RESULT" | grep -oP '[\d.]+ [GM]B/sec')
            print_result "Buffered Disk Read" "${HDPARM_SPEED:-N/A}" ""
        fi
    fi
fi

#-------------------------------------------------------------------------------
# CLEANUP
#-------------------------------------------------------------------------------
if $CLEANUP; then
    rm -f "$TEST_FILE"
fi

echo ""
