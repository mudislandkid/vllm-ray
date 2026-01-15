# Model Options for 2x L40 GPUs (96GB Total)

## Quick Comparison

| Model | Vision? | Size | VRAM | Best For |
|-------|---------|------|------|----------|
| **Qwen3-VL-30B-FP8** ⭐ | ✅ YES | 31B | ~25GB | Screenshot analysis, visual coding |
| **GLM-4.6V-Flash** | ✅ YES | 9B | ~10GB | Fast vision tasks, UI replication |
| **MiniMax-M2.1-AWQ** | ❌ NO | 39B | ~92GB | Coding, agentic workflows, tool use |
| **DeepSeek-R1-32B-FP8** | ❌ NO | 32B | ~35GB | Complex reasoning, math |
| **Kimi-K2-Thinking** | ❌ NO | 1T | 210GB+ | ❌ Too large |

## Recommended Choice by Use Case

### 🖼️ Screenshot Analysis & Visual Tasks
**→ Use: Qwen3-VL-30B-FP8** (Recommended)
- Best balance of vision capabilities and performance
- Generate HTML/CSS from screenshots
- OCR with 32 languages
- 256K context window

```bash
cp .env.qwen3vl .env  # Use Qwen3-VL config as template
docker-compose -f docker-compose.single.qwen3vl.yml up -d
```

### 💻 Pure Coding & Agentic Workflows (No Vision)
**→ Use: MiniMax-M2.1-AWQ**
- State-of-the-art coding performance
- Multi-language programming
- Tool calling and agentic workflows
- 196K context window

```bash
cp .env.minimax-m2 .env
docker-compose -f docker-compose.single.minimax-m2.yml up -d
```

### 🧠 Complex Reasoning & Math (No Vision)
**→ Use: DeepSeek-R1-32B-FP8**
- O1-style reasoning
- Strong math/science capabilities
- 128K context window

```bash
cp .env  # Already configured for DeepSeek-R1
docker-compose -f docker-compose.single.deepseek-r1.yml up -d
```

### ⚡ Lightweight Vision Tasks
**→ Use: GLM-4.6V-Flash**
- Smallest vision model (9B)
- Fast inference
- Good for basic screenshot analysis

```bash
cp .env.glm4v .env
docker-compose -f docker-compose.single.glm4v.yml up -d
```

## All Configuration Files

```
docker-compose.single.qwen3vl.yml      # Qwen3-VL-30B (vision)
docker-compose.single.minimax-m2.yml   # MiniMax-M2.1 (coding)
docker-compose.single.deepseek-r1.yml  # DeepSeek-R1 (reasoning)
docker-compose.single.glm4v.yml        # GLM-4.6V-Flash (vision)

.env                    # Main config (currently Qwen3-VL)
.env.qwen3vl           # Qwen3-VL template
.env.minimax-m2        # MiniMax-M2 template
.env.glm4v             # GLM-4.6V template
```

## Deployment Steps

1. **Choose your model** based on use case above
2. **Copy the appropriate .env file**:
   ```bash
   cp .env.minimax-m2 .env  # Example
   ```
3. **Edit .env** and set your HuggingFace token
4. **Find your network interface**:
   ```bash
   ip addr show
   ```
5. **Update NETWORK_INTERFACE** in .env
6. **Deploy**:
   ```bash
   docker-compose -f docker-compose.single.minimax-m2.yml up -d
   ```
7. **Monitor logs**:
   ```bash
   docker logs -f vllm-server
   ```

## API Usage

All models expose OpenAI-compatible API on port 8000:

```python
import openai

client = openai.OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="dummy"
)

# For vision models (Qwen3-VL, GLM-4.6V)
response = client.chat.completions.create(
    model="qwen3-vl-30b",  # or "glm-4.6v-flash"
    messages=[
        {
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": {"url": "file:///workspace/images/screenshot.png"}
                },
                {"type": "text", "text": "Analyze this screenshot"}
            ]
        }
    ]
)

# For text-only models (MiniMax-M2, DeepSeek-R1)
response = client.chat.completions.create(
    model="minimax-m2.1",  # or "deepseek-r1"
    messages=[
        {"role": "user", "content": "Write a Python function to calculate Fibonacci"}
    ]
)
```

## Performance Expectations

### Qwen3-VL-30B-FP8 (Vision)
- Single request: 50-80 tokens/sec
- Batched: 400-600 tokens/sec
- Image processing: ~2-5 sec per image

### MiniMax-M2.1-AWQ (Coding)
- Single request: 100+ tokens/sec
- Batched: 800-1,200 tokens/sec
- Context: Up to 196K tokens

### DeepSeek-R1-32B-FP8 (Reasoning)
- Single request: 60-90 tokens/sec
- Batched: 500-700 tokens/sec
- Context: Up to 128K tokens

### GLM-4.6V-Flash (Vision)
- Single request: 80-120 tokens/sec
- Batched: 600-900 tokens/sec
- Image processing: ~1-3 sec per image

## Switching Models

To switch models:

1. **Stop current container**:
   ```bash
   docker-compose -f docker-compose.single.<current>.yml down
   ```

2. **Update .env**:
   ```bash
   cp .env.<new-model> .env
   nano .env  # Verify settings
   ```

3. **Start new model**:
   ```bash
   docker-compose -f docker-compose.single.<new>.yml up -d
   ```

## Troubleshooting

### Out of Memory (OOM)
- Reduce `MAX_MODEL_LEN` in .env
- Reduce `MAX_NUM_SEQS` in .env
- Lower `GPU_MEMORY_UTILIZATION` to 0.85

### Slow Loading
- Check network connection to HuggingFace
- Set `HF_HUB_ENABLE_HF_TRANSFER=1` for faster downloads
- Models are large (20-90GB), first download takes time

### Model Not Found
- Verify `HF_TOKEN` is set correctly in .env
- Check HuggingFace token has read permissions
- Some models require accepting license agreement on HuggingFace

## Context Length vs VRAM Trade-off

Higher context lengths require more VRAM for KV cache:

| Model | 32K Context | 64K Context | 128K Context | 196K Context |
|-------|-------------|-------------|--------------|--------------|
| Qwen3-VL-30B | ✅ Safe | ✅ OK | ⚠️ Tight | ❌ OOM |
| MiniMax-M2.1 | ✅ Safe | ✅ Safe | ✅ OK | ⚠️ Single seq |
| DeepSeek-R1-32B | ✅ Safe | ✅ OK | ⚠️ Tight | N/A |
| GLM-4.6V-Flash | ✅ Safe | ✅ Safe | ✅ Safe | N/A |

Adjust `MAX_MODEL_LEN` and `MAX_NUM_SEQS` in .env based on your needs.
