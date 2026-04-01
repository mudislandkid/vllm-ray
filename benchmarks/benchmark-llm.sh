#!/bin/bash
#===============================================================================
#  LLM INFERENCE PERFORMANCE BENCHMARK
#  Tests: Time to First Token, Generation Speed, Throughput, Concurrency
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

# Load .env from parent
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Defaults
API_BASE="http://${HEAD_NODE_IP:-localhost}:${VLLM_PORT:-8000}"
QUICK_MODE=false
CONCURRENCY_LEVELS=(1 2 4 8)
OUTPUT_LENGTHS=(32 128 512)
REPORT_FILE=""

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           LLM INFERENCE PERFORMANCE BENCHMARK                    ║"
    echo "║                                                                  ║"
    echo "║  Tests: TTFT • Token Speed • Throughput • Concurrency           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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
            CONCURRENCY_LEVELS=(1 4)
            OUTPUT_LENGTHS=(32 128)
            shift
            ;;
        --api)
            API_BASE="$2"
            shift 2
            ;;
        --report)
            mkdir -p "$REPORT_DIR"
            REPORT_FILE="${REPORT_DIR}/${HOSTNAME}_llm_benchmark_${TIMESTAMP}.txt"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick       Run reduced test set"
            echo "  --api URL     vLLM API base URL (default: http://\$HEAD_NODE_IP:\$VLLM_PORT)"
            echo "  --report      Save results to benchmarks/reports/"
            echo "  -h, --help    Show this help"
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

#-------------------------------------------------------------------------------
# Preflight check
#-------------------------------------------------------------------------------
check_api() {
    if ! curl -s "${API_BASE}/health" &>/dev/null; then
        print_error "Cannot reach vLLM at ${API_BASE}"
        echo "  Start a model first: ./manage.sh serve <model>"
        exit 1
    fi
}

get_model_name() {
    curl -s "${API_BASE}/v1/models" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = data.get('data', [])
if models:
    print(models[0]['id'])
" 2>/dev/null
}

#-------------------------------------------------------------------------------
# Single request benchmark - measures TTFT and generation speed
#-------------------------------------------------------------------------------
bench_single_request() {
    local prompt="$1"
    local max_tokens="$2"
    local model="$3"

    python3 -c "
import json, time, sys
try:
    from urllib.request import urlopen, Request
except ImportError:
    print(json.dumps({'error': 'urllib not available'}))
    sys.exit(1)

api_base = '${API_BASE}'
model = '${model}'
prompt = '''${prompt}'''
max_tokens = ${max_tokens}

# Streaming request for TTFT measurement
payload = json.dumps({
    'model': model,
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': max_tokens,
    'temperature': 0.0,
    'stream': True
}).encode()

req = Request(f'{api_base}/v1/chat/completions', data=payload,
              headers={'Content-Type': 'application/json'})

start_time = time.perf_counter()
first_token_time = None
token_count = 0

try:
    with urlopen(req, timeout=300) as resp:
        buffer = b''
        while True:
            chunk = resp.read(1)
            if not chunk:
                break
            buffer += chunk
            if b'\n' in buffer:
                lines = buffer.split(b'\n')
                buffer = lines[-1]
                for line in lines[:-1]:
                    line = line.strip()
                    if not line or line == b'data: [DONE]':
                        continue
                    if line.startswith(b'data: '):
                        try:
                            data = json.loads(line[6:])
                            delta = data.get('choices', [{}])[0].get('delta', {})
                            content = delta.get('content', '')
                            if content:
                                if first_token_time is None:
                                    first_token_time = time.perf_counter()
                                token_count += 1
                        except json.JSONDecodeError:
                            pass
except Exception as e:
    print(json.dumps({'error': str(e)}))
    sys.exit(1)

end_time = time.perf_counter()
total_time = end_time - start_time
ttft = (first_token_time - start_time) if first_token_time else total_time
gen_time = (end_time - first_token_time) if first_token_time else 0

result = {
    'ttft': round(ttft * 1000, 1),
    'total_time': round(total_time, 3),
    'tokens': token_count,
    'gen_time': round(gen_time, 3),
    'tokens_per_sec': round(token_count / gen_time, 2) if gen_time > 0 else 0
}
print(json.dumps(result))
" 2>/dev/null
}

