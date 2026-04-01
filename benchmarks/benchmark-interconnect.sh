#!/bin/bash
#===============================================================================
#  INTER-NODE INTERCONNECT BENCHMARK
#  Tests: Raw Network, NCCL AllReduce, NCCL AllGather, P2P GPU Transfer
#
#  Run BEFORE and AFTER enabling RoCE/RDMA to measure improvement.
#  Produces a single summary you can compare side-by-side.
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PARENT_DIR}/.env"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Load .env
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

HEAD_IP="${HEAD_NODE_IP:-10.50.100.100}"
WORKER_IP="${WORKER_NODE_IP:-10.50.100.101}"
QUICK_MODE=false
REPORT_FILE=""
LABEL=""

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           INTER-NODE INTERCONNECT BENCHMARK                      ║"
    echo "║                                                                  ║"
    echo "║  Tests: Network • NCCL AllReduce • AllGather • P2P Transfer     ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_result() {
    local label="$1"
    local value="$2"
    local unit="$3"
    printf "  ${GREEN}%-35s${NC} ${BOLD}%s${NC} %s\n" "$label:" "$value" "$unit"
}

print_info() {
    echo -e "  ${CYAN}ℹ${NC}  $1"
}

print_subheader() {
    echo ""
    echo -e "  ${YELLOW}▸ $1${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${YELLOW}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --head)
            HEAD_IP="$2"
            shift 2
            ;;
        --worker)
            WORKER_IP="$2"
            shift 2
            ;;
        --label)
            LABEL="$2"
            shift 2
            ;;
        --report)
            mkdir -p "$REPORT_DIR"
            REPORT_FILE="${REPORT_DIR}/${HOSTNAME}_interconnect_${TIMESTAMP}.txt"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick            Run reduced test set (smaller transfers)"
            echo "  --head IP          Head node IP (default: \$HEAD_NODE_IP)"
            echo "  --worker IP        Worker node IP (default: \$WORKER_NODE_IP)"
            echo "  --label TEXT       Label for this run (e.g. 'before-rdma', 'after-rdma')"
            echo "  --report           Save results to benchmarks/reports/"
            echo "  -h, --help         Show this help"
            echo ""
            echo "Example workflow:"
            echo "  # Before enabling RDMA"
            echo "  $0 --label before-rdma --report"
            echo ""
            echo "  # Enable RDMA/RoCE, then:"
            echo "  $0 --label after-rdma --report"
            echo ""
            echo "  # Compare results"
            echo "  diff reports/*before* reports/*after*"
            echo ""
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Tee to report file if requested
if [[ -n "$REPORT_FILE" ]]; then
    exec > >(tee -a "$REPORT_FILE") 2>&1
fi

# Summary accumulators
declare -A SUMMARY

#===============================================================================
# NCCL benchmark Python script (runs inside ray-head container)
#===============================================================================
NCCL_BENCH_SCRIPT='
import ray
import time
import json
import sys
import os

num_warmup = int(os.environ.get("NUM_WARMUP", "3"))
num_iters = int(os.environ.get("NUM_ITERS", "10"))
sizes_mb_str = os.environ.get("SIZES_MB", "1,16,64,256,512,1024")
sizes_mb = [int(s) for s in sizes_mb_str.split(",")]

ray.init(address="auto")

nodes = [n for n in ray.nodes() if n["Alive"]]
total_gpus = int(sum(n["Resources"].get("GPU", 0) for n in nodes))

if total_gpus < 2:
    print(json.dumps({"error": f"Need at least 2 GPUs across nodes, found {total_gpus}"}))
    sys.exit(0)

