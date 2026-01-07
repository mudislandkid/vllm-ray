#!/bin/bash
# Quick inference test for vLLM Qwen3-VL-30B-A3B server

VLLM_URL="${VLLM_URL:-http://localhost:8000}"
MODEL_NAME="${MODEL_NAME:-qwen3-vl}"

echo "============================================"
echo "vLLM Vision-Language Inference Test"
echo "Server: $VLLM_URL"
echo "Model: $MODEL_NAME"
echo "============================================"
echo

# Test 1: Health check
echo "1. Health Check..."
if curl -sf "$VLLM_URL/health" > /dev/null; then
    echo "   ✓ Server is healthy"
else
    echo "   ✗ Server not responding. Is vLLM running?"
    exit 1
fi
echo

# Test 2: List models
echo "2. Available Models..."
curl -s "$VLLM_URL/v1/models" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(f\"   - {m['id']}\")
" 2>/dev/null || echo "   (Could not parse models)"
echo

# Test 3: Text-only chat completion with timing
echo "3. Text-Only Chat Test..."
START_TIME=$(python3 -c "import time; print(time.time())")
RESPONSE=$(curl -s "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"Write a Python function that calculates factorial. Be concise.\"}
        ],
        \"max_tokens\": 150,
        \"temperature\": 0.7
    }")
END_TIME=$(python3 -c "import time; print(time.time())")
echo "$RESPONSE" | python3 -c "
import sys, json
start = $START_TIME
end = $END_TIME
elapsed = end - start
data = json.load(sys.stdin)
if 'choices' in data:
    content = data['choices'][0]['message']['content']
    print('   Response:')
    for line in content.strip().split('\n')[:10]:
        print(f'   {line}')
    usage = data.get('usage', {})
    prompt_tokens = usage.get('prompt_tokens', 0)
    completion_tokens = usage.get('completion_tokens', 0)
    tps = completion_tokens / elapsed if elapsed > 0 else 0
    print(f\"\n   Tokens: {prompt_tokens} prompt, {completion_tokens} completion\")
    print(f\"   Time: {elapsed:.2f}s | Speed: {tps:.1f} tok/s\")
else:
    print(f\"   Error: {data.get('error', data)}\")
" 2>/dev/null
echo

# Test 4: Vision test with URL image
echo "4. Vision Test (URL image)..."
START_TIME=$(python3 -c "import time; print(time.time())")
RESPONSE=$(curl -s "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [
            {
                \"role\": \"user\",
                \"content\": [
                    {\"type\": \"text\", \"text\": \"Describe this image briefly in one sentence.\"},
                    {\"type\": \"image_url\", \"image_url\": {\"url\": \"https://picsum.photos/id/237/400/300\"}}
                ]
            }
        ],
        \"max_tokens\": 100
    }")
END_TIME=$(python3 -c "import time; print(time.time())")
echo "$RESPONSE" | python3 -c "
import sys, json
start = $START_TIME
end = $END_TIME
elapsed = end - start
data = json.load(sys.stdin)
if 'choices' in data:
    content = data['choices'][0]['message']['content']
    print(f'   Response: {content[:200]}')
    usage = data.get('usage', {})
    prompt_tokens = usage.get('prompt_tokens', 0)
    completion_tokens = usage.get('completion_tokens', 0)
    tps = completion_tokens / elapsed if elapsed > 0 else 0
    print(f\"   Tokens: {prompt_tokens} prompt, {completion_tokens} completion\")
    print(f\"   Time: {elapsed:.2f}s | Speed: {tps:.1f} tok/s\")
elif 'error' in data:
    print(f\"   Error: {data['error'].get('message', data['error'])}\")
else:
    print(f\"   Unexpected: {data}\")
" 2>/dev/null
echo

# Test 5: Tool calling test
echo "5. Tool Calling Test..."
START_TIME=$(python3 -c "import time; print(time.time())")
RESPONSE=$(curl -s "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [
            {\"role\": \"system\", \"content\": \"You are a helpful assistant with access to tools.\"},
            {\"role\": \"user\", \"content\": \"What is the weather in San Francisco? Use the get_weather tool.\"}
        ],
        \"tools\": [
            {
                \"type\": \"function\",
                \"function\": {
                    \"name\": \"get_weather\",
                    \"description\": \"Get the current weather for a location\",
                    \"parameters\": {
                        \"type\": \"object\",
                        \"properties\": {
                            \"location\": {\"type\": \"string\", \"description\": \"City name\"}
                        },
                        \"required\": [\"location\"]
                    }
                }
            }
        ],
        \"tool_choice\": \"auto\",
        \"max_tokens\": 200
    }")
END_TIME=$(python3 -c "import time; print(time.time())")
echo "$RESPONSE" | python3 -c "
import sys, json
start = $START_TIME
end = $END_TIME
elapsed = end - start
data = json.load(sys.stdin)
if 'choices' in data:
    msg = data['choices'][0]['message']
    if msg.get('tool_calls'):
        print('   ✓ Tool call detected!')
        for tc in msg['tool_calls']:
            func = tc.get('function', {})
            print(f\"   Tool: {func.get('name')}({func.get('arguments')})\")
    elif msg.get('content'):
        print(f\"   Response: {msg['content'][:200]}\")
    usage = data.get('usage', {})
    prompt_tokens = usage.get('prompt_tokens', 0)
    completion_tokens = usage.get('completion_tokens', 0)
    tps = completion_tokens / elapsed if elapsed > 0 else 0
    print(f\"   Tokens: {prompt_tokens} prompt, {completion_tokens} completion\")
    print(f\"   Time: {elapsed:.2f}s | Speed: {tps:.1f} tok/s\")
else:
    print(f\"   Error: {data.get('error', data)}\")
" 2>/dev/null
echo

# Test 6: Throughput benchmark
echo "6. Throughput Benchmark (5 requests, 50 tokens each)..."
echo "   Running..."
total_tokens=0
total_time=0
for i in {1..5}; do
    START_TIME=$(python3 -c "import time; print(time.time())")
    RESPONSE=$(curl -s "$VLLM_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL_NAME\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 50.\"}],
            \"max_tokens\": 50
        }")
    END_TIME=$(python3 -c "import time; print(time.time())")

    # Extract tokens and calculate
    RESULT=$(echo "$RESPONSE" | python3 -c "
import sys, json
start = $START_TIME
end = $END_TIME
elapsed = end - start
data = json.load(sys.stdin)
if 'choices' in data:
    usage = data.get('usage', {})
    completion_tokens = usage.get('completion_tokens', 0)
    tps = completion_tokens / elapsed if elapsed > 0 else 0
    print(f'{completion_tokens},{elapsed:.3f},{tps:.1f}')
else:
    print('0,0,0')
" 2>/dev/null)

    TOKENS=$(echo "$RESULT" | cut -d',' -f1)
    ELAPSED=$(echo "$RESULT" | cut -d',' -f2)
    TPS=$(echo "$RESULT" | cut -d',' -f3)

    echo "   Request $i: ${TOKENS} tokens in ${ELAPSED}s = ${TPS} tok/s"
done
echo

echo "============================================"
echo "All tests complete!"
echo "============================================"