#-------------------------------------------------------------------------------
# Non-streaming request for throughput measurement
#-------------------------------------------------------------------------------
bench_throughput_request() {
    local prompt="$1"
    local max_tokens="$2"
    local model="$3"

    local start end total_time
    start=$(date +%s%N)

    local response
    response=$(curl -s -w "\n%{time_total}" "${API_BASE}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${model}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
            \"max_tokens\": ${max_tokens},
            \"temperature\": 0.0
        }" 2>/dev/null)

    local curl_time
    curl_time=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    local tokens
    tokens=$(echo "$body" | python3 -c "
import json, sys
data = json.load(sys.stdin)
usage = data.get('usage', {})
print(usage.get('completion_tokens', 0))
" 2>/dev/null)

    echo "${tokens:-0} ${curl_time}"
}

#-------------------------------------------------------------------------------
# Concurrent request benchmark
#-------------------------------------------------------------------------------
bench_concurrent() {
    local concurrency="$1"
    local max_tokens="$2"
    local model="$3"
    local num_requests="$4"

    local prompts=(
        "Explain the concept of distributed computing in detail."
        "Write a Python function to implement a binary search tree."
        "Describe the architecture of a modern web application."
        "What are the key principles of object-oriented programming?"
        "Explain how neural networks learn through backpropagation."
        "Write a detailed comparison of SQL and NoSQL databases."
        "Describe the TCP/IP networking model and its layers."
        "Explain the CAP theorem and its implications for distributed systems."
    )

    local tmpdir
    tmpdir=$(mktemp -d)
    local start_time
    start_time=$(date +%s%N)

    local running=0
    local launched=0

    for ((i=0; i<num_requests; i++)); do
        local prompt="${prompts[$((i % ${#prompts[@]}))]}"
        (
            local result
            result=$(curl -s -o /dev/null -w "%{time_total}" \
                "${API_BASE}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"${model}\",
                    \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
                    \"max_tokens\": ${max_tokens},
                    \"temperature\": 0.0
                }" 2>/dev/null)
            echo "$result" > "${tmpdir}/req_${i}.txt"
        ) &

        launched=$((launched + 1))
        running=$((running + 1))

        if ((running >= concurrency)); then
            wait -n 2>/dev/null || true
            running=$((running - 1))
        fi
    done

    wait

    local end_time
    end_time=$(date +%s%N)
    local wall_time
    wall_time=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc)

    # Collect results
    local total_latency=0
    local min_latency=999999
    local max_latency=0
    local count=0

    for f in "${tmpdir}"/req_*.txt; do
        if [[ -f "$f" ]]; then
            local latency
            latency=$(cat "$f")
            if [[ -n "$latency" && "$latency" != "0.000000" ]]; then
                total_latency=$(echo "$total_latency + $latency" | bc)
                count=$((count + 1))
                if (( $(echo "$latency < $min_latency" | bc -l) )); then
                    min_latency=$latency
                fi
                if (( $(echo "$latency > $max_latency" | bc -l) )); then
                    max_latency=$latency
                fi
            fi
        fi
    done

    rm -rf "$tmpdir"

    local avg_latency=0
    local rps=0
    if ((count > 0)); then
        avg_latency=$(echo "scale=3; $total_latency / $count" | bc)
        rps=$(echo "scale=2; $count / $wall_time" | bc)
    fi

    echo "${count} ${wall_time} ${avg_latency} ${min_latency} ${max_latency} ${rps}"
}

#===============================================================================
# MAIN
#===============================================================================

print_header

echo -e "  API endpoint: ${BOLD}${API_BASE}${NC}"
echo ""

check_api

MODEL=$(get_model_name)
if [[ -z "$MODEL" ]]; then
    print_error "No model loaded. Start one with: ./manage.sh serve <model>"
    exit 1
fi

echo -e "  Model: ${BOLD}${MODEL}${NC}"
echo -e "  Quick mode: ${BOLD}${QUICK_MODE}${NC}"

if [[ -n "$REPORT_FILE" ]]; then
    echo -e "  Report: ${BOLD}${REPORT_FILE}${NC}"
fi

#-------------------------------------------------------------------------------
# Test 1: Time to First Token (TTFT)
#-------------------------------------------------------------------------------
print_section "TIME TO FIRST TOKEN (TTFT)"

print_info "Measures latency from request to first token streamed back"
echo ""

TTFT_PROMPTS=(
    "Hi"
    "Explain quantum computing"
    "Write a comprehensive essay about the history of artificial intelligence, covering the major breakthroughs, key researchers, and pivotal moments that shaped the field from its inception to the present day"
)
TTFT_LABELS=("Short prompt (2 tokens)" "Medium prompt (3 tokens)" "Long prompt (~30 tokens)")

for i in "${!TTFT_PROMPTS[@]}"; do
    print_subheader "${TTFT_LABELS[$i]}"

    result=$(bench_single_request "${TTFT_PROMPTS[$i]}" 32 "$MODEL")
    error=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)

    if [[ -n "$error" && "$error" != "None" ]]; then
        print_error "Request failed: $error"
        continue
    fi

    ttft=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ttft'])" 2>/dev/null)
    tps=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tokens_per_sec'])" 2>/dev/null)
    tokens=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tokens'])" 2>/dev/null)

    print_result "TTFT" "${ttft}" "ms"
    print_result "Tokens generated" "${tokens}" ""
    print_result "Generation speed" "${tps}" "tok/s"