@ray.remote(num_gpus=1)
class NCCLWorker:
    def __init__(self, rank, world_size, master_addr, master_port):
        import torch
        import torch.distributed as dist
        os.environ["MASTER_ADDR"] = master_addr
        os.environ["MASTER_PORT"] = str(master_port)
        os.environ["RANK"] = str(rank)
        os.environ["WORLD_SIZE"] = str(world_size)
        dist.init_process_group(backend="nccl", rank=rank, world_size=world_size)
        self.rank = rank
        self.device = torch.device("cuda:0")
        self.world_size = world_size

    def bench_allreduce(self, size_bytes, num_warmup, num_iters):
        import torch
        import torch.distributed as dist
        num_elements = size_bytes // 4
        tensor = torch.randn(num_elements, device=self.device)

        for _ in range(num_warmup):
            dist.all_reduce(tensor)
        torch.cuda.synchronize()

        start = time.perf_counter()
        for _ in range(num_iters):
            dist.all_reduce(tensor)
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start

        return elapsed / num_iters

    def bench_allgather(self, size_bytes, num_warmup, num_iters):
        import torch
        import torch.distributed as dist
        num_elements = size_bytes // 4
        tensor = torch.randn(num_elements, device=self.device)
        output = [torch.zeros(num_elements, device=self.device) for _ in range(self.world_size)]

        for _ in range(num_warmup):
            dist.all_gather(output, tensor)
        torch.cuda.synchronize()

        start = time.perf_counter()
        for _ in range(num_iters):
            dist.all_gather(output, tensor)
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start

        return elapsed / num_iters

    def bench_p2p_send(self, size_bytes, dest_rank, num_warmup, num_iters):
        import torch
        import torch.distributed as dist
        num_elements = size_bytes // 4
        tensor = torch.randn(num_elements, device=self.device)

        for _ in range(num_warmup):
            dist.send(tensor, dst=dest_rank)
        torch.cuda.synchronize()

        start = time.perf_counter()
        for _ in range(num_iters):
            dist.send(tensor, dst=dest_rank)
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start

        return elapsed / num_iters

    def bench_p2p_recv(self, size_bytes, src_rank, num_warmup, num_iters):
        import torch
        import torch.distributed as dist
        num_elements = size_bytes // 4
        tensor = torch.zeros(num_elements, device=self.device)

        for _ in range(num_warmup):
            dist.recv(tensor, src=src_rank)
        torch.cuda.synchronize()

        start = time.perf_counter()
        for _ in range(num_iters):
            dist.recv(tensor, src=src_rank)
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start

        return elapsed / num_iters

    def get_info(self):
        import torch
        node_ip = ray.util.get_node_ip_address()
        gpu_name = torch.cuda.get_device_name(0)
        return {"rank": self.rank, "node_ip": node_ip, "gpu": gpu_name}

    def cleanup(self):
        import torch.distributed as dist
        dist.destroy_process_group()

master_addr = sys.argv[1] if len(sys.argv) > 1 else "localhost"
master_port = 29500

# Create workers across all GPUs
workers = []
for i in range(total_gpus):
    w = NCCLWorker.remote(i, total_gpus, master_addr, master_port)
    workers.append(w)

# Get worker placement info
infos = ray.get([w.get_info.remote() for w in workers])

results = {
    "num_gpus": total_gpus,
    "num_nodes": len(nodes),
    "workers": infos,
    "allreduce": [],
    "allgather": [],
    "p2p": [],
    "nccl_env": {}
}

# Capture NCCL env vars
for key in ["NCCL_SOCKET_IFNAME", "NCCL_IB_DISABLE", "NCCL_NET_GDR_LEVEL",
            "NCCL_IB_GID_INDEX", "NCCL_IB_HCA", "NCCL_P2P_LEVEL",
            "NCCL_NET", "NCCL_ALGO", "NCCL_PROTO"]:
    val = os.environ.get(key, "")
    if val:
        results["nccl_env"][key] = val

