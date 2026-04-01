# vLLM + Ray Distributed Cluster

Docker Compose setup for running vLLM with Ray across multiple nodes with monitoring and a chat UI.

## Architecture

```
+-----------------------------------------+     +---------------------------+
|          Head Node (VM1)                |     |     Worker Node (VM2)     |
|                                         |     |                           |
|  +-------------+  +-----------------+   |     |  +---------------------+  |
|  |  Ray Head   |  |   Open WebUI    |   |     |  |    Ray Worker       |  |
|  |  Port 6379  |  |   Port 3000     |   |     |  |  Joins Head:6379   |  |
|  |  Dashboard  |  +-----------------+   |     |  +---------------------+  |
|  |  Port 8265  |                        |     |      GPU 0    GPU 1      |
|  +-------------+  +-----------------+   |     +---------------------------+
|      GPU 0        |   Prometheus    |   |
|      GPU 1        |   Port 9090    |   |
|                    +-----------------+   |
|  +-------------+  +-----------------+   |
|  | vLLM Server |  |    Grafana      |   |
|  |  Port 8000  |  |   Port 4000    |   |
|  | (exec in    |  +-----------------+   |
|  |  ray-head)  |                        |
|  +-------------+                        |
+-----------------------------------------+
```

- **Tensor Parallelism (TP=2)**: Splits model layers across 2 GPUs on each node
- **Pipeline Parallelism (PP=2)**: Splits model stages across 2 nodes
- **Total GPUs**: 4 (2 per node x 2 nodes)

## Prerequisites

- Docker with NVIDIA Container Toolkit on both nodes
- 2+ GPUs per node
- Network connectivity between nodes on port 6379
- Hugging Face token for gated models

## Quick Start

### 1. Configure Environment

```bash
cp .env.example .env
nano .env  # Set HF_TOKEN, IPs, and model settings
```

### 2. Start Head Node (VM1)

```bash
./manage.sh up
```

### 3. Start Worker Node (VM2)

Copy `Dockerfile`, `docker-compose-worker.yml`, and `.env` to the worker node, then:

```bash
docker compose -f docker-compose-worker.yml up -d --build
```

### 4. Load a Model

```bash
./manage.sh serve Qwen/Qwen2.5-7B-Instruct
```

## Management Script

The `manage.sh` script provides all cluster operations:

```
./manage.sh up                        Start cluster + services
./manage.sh down                      Stop everything
./manage.sh serve <model> [tp] [pp]   Load a model
./manage.sh stop                      Unload model (cluster stays running)
./manage.sh status                    Show cluster status
./manage.sh logs [lines]              Show vLLM logs
./manage.sh logs-follow               Follow logs live
./manage.sh models                    List recommended models
```

### Examples

```bash
# Small model (single node)
./manage.sh serve Qwen/Qwen2.5-7B-Instruct

# Large model (multi-node)
./manage.sh serve meta-llama/Llama-3.1-70B-Instruct

# FP8 quantized (recommended for 70B)
./manage.sh serve neuralmagic/Meta-Llama-3.1-70B-Instruct-FP8
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HEAD_NODE_IP` | `10.50.100.100` | Head node IP address |
| `WORKER_NODE_IP` | `10.50.100.101` | Worker node IP address |
| `NETWORK_INTERFACE` | `ens33` | Network interface for NCCL/GLOO |
| `MODEL_NAME` | `Qwen/Qwen2.5-7B-Instruct` | Default model to serve |
| `TENSOR_PARALLEL_SIZE` | `2` | GPUs per node for tensor parallelism |
| `PIPELINE_PARALLEL_SIZE` | `2` | Nodes for pipeline parallelism |
| `MAX_MODEL_LEN` | `4096` | Maximum sequence length |
| `GPU_MEMORY_UTILIZATION` | `0.9` | GPU memory fraction to use |
| `HF_TOKEN` | | Hugging Face API token |
| `VLLM_PORT` | `8000` | vLLM API port |
| `WEBUI_PORT` | `3000` | Open WebUI port |
| `PROMETHEUS_PORT` | `9090` | Prometheus port |
| `GRAFANA_PORT` | `4000` | Grafana port |

## Services

| Service | URL | Description |
|---------|-----|-------------|
| vLLM API | `http://<head-ip>:8000/v1` | OpenAI-compatible API |
| Open WebUI | `http://<head-ip>:3000` | Chat interface |
| Ray Dashboard | `http://<head-ip>:8265` | Ray cluster monitoring |
| Grafana | `http://<head-ip>:4000` | Metrics dashboards (admin/vllm-admin) |
| Prometheus | `http://<head-ip>:9090` | Metrics storage |

## Project Structure

```
.
├── Dockerfile                    # vLLM + Ray image
├── docker-compose-head.yml       # Head node services
├── docker-compose-worker.yml     # Worker node service
├── manage.sh                     # Cluster management script
├── copy-dashboards.sh            # Ray Grafana dashboard provisioner
├── .env.example                  # Environment variable template
├── prometheus/
│   └── prometheus.yml            # Prometheus scrape config
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasource.yml    # Prometheus datasource
│       └── dashboards/
│           └── dashboard-provider.yml  # Dashboard auto-discovery
└── benchmarks/                   # GPU/network/disk benchmark scripts
```

## Troubleshooting

### Worker not connecting
1. Check connectivity: `ping <head-ip>` from worker
2. Verify port 6379 is open: `nc -zv <head-ip> 6379`
3. Check `NETWORK_INTERFACE` matches your setup (`ip a` to find it)

### Model won't load
- Check logs: `./manage.sh logs`
- Verify enough GPUs: `./manage.sh status`
- Try a smaller model first to test the cluster

### Version mismatch
Both nodes must use the same Docker image. Rebuild on both:
```bash
docker compose -f docker-compose-head.yml build
docker compose -f docker-compose-worker.yml build
```

## License

MIT