done

#-------------------------------------------------------------------------------
# Test 2: Generation Speed at Different Output Lengths
#-------------------------------------------------------------------------------
print_section "GENERATION SPEED vs OUTPUT LENGTH"

print_info "Measures tokens/sec at different max_tokens values"
echo ""

for max_tokens in "${OUTPUT_LENGTHS[@]}"; do
    print_subheader "max_tokens=${max_tokens}"

    result=$(bench_single_request "Write a detailed technical article about Linux kernel internals." "$max_tokens" "$MODEL")
    error=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)

    if [[ -n "$error" && "$error" != "None" ]]; then
        print_error "Request failed: $error"
        continue
    fi

    ttft=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ttft'])" 2>/dev/null)
    tps=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tokens_per_sec'])" 2>/dev/null)
    tokens=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['tokens'])" 2>/dev/null)
    total=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_time'])" 2>/dev/null)

    print_result "Tokens generated" "${tokens}" ""
    print_result "Total time" "${total}" "s"
    print_result "TTFT" "${ttft}" "ms"
    print_result "Generation speed" "${tps}" "tok/s"
done

#-------------------------------------------------------------------------------
# Test 3: Concurrent Request Throughput
#-------------------------------------------------------------------------------
print_section "CONCURRENT REQUEST THROUGHPUT"

print_info "Measures how the server handles multiple simultaneous requests"
echo ""

MAX_TOKENS_CONCURRENT=128

for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
    num_requests=$((concurrency * 2))
    if $QUICK_MODE; then
        num_requests=$concurrency
    fi

    print_subheader "Concurrency: ${concurrency} (${num_requests} requests)"

    result=$(bench_concurrent "$concurrency" "$MAX_TOKENS_CONCURRENT" "$MODEL" "$num_requests")

    count=$(echo "$result" | awk '{print $1}')
    wall=$(echo "$result" | awk '{print $2}')
    avg=$(echo "$result" | awk '{print $3}')
    min=$(echo "$result" | awk '{print $4}')
    max=$(echo "$result" | awk '{print $5}')
    rps=$(echo "$result" | awk '{print $6}')

    print_result "Completed requests" "${count}/${num_requests}" ""
    print_result "Wall clock time" "${wall}" "s"
    print_result "Avg latency" "${avg}" "s"
    print_result "Min latency" "${min}" "s"
    print_result "Max latency" "${max}" "s"
    print_result "Requests/sec" "${rps}" ""
done

#-------------------------------------------------------------------------------
# Test 4: Sustained Throughput (batch of sequential requests)
#-------------------------------------------------------------------------------
print_section "SUSTAINED THROUGHPUT"

print_info "Rapid-fire sequential requests to measure sustained performance"
echo ""

SUSTAINED_COUNT=10
if $QUICK_MODE; then
    SUSTAINED_COUNT=5
fi

print_subheader "${SUSTAINED_COUNT} sequential requests @ 128 max_tokens"

total_tokens=0
total_time=0

for ((i=1; i<=SUSTAINED_COUNT; i++)); do
    result=$(bench_throughput_request "Explain concept number ${i} in computer science." 128 "$MODEL")
    tokens=$(echo "$result" | awk '{print $1}')
    req_time=$(echo "$result" | awk '{print $2}')

    total_tokens=$((total_tokens + tokens))
    total_time=$(echo "$total_time + $req_time" | bc)

    printf "  Request %2d: %3d tokens in %ss\n" "$i" "$tokens" "$req_time"
done

echo ""
avg_time=$(echo "scale=3; $total_time / $SUSTAINED_COUNT" | bc)
avg_tokens=$(echo "scale=1; $total_tokens / $SUSTAINED_COUNT" | bc)
overall_tps=$(echo "scale=2; $total_tokens / $total_time" | bc)

print_result "Total tokens generated" "${total_tokens}" ""
print_result "Total time" "${total_time}" "s"
print_result "Avg tokens per request" "${avg_tokens}" ""
print_result "Avg request time" "${avg_time}" "s"
print_result "Overall throughput" "${overall_tps}" "tok/s"

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_section "BENCHMARK COMPLETE"

echo -e "  Model:     ${BOLD}${MODEL}${NC}"
echo -e "  Endpoint:  ${BOLD}${API_BASE}${NC}"
echo -e "  Timestamp: ${BOLD}$(date)${NC}"

if [[ -n "$REPORT_FILE" ]]; then
    echo ""
    echo -e "  Report saved to: ${BOLD}${REPORT_FILE}${NC}"
fi

echo ""