# AllReduce benchmark
for size_mb in sizes_mb:
    size_bytes = size_mb * 1024 * 1024
    times = ray.get([w.bench_allreduce.remote(size_bytes, num_warmup, num_iters) for w in workers])
    avg_time = max(times)  # allreduce completes when slowest finishes
    bw = (size_bytes * 2 * (total_gpus - 1) / total_gpus) / avg_time / 1e9  # busbw
    results["allreduce"].append({
        "size_mb": size_mb,
        "time_ms": round(avg_time * 1000, 3),
        "busbw_gbps": round(bw, 2)
    })

# AllGather benchmark
for size_mb in sizes_mb:
    size_bytes = size_mb * 1024 * 1024
    times = ray.get([w.bench_allgather.remote(size_bytes, num_warmup, num_iters) for w in workers])
    avg_time = max(times)
    bw = (size_bytes * (total_gpus - 1) / total_gpus) / avg_time / 1e9  # busbw
    results["allgather"].append({
        "size_mb": size_mb,
        "time_ms": round(avg_time * 1000, 3),
        "busbw_gbps": round(bw, 2)
    })

# P2P benchmark (rank 0 -> rank on different node if possible)
dest_rank = total_gpus - 1  # last GPU, likely on worker node
for size_mb in sizes_mb:
    size_bytes = size_mb * 1024 * 1024
    send_fut = workers[0].bench_p2p_send.remote(size_bytes, dest_rank, num_warmup, num_iters)
    recv_fut = workers[dest_rank].bench_p2p_recv.remote(size_bytes, 0, num_warmup, num_iters)
    send_time, recv_time = ray.get([send_fut, recv_fut])
    transfer_time = max(send_time, recv_time)
    bw = size_bytes / transfer_time / 1e9
    results["p2p"].append({
        "size_mb": size_mb,
        "time_ms": round(transfer_time * 1000, 3),
        "bw_gbps": round(bw, 2),
        "src": infos[0]["node_ip"],
        "dst": infos[dest_rank]["node_ip"]
    })

# Cleanup
ray.get([w.cleanup.remote() for w in workers])

print(json.dumps(results))
'

#===============================================================================
# MAIN
#===============================================================================

print_header

if [[ -n "$LABEL" ]]; then
    echo -e "  Label: ${BOLD}${LABEL}${NC}"
fi
echo -e "  Head node:   ${BOLD}${HEAD_IP}${NC}"
echo -e "  Worker node: ${BOLD}${WORKER_IP}${NC}"
echo -e "  Timestamp:   ${BOLD}$(date)${NC}"
echo -e "  Quick mode:  ${BOLD}${QUICK_MODE}${NC}"

if [[ -n "$REPORT_FILE" ]]; then
    echo -e "  Report:      ${BOLD}${REPORT_FILE}${NC}"
fi

#-------------------------------------------------------------------------------
# Test 1: Raw Network Bandwidth (iperf3)
#-------------------------------------------------------------------------------
print_section "RAW NETWORK BANDWIDTH (iperf3)"

print_info "Testing TCP throughput between nodes"
print_info "This measures raw network capacity, not GPU transfer"
echo ""

# Check if iperf3 is available on both ends
if ! command -v iperf3 &>/dev/null; then
    print_error "iperf3 not installed locally. Install with: apt install iperf3"
    SUMMARY[network]="SKIPPED"
else
    # Try to run iperf3 against worker
    print_info "Ensure iperf3 server is running on ${WORKER_IP}: iperf3 -s"
    echo ""

    print_subheader "Single stream"
    result=$(iperf3 -c "$WORKER_IP" -t 5 -f g --json 2>/dev/null || echo "FAIL")
    if [[ "$result" != "FAIL" ]]; then
        bw=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"end\"][\"sum_sent\"][\"bits_per_second\"]/1e9:.2f}')" 2>/dev/null)
        print_result "Single stream throughput" "$bw" "Gbps"
        SUMMARY[net_single]="${bw} Gbps"
    else
        print_error "Could not connect. Is iperf3 -s running on ${WORKER_IP}?"
        SUMMARY[net_single]="FAILED"
    fi

    print_subheader "Multi-stream (8 parallel)"
    result=$(iperf3 -c "$WORKER_IP" -t 5 -P 8 -f g --json 2>/dev/null || echo "FAIL")
    if [[ "$result" != "FAIL" ]]; then
        bw=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"end\"][\"sum_sent\"][\"bits_per_second\"]/1e9:.2f}')" 2>/dev/null)
        print_result "Multi-stream throughput" "$bw" "Gbps"
        SUMMARY[net_multi]="${bw} Gbps"
    else
        print_error "Multi-stream test failed"
        SUMMARY[net_multi]="FAILED"
    fi
