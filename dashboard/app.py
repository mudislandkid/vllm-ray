"""vLLM Cluster Dashboard — FastAPI backend for managing models and viewing logs."""

import asyncio
import json
import os
import subprocess
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

app = FastAPI(title="vLLM Cluster Dashboard")

BASE_DIR = Path(__file__).parent
MODELS_DIR = Path(os.environ.get("MODELS_DIR", "/models"))
VLLM_PORT = os.environ.get("VLLM_PORT", "8000")
HEAD_NODE_IP = os.environ.get("HEAD_NODE_IP", "localhost")

app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


def run_cmd(cmd: list[str], timeout: int = 10) -> str:
    """Run a command and return stdout."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        return f"Error: {e}"


def parse_model_profile(path: Path) -> dict:
    """Parse a model .conf file into a dict."""
    profile = {"name": path.stem, "file": path.name}
    comments = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("#"):
            comments.append(line.lstrip("# "))
        elif "=" in line and not line.startswith("#"):
            key, _, val = line.partition("=")
            profile[key.strip()] = val.strip().strip('"')
    profile["description"] = comments[0] if comments else ""
    profile["details"] = comments[1] if len(comments) > 1 else ""
    return profile


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


@app.get("/api/status")
async def get_status():
    """Get cluster status: ray, vllm, gpus."""
    # Ray status
    ray_status = {"online": False, "nodes": 0, "gpus": 0, "cpus": 0}
    ray_check = run_cmd(["docker", "exec", "ray-head", "ray", "status"], timeout=5)
    if "Error" not in ray_check:
        ray_status["online"] = True
        ray_info = run_cmd([
            "docker", "exec", "ray-head", "python3", "-c",
            "import ray; ray.init(address='auto'); "
            "nodes=[n for n in ray.nodes() if n['Alive']]; "
            "gpus=sum(n['Resources'].get('GPU',0) for n in nodes); "
            "cpus=sum(n['Resources'].get('CPU',0) for n in nodes); "
            f"print(f'{{len(nodes)}}|{{int(gpus)}}|{{int(cpus)}}')"
        ], timeout=10)
        if "|" in ray_info:
            parts = ray_info.strip().split("|")
            ray_status["nodes"] = int(parts[0])
            ray_status["gpus"] = int(parts[1])
            ray_status["cpus"] = int(parts[2])

    # vLLM model
    model_info = {"serving": False, "model": None}
    try:
        import urllib.request
        resp = urllib.request.urlopen(
            f"http://{HEAD_NODE_IP}:{VLLM_PORT}/v1/models", timeout=3
        )
        data = json.loads(resp.read())
        models = data.get("data", [])
        if models:
            model_info["serving"] = True
            model_info["model"] = models[0]["id"]
    except Exception:
        pass

    # GPU info
    gpus = []
    gpu_out = run_cmd([
        "docker", "exec", "ray-head", "nvidia-smi",
        "--query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu",
        "--format=csv,noheader,nounits"
    ], timeout=5)
    if "Error" not in gpu_out:
        for line in gpu_out.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 6:
                gpus.append({
                    "index": int(parts[0]),
                    "name": parts[1],
                    "mem_used": int(parts[2]),
                    "mem_total": int(parts[3]),
                    "util": int(parts[4]),
                    "temp": int(parts[5]),
                })

    return {
        "ray": ray_status,
        "model": model_info,
        "gpus": gpus,
        "head_ip": HEAD_NODE_IP,
        "vllm_port": VLLM_PORT,
    }


@app.get("/api/models")
async def get_models():
    """List available model profiles."""
    profiles = []
    if MODELS_DIR.exists():
        for conf in sorted(MODELS_DIR.glob("*.conf")):
            profiles.append(parse_model_profile(conf))
    return {"models": profiles}


@app.post("/api/serve/{profile_name}")
async def serve_model(profile_name: str):
    """Serve a model by profile name."""
    conf_path = MODELS_DIR / f"{profile_name}.conf"
    if not conf_path.exists():
        return {"error": f"Profile '{profile_name}' not found"}

    profile = parse_model_profile(conf_path)

    # Stop current model if running
    run_cmd(["docker", "exec", "ray-head", "pkill", "-f", "vllm serve"], timeout=5)
    await asyncio.sleep(3)
    run_cmd(["docker", "exec", "ray-head", "pkill", "-9", "-f", "vllm serve"], timeout=5)
    await asyncio.sleep(2)

    # Clear log
    run_cmd(["docker", "exec", "ray-head", "bash", "-c", "> /tmp/vllm-serve.log"])

    # Build command
    model_id = profile.get("MODEL_ID", "")
    tp = profile.get("TENSOR_PARALLEL", "2")
    pp = profile.get("PIPELINE_PARALLEL", "1")
    max_len = profile.get("MAX_MODEL_LEN", "4096")
    gpu_util = profile.get("GPU_MEM_UTIL", "0.9")
    extra = profile.get("EXTRA_ARGS", "")

    hf_token = os.environ.get("HF_TOKEN", "")

    cmd = (
        f"HF_TOKEN={hf_token} vllm serve '{model_id}' "
        f"--tensor-parallel-size {tp} "
        f"--pipeline-parallel-size {pp} "
        f"--max-model-len {max_len} "
        f"--gpu-memory-utilization {gpu_util} "
        f"--distributed-executor-backend ray "
        f"--host 0.0.0.0 "
        f"--port {VLLM_PORT} "
        f"{extra} "
        f"2>&1 | tee /tmp/vllm-serve.log"
    )

    run_cmd(["docker", "exec", "-d", "ray-head", "bash", "-c", cmd], timeout=10)

    return {"status": "starting", "model": model_id, "profile": profile_name}


@app.post("/api/stop")
async def stop_model():
    """Stop the currently serving model."""
    run_cmd(["docker", "exec", "ray-head", "pkill", "-f", "vllm serve"], timeout=5)
    await asyncio.sleep(3)
    run_cmd(["docker", "exec", "ray-head", "pkill", "-9", "-f", "vllm serve"], timeout=5)
    return {"status": "stopped"}


@app.websocket("/ws/logs")
async def websocket_logs(websocket: WebSocket):
    """Stream vLLM logs via WebSocket."""
    await websocket.accept()
    process = None
    try:
        process = await asyncio.create_subprocess_exec(
            "docker", "exec", "ray-head", "tail", "-n", "100", "-f", "/tmp/vllm-serve.log",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        while True:
            line = await asyncio.wait_for(process.stdout.readline(), timeout=30)
            if line:
                await websocket.send_text(line.decode("utf-8", errors="replace").rstrip())
            else:
                await asyncio.sleep(0.5)
    except (WebSocketDisconnect, asyncio.TimeoutError, Exception):
        pass
    finally:
        if process:
            try:
                process.kill()
                await process.wait()
            except Exception:
                pass


@app.websocket("/ws/status")
async def websocket_status(websocket: WebSocket):
    """Push status updates every 5 seconds."""
    await websocket.accept()
    try:
        while True:
            status = await asyncio.to_thread(get_status_sync)
            await websocket.send_json(status)
            await asyncio.sleep(5)
    except (WebSocketDisconnect, Exception):
        pass


def get_status_sync() -> dict:
    """Synchronous version of status for use in threads."""
    import urllib.request

    ray_status = {"online": False, "nodes": 0, "gpus": 0, "cpus": 0}
    ray_check = run_cmd(["docker", "exec", "ray-head", "ray", "status"], timeout=5)
    if "Error" not in ray_check:
        ray_status["online"] = True
        ray_info = run_cmd([
            "docker", "exec", "ray-head", "python3", "-c",
            "import ray; ray.init(address='auto'); "
            "nodes=[n for n in ray.nodes() if n['Alive']]; "
            "gpus=sum(n['Resources'].get('GPU',0) for n in nodes); "
            "cpus=sum(n['Resources'].get('CPU',0) for n in nodes); "
            f"print(f'{{len(nodes)}}|{{int(gpus)}}|{{int(cpus)}}')"
        ], timeout=10)
        if "|" in ray_info:
            parts = ray_info.strip().split("|")
            ray_status["nodes"] = int(parts[0])
            ray_status["gpus"] = int(parts[1])
            ray_status["cpus"] = int(parts[2])

    model_info = {"serving": False, "model": None}
    try:
        resp = urllib.request.urlopen(
            f"http://{HEAD_NODE_IP}:{VLLM_PORT}/v1/models", timeout=3
        )
        data = json.loads(resp.read())
        models = data.get("data", [])
        if models:
            model_info["serving"] = True
            model_info["model"] = models[0]["id"]
    except Exception:
        pass

    gpus = []
    gpu_out = run_cmd([
        "docker", "exec", "ray-head", "nvidia-smi",
        "--query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu",
        "--format=csv,noheader,nounits"
    ], timeout=5)
    if "Error" not in gpu_out:
        for line in gpu_out.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 6:
                gpus.append({
                    "index": int(parts[0]),
                    "name": parts[1],
                    "mem_used": int(parts[2]),
                    "mem_total": int(parts[3]),
                    "util": int(parts[4]),
                    "temp": int(parts[5]),
                })

    return {
        "ray": ray_status,
        "model": model_info,
        "gpus": gpus,
        "head_ip": HEAD_NODE_IP,
        "vllm_port": VLLM_PORT,
    }
