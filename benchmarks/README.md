# Node Performance Benchmark Suite

Comprehensive benchmarks for testing Network, Disk I/O, Memory, and GPU performance.

## Quick Start

```bash
# Install dependencies (run once on each node)
./setup.sh

# Run all benchmarks (except network)
./benchmark-all.sh

# Run all benchmarks including network to remote node
./benchmark-all.sh -r 10.15.105.107

# Quick mode (shorter tests)
./benchmark-all.sh -r 10.15.105.107 --quick
```

## Network Testing

For network benchmarks between nodes:

1. **On Node 2** (or the remote node), start the iperf3 server:
   ```bash
   iperf3 -s
   ```

2. **On Node 1**, run the benchmark:
   ```bash
   ./benchmark-all.sh -r <node2-ip>
   ```

## Individual Benchmarks

Run specific benchmarks independently:

```bash
# Network only
./benchmark-network.sh -r <remote-ip>

# Disk only
./benchmark-disk.sh

# Memory only
./benchmark-memory.sh

# GPU only
./benchmark-gpu.sh
```

## Options

| Option | Description |
|--------|-------------|
| `-r, --remote <host>` | Remote host for network tests |
| `-q, --quick` | Quick mode (shorter tests) |
| `--no-network` | Skip network benchmarks |
| `--no-disk` | Skip disk benchmarks |
| `--no-memory` | Skip memory benchmarks |
| `--no-gpu` | Skip GPU benchmarks |

## What's Tested

### Network
- Ping latency (min/avg/max)
- TCP bandwidth (single & multi-stream)
- UDP jitter & packet loss
- Download bandwidth (reverse test)
- MTU & jumbo frame support

### Disk I/O
- Sequential read/write (dd)
- Random 4K read/write IOPS (fio)
- Mixed random R/W (70/30)
- Direct device read (hdparm)

### Memory
- Sequential read/write bandwidth
- Random read/write bandwidth
- STREAM-like benchmark (COPY, SCALE, ADD, TRIAD)
- Memory latency
- NUMA topology

### GPU/VRAM
- VRAM copy bandwidth
- Host ↔ Device transfer (pinned memory)
- GPU ↔ GPU transfer (P2P)
- FP32/FP16/BF16 compute (TFLOPS)
- GPU topology

## Output

Reports are saved to `./reports/` with timestamp:
```
reports/hostname_benchmark_20240107_123456.txt
```

## Dependencies

Installed automatically by `setup.sh`:
- `iperf3` - Network bandwidth
- `fio` - Disk I/O
- `sysbench` - Memory bandwidth
- `hdparm` - Direct disk read
- `numactl` - NUMA info
- `numpy` - Python numerical
- `torch` - GPU benchmarks (optional)

## Expected Results (NVIDIA L40)

| Metric | Expected Range |
|--------|----------------|
| VRAM Bandwidth | 800-900 GB/s |
| Host → Device | 12-13 GB/s (PCIe 4.0 x16) |
| FP32 GEMM | 90-100 TFLOPS |
| FP16 GEMM | 180-200 TFLOPS |
| BF16 GEMM | 180-200 TFLOPS |