fi

#-------------------------------------------------------------------------------
# Test 2: NCCL GPU Communication
#-------------------------------------------------------------------------------
print_section "NCCL GPU COMMUNICATION (via Ray cluster)"

# Check Ray cluster is up
if ! docker exec ray-head ray status &>/dev/null; then
    print_error "Ray cluster not running. Start with: ./manage.sh up"
    echo ""
    exit 1
fi

# Set sizes based on mode
if $QUICK_MODE; then
    SIZES_MB="16,256,1024"
    NUM_ITERS=5
    NUM_WARMUP=2
else
    SIZES_MB="1,16,64,256,512,1024"
    NUM_ITERS=10
    NUM_WARMUP=3
fi

print_info "Running NCCL benchmarks across all GPUs in the Ray cluster"
print_info "Sizes: ${SIZES_MB} MB | Iterations: ${NUM_ITERS} | Warmup: ${NUM_WARMUP}"
echo ""

# Write the benchmark script into the container
docker exec ray-head bash -c "cat > /tmp/nccl_bench.py << 'PYEOF'
${NCCL_BENCH_SCRIPT}
PYEOF"

# Run the benchmark
NCCL_RESULT=$(docker exec -e NUM_WARMUP="$NUM_WARMUP" -e NUM_ITERS="$NUM_ITERS" -e SIZES_MB="$SIZES_MB" \
    ray-head python3 /tmp/nccl_bench.py "$HEAD_IP" 2>/dev/null)

