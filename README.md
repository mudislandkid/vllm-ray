# vLLM + Ray Distributed Cluster

Docker Compose setup for running vLLM with Ray across multiple nodes for distributed inference.

## Architecture

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────────┐
│           Node 1 (Head)             │     │          Node 2 (Worker)            │
│                                     │     │                                     │
│  ┌─────────────┐  ┌──────────────┐  │     │  ┌─────────────────────────────┐   │
│  │  Ray Head   │  │ vLLM Server  │  │     │  │        Ray Worker           │   │
│  │  Port 6379  │  │  Port 8000   │  │     │  │  Connects to Head:6379      │   │
│  │  Dashboard  │  │              │  │     │  │                             │   │
│  │  Port 8265  │  │  TP=2, PP=2  │  │     │  │                             │   │
│  └─────────────┘  └──────────────┘  │     │  └─────────────────────────────┘   │
│       GPU 0          GPU 1          │     │       GPU 0          GPU 1         │
└─────────────────────────────────────┘     └─────────────────────────────────────┘
```

- **Tensor Parallelism (TP=2)**: Splits model layers across 2 GPUs on each node
- **Pipeline Parallelism (PP=2)**: Splits model stages across 2 nodes
- **Total GPUs**: 4 (2 per node x 2 nodes)

## Prerequisites

- Docker with NVIDIA Container Toolkit installed on both nodes
- 2 GPUs per node
- Network connectivity between nodes on port 6379
- Hugging Face account with access to gated models (e.g., Llama)

## Deployment Options

### Option A: Pre-built Image (Recommended)

Uses `vllm/vllm-openai:latest` which has Ray + vLLM pre-installed with compatible versions.

**Pros:** Faster deployment, no build step, guaranteed compatible versions
**Cons:** Less customization

### Option B: Custom Dockerfile

Builds from `rayproject/ray:*-gpu` and installs vLLM on top.

**Pros:** Full control over dependencies, can pin specific versions
**Cons:** Longer initial build time, potential dependency conflicts

---

## Quick Start (Option A - Pre-built)

### Node 1 (Head Node)

```bash
# Clone and navigate to node1 directory
cd node1

# Copy and configure environment variables
cp .env.example .env
nano .env  # Set your HF_TOKEN and adjust settings

# Create model cache directory
mkdir -p models data

# Start Ray head first
docker compose up -d ray-head

# Wait for Ray head to be ready
sleep 10

# Start Node 2 worker (see below) before proceeding

# Once Node 2 is connected, start vLLM
docker compose up -d vllm-server

# Watch logs
docker compose logs -f vllm-server
```

### Node 2 (Worker Node)

```bash
# Clone and navigate to node2 directory
cd node2

# Copy and configure environment variables
cp .env.example .env
nano .env  # Set RAY_HEAD_IP to Node 1's IP address

# Create model cache directory
mkdir -p models data

# Start Ray worker
docker compose up -d

# Check connection to head node
docker compose logs -f
```

---

## Quick Start (Option B - Custom Dockerfile)

If you need to customize the environment or pin specific versions.

### Node 1 (Head Node)

```bash
cd node1

# Configure environment
cp .env.example .env
nano .env

# Create directories
mkdir -p models data

# Build and start (uses docker-compose.build.yml)
docker compose -f docker-compose.build.yml build
docker compose -f docker-compose.build.yml up -d ray-head

# Wait for worker nodes to connect, then start vLLM
docker compose -f docker-compose.build.yml up -d vllm-server
docker compose -f docker-compose.build.yml logs -f vllm-server
```

### Node 2 (Worker Node)

```bash
cd node2

# Configure environment
cp .env.example .env
nano .env  # Set RAY_HEAD_IP

# Create directories
mkdir -p models data

# Build and start
docker compose -f docker-compose.build.yml build
docker compose -f docker-compose.build.yml up -d
docker compose -f docker-compose.build.yml logs -f
```

## Verifying the Cluster

### Check Ray cluster status (on Node 1)

```bash
docker exec ray-head ray status
```

Expected output:
```
======== Autoscaler status ========
...
Resources:
  - CPU: 0.0/X used
  - GPU: 0.0/4.0 used  # Should show 4.0 GPUs
  - ...
```

**Important**: Wait until you see `4.0 GPUs` before starting vLLM. If you only see 2 GPUs, Node 2 hasn't connected yet.

### Access Ray Dashboard

Open `http://<node1-ip>:8265` in your browser

### Test vLLM API

```bash
curl http://<node1-ip>:8000/v1/models

curl http://<node1-ip>:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-70B-Instruct",
    "prompt": "Hello, how are you?",
    "max_tokens": 50
  }'
```

## Configuration

### Node 1 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_TOKEN` | (required) | Hugging Face API token |
| `MODEL_NAME` | `meta-llama/Llama-3.1-70B-Instruct` | Model to serve |
| `MODEL_CACHE_DIR` | `./models` | Local model cache path |
| `VLLM_PORT` | `8000` | vLLM API port |
| `MAX_MODEL_LEN` | `4096` | Maximum sequence length |
| `TENSOR_PARALLEL_SIZE` | `2` | GPUs per node for tensor parallelism |
| `PIPELINE_PARALLEL_SIZE` | `2` | Number of nodes for pipeline parallelism |
| `VLLM_STARTUP_DELAY` | `60` | Seconds to wait for workers before starting vLLM |

### Node 2 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_TOKEN` | (required) | Hugging Face API token |
| `RAY_HEAD_IP` | `10.15.105.105` | IP address of Node 1 (Ray head) |
| `MODEL_CACHE_DIR` | `./models` | Local model cache path |

## Troubleshooting

### "Tensor parallel size exceeds available GPUs"

vLLM started before all workers connected. Solution:
```bash
# On Node 1
docker compose stop vllm-server
docker exec ray-head ray status  # Wait for 4 GPUs
docker compose up -d vllm-server
```

### Version mismatch errors

Both nodes must use the same Docker image (`vllm/vllm-openai:latest`). Pull the latest on both:
```bash
docker pull vllm/vllm-openai:latest
```

### "No module named 'vllm'" on workers

Worker node is using wrong image. Ensure Node 2 uses `vllm/vllm-openai:latest`, not `rayproject/ray:latest-gpu`.

### Worker not connecting to head

1. Check network connectivity: `ping <node1-ip>` from Node 2
2. Verify port 6379 is open: `nc -zv <node1-ip> 6379`
3. Check firewall rules on both nodes
4. Verify `RAY_HEAD_IP` in Node 2's `.env` file

### Permission errors with /tmp/ray

This setup intentionally does not mount `/tmp/ray` to avoid permission issues. Ray session data won't persist between restarts.

## Stopping the Cluster

### Node 1
```bash
docker compose down
```

### Node 2
```bash
docker compose down
```

## Scaling

To add more worker nodes:
1. Copy `node2/` directory to the new node
2. Configure `.env` with the correct `RAY_HEAD_IP`
3. Update `PIPELINE_PARALLEL_SIZE` on Node 1 accordingly
4. Restart the cluster

## License

MIT