# Check for errors
nccl_error=$(echo "$NCCL_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
if [[ -n "$nccl_error" && "$nccl_error" != "" ]]; then
    print_error "$nccl_error"
    exit 1
fi

# Display worker placement
num_gpus=$(echo "$NCCL_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['num_gpus'])" 2>/dev/null)
num_nodes=$(echo "$NCCL_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['num_nodes'])" 2>/dev/null)
print_info "Cluster: ${num_gpus} GPUs across ${num_nodes} nodes"

echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d['workers']:
    print(f'    Rank {w[\"rank\"]}: {w[\"node_ip\"]} ({w[\"gpu\"]})')
" 2>/dev/null

# Show NCCL config
nccl_env=$(echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
env = d.get('nccl_env', {})
if env:
    for k,v in env.items():
        print(f'    {k}={v}')
else:
    print('    (default NCCL config)')
" 2>/dev/null)
echo ""
print_info "NCCL Configuration:"
echo "$nccl_env"

#--- AllReduce ---
print_subheader "AllReduce (used by Tensor Parallelism)"
echo ""
printf "  ${BOLD}%-12s  %-12s  %-12s${NC}\n" "Size" "Latency" "Bus BW"
printf "  %-12s  %-12s  %-12s\n" "--------" "--------" "--------"

echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
peak = 0
for r in d['allreduce']:
    size = f'{r[\"size_mb\"]} MB'
    latency = f'{r[\"time_ms\"]:.3f} ms'
    bw = f'{r[\"busbw_gbps\"]:.2f} GB/s'
    print(f'  {size:<12}  {latency:<12}  {bw:<12}')
    peak = max(peak, r['busbw_gbps'])
print(f'\n  Peak AllReduce Bus BW: {peak:.2f} GB/s')
" 2>/dev/null

peak_allreduce=$(echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'{max(r[\"busbw_gbps\"] for r in d[\"allreduce\"]):.2f}')
" 2>/dev/null)
SUMMARY[allreduce]="${peak_allreduce} GB/s"

#--- AllGather ---
print_subheader "AllGather (used by Pipeline Parallelism)"
echo ""
printf "  ${BOLD}%-12s  %-12s  %-12s${NC}\n" "Size" "Latency" "Bus BW"
printf "  %-12s  %-12s  %-12s\n" "--------" "--------" "--------"

echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
peak = 0
for r in d['allgather']:
    size = f'{r[\"size_mb\"]} MB'
    latency = f'{r[\"time_ms\"]:.3f} ms'
    bw = f'{r[\"busbw_gbps\"]:.2f} GB/s'
    print(f'  {size:<12}  {latency:<12}  {bw:<12}')
    peak = max(peak, r['busbw_gbps'])
print(f'\n  Peak AllGather Bus BW: {peak:.2f} GB/s')
" 2>/dev/null

peak_allgather=$(echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'{max(r[\"busbw_gbps\"] for r in d[\"allgather\"]):.2f}')
" 2>/dev/null)
SUMMARY[allgather]="${peak_allgather} GB/s"

#--- P2P ---
print_subheader "Point-to-Point GPU Transfer (rank 0 → last rank)"
echo ""
printf "  ${BOLD}%-12s  %-12s  %-12s${NC}\n" "Size" "Latency" "Bandwidth"
printf "  %-12s  %-12s  %-12s\n" "--------" "--------" "--------"

echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
peak = 0
for r in d['p2p']:
    size = f'{r[\"size_mb\"]} MB'
    latency = f'{r[\"time_ms\"]:.3f} ms'
    bw = f'{r[\"bw_gbps\"]:.2f} GB/s'
    print(f'  {size:<12}  {latency:<12}  {bw:<12}')
    peak = max(peak, r['bw_gbps'])
src = d['p2p'][0]['src']
dst = d['p2p'][0]['dst']
print(f'\n  Peak P2P BW: {peak:.2f} GB/s ({src} → {dst})')
" 2>/dev/null

peak_p2p=$(echo "$NCCL_RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'{max(r[\"bw_gbps\"] for r in d[\"p2p\"]):.2f}')
" 2>/dev/null)
SUMMARY[p2p]="${peak_p2p} GB/s"

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_section "SUMMARY"

if [[ -n "$LABEL" ]]; then
    echo -e "  ${BOLD}Run: ${LABEL}${NC}"
    echo ""
fi

echo -e "  ${BOLD}Metric                              Result${NC}"
echo "  ──────────────────────────────────────────────"
[[ -n "${SUMMARY[net_single]}" ]] && printf "  %-36s %s\n" "Network (single stream)" "${SUMMARY[net_single]}"
[[ -n "${SUMMARY[net_multi]}" ]]  && printf "  %-36s %s\n" "Network (8 streams)" "${SUMMARY[net_multi]}"
printf "  %-36s %s\n" "NCCL AllReduce (peak bus BW)" "${SUMMARY[allreduce]}"
printf "  %-36s %s\n" "NCCL AllGather (peak bus BW)" "${SUMMARY[allgather]}"
printf "  %-36s %s\n" "NCCL P2P Transfer (peak BW)" "${SUMMARY[p2p]}"
echo "  ──────────────────────────────────────────────"
echo ""
echo -e "  GPUs: ${BOLD}${num_gpus}${NC} across ${BOLD}${num_nodes}${NC} nodes"
echo -e "  Date: ${BOLD}$(date)${NC}"

if [[ -n "$REPORT_FILE" ]]; then
    echo ""
    echo -e "  Report saved to: ${BOLD}${REPORT_FILE}${NC}"
fi

echo ""
echo -e "  ${CYAN}To compare runs:${NC}"
echo "    $0 --label before-rdma --report"
echo "    # ... enable RDMA ..."
echo "    $0 --label after-rdma --report"
echo ""
