/* vLLM Cluster Dashboard — Frontend Logic */

let statusWs = null;
let logWs = null;
let currentModel = null;
let servingProfile = null;

// ── Status WebSocket ────────────────────────────────────────────

function connectStatusWs() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    statusWs = new WebSocket(`${proto}//${location.host}/ws/status`);

    statusWs.onmessage = (event) => {
        const data = JSON.parse(event.data);
        updateStatus(data);
    };

    statusWs.onclose = () => {
        setTimeout(connectStatusWs, 3000);
    };

    statusWs.onerror = () => statusWs.close();
}

function updateStatus(data) {
    const badge = document.getElementById('cluster-badge');
    const ray = data.ray;

    // Cluster badge
    if (ray.online) {
        badge.className = 'badge badge-online';
        badge.textContent = 'Online';
    } else {
        badge.className = 'badge badge-offline';
        badge.textContent = 'Offline';
    }

    // Ray stats
    document.getElementById('ray-nodes').textContent = ray.nodes;
    document.getElementById('ray-gpus').textContent = ray.gpus;
    document.getElementById('ray-cpus').textContent = ray.cpus;

    // Model info
    const modelName = document.getElementById('model-name');
    const btnStop = document.getElementById('btn-stop');
    const model = data.model;

    if (model.serving) {
        currentModel = model.model;
        modelName.textContent = model.model;
        modelName.className = 'model-name active';
        btnStop.style.display = 'inline-flex';
        badge.className = 'badge badge-online';
        badge.textContent = 'Serving';
    } else {
        if (currentModel === null && isLoading()) {
            modelName.textContent = 'Loading...';
            modelName.className = 'model-name inactive';
            badge.className = 'badge badge-loading';
            badge.textContent = 'Loading';
        } else if (currentModel !== null) {
            // Model was just stopped
            currentModel = null;
            modelName.textContent = 'No model loaded';
            modelName.className = 'model-name inactive';
        } else {
            modelName.textContent = 'No model loaded';
            modelName.className = 'model-name inactive';
        }
        btnStop.style.display = 'none';
    }

    // GPU cards
    updateGpuCards(data.gpus);

    // Update profile cards active state
    updateProfileActive(model.model);
}

function isLoading() {
    return servingProfile !== null;
}

// ── GPU Cards ───────────────────────────────────────────────────

function updateGpuCards(gpus) {
    const container = document.getElementById('gpu-cards');
    if (!gpus || gpus.length === 0) {
        container.innerHTML = '';
        return;
    }

    // Only rebuild if GPU count changed
    if (container.children.length !== gpus.length) {
        container.innerHTML = gpus.map(gpu => `
            <div class="gpu-card" id="gpu-${gpu.index}">
                <div class="gpu-card-header">
                    <span class="gpu-name">GPU ${gpu.index}: ${gpu.name}</span>
                    <span class="gpu-temp" id="gpu-temp-${gpu.index}">${gpu.temp}°C</span>
                </div>
                <div class="gpu-bar-container">
                    <div class="gpu-bar" id="gpu-bar-mem-${gpu.index}"></div>
                </div>
                <div class="gpu-stats">
                    <span id="gpu-mem-${gpu.index}">VRAM: ${gpu.mem_used}/${gpu.mem_total} MB</span>
                    <span id="gpu-util-${gpu.index}">Util: ${gpu.util}%</span>
                </div>
            </div>
        `).join('');
    }

    // Update values
    gpus.forEach(gpu => {
        const pct = Math.round((gpu.mem_used / gpu.mem_total) * 100);
        const bar = document.getElementById(`gpu-bar-mem-${gpu.index}`);
        if (bar) {
            bar.style.width = `${pct}%`;
            bar.className = `gpu-bar ${pct > 85 ? 'high' : pct > 50 ? 'medium' : 'low'}`;
        }

        const mem = document.getElementById(`gpu-mem-${gpu.index}`);
        if (mem) mem.textContent = `VRAM: ${gpu.mem_used}/${gpu.mem_total} MB`;

        const util = document.getElementById(`gpu-util-${gpu.index}`);
        if (util) util.textContent = `Util: ${gpu.util}%`;

        const temp = document.getElementById(`gpu-temp-${gpu.index}`);
        if (temp) temp.textContent = `${gpu.temp}°C`;
    });
}

// ── Model Profiles ──────────────────────────────────────────────

async function loadProfiles() {
    try {
        const resp = await fetch('/api/models');
        const data = await resp.json();
        renderProfiles(data.models);
    } catch (e) {
        document.getElementById('model-profiles').innerHTML =
            '<p class="muted">Failed to load profiles</p>';
    }
}

function renderProfiles(models) {
    const container = document.getElementById('model-profiles');

    if (!models || models.length === 0) {
        container.innerHTML = '<p class="muted">No model profiles found in models/</p>';
        return;
    }

    container.innerHTML = `<div class="profile-grid">${models.map(m => {
        const extra = m.EXTRA_ARGS || '';
        const isFp8 = extra.includes('fp8');
        const tp = m.TENSOR_PARALLEL || '?';
        const pp = m.PIPELINE_PARALLEL || '?';
        const maxLen = m.MAX_MODEL_LEN || '?';

        return `
            <div class="profile-card" id="profile-${m.name}" data-profile="${m.name}">
                <div class="profile-info">
                    <div class="profile-name">${m.name}</div>
                    <div class="profile-desc">${m.description}</div>
                    <div class="profile-details">${m.details}</div>
                    <div class="profile-tags">
                        <span class="tag tag-tp">TP=${tp} PP=${pp}</span>
                        ${isFp8 ? '<span class="tag tag-fp8">FP8</span>' : ''}
                        <span class="tag">ctx ${formatCtx(maxLen)}</span>
                    </div>
                </div>
                <button class="btn btn-serve btn-primary" onclick="serveModel('${m.name}')">
                    Serve
                </button>
            </div>`;
    }).join('')}</div>`;
}

function formatCtx(len) {
    const n = parseInt(len);
    if (n >= 1024) return `${Math.round(n / 1024)}K`;
    return len;
}

function updateProfileActive(modelId) {
    document.querySelectorAll('.profile-card').forEach(card => {
        card.classList.remove('active');
    });

    if (servingProfile && modelId) {
        const card = document.getElementById(`profile-${servingProfile}`);
        if (card) card.classList.add('active');
    }
}

// ── Actions ─────────────────────────────────────────────────────

async function serveModel(profileName) {
    if (!confirm(`Serve model profile "${profileName}"?\n\nThis will stop any currently running model.`)) {
        return;
    }

    // Disable all serve buttons
    document.querySelectorAll('.btn-serve').forEach(btn => {
        btn.disabled = true;
        btn.textContent = 'Wait...';
    });

    servingProfile = profileName;
    currentModel = null;

    // Update UI immediately
    const modelName = document.getElementById('model-name');
    modelName.textContent = `Loading ${profileName}...`;
    modelName.className = 'model-name inactive';

    const badge = document.getElementById('cluster-badge');
    badge.className = 'badge badge-loading';
    badge.textContent = 'Loading';

    try {
        const resp = await fetch(`/api/serve/${profileName}`, { method: 'POST' });
        const data = await resp.json();

        if (data.error) {
            alert(`Error: ${data.error}`);
            servingProfile = null;
        }
    } catch (e) {
        alert(`Failed to start model: ${e.message}`);
        servingProfile = null;
    }

    // Re-enable buttons after a short delay
    setTimeout(() => {
        document.querySelectorAll('.btn-serve').forEach(btn => {
            btn.disabled = false;
            btn.textContent = 'Serve';
        });
    }, 3000);

    // Reconnect log WebSocket to get fresh logs
    if (logWs) logWs.close();
    setTimeout(connectLogWs, 2000);
}

async function stopModel() {
    if (!confirm('Stop the currently running model?')) return;

    document.getElementById('btn-stop').disabled = true;
    servingProfile = null;

    try {
        await fetch('/api/stop', { method: 'POST' });
        currentModel = null;
        document.getElementById('model-name').textContent = 'Stopping...';
    } catch (e) {
        alert(`Failed to stop model: ${e.message}`);
    }

    setTimeout(() => {
        document.getElementById('btn-stop').disabled = false;
    }, 3000);
}

// ── Log WebSocket ───────────────────────────────────────────────

function connectLogWs() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    logWs = new WebSocket(`${proto}//${location.host}/ws/logs`);

    logWs.onmessage = (event) => {
        appendLog(event.data);
    };

    logWs.onclose = () => {
        setTimeout(connectLogWs, 3000);
    };

    logWs.onerror = () => logWs.close();
}

function appendLog(line) {
    const output = document.getElementById('log-output');
    const container = document.getElementById('log-container');

    const span = document.createElement('span');
    span.textContent = line + '\n';
    span.className = classifyLogLine(line);
    output.appendChild(span);

    // Limit lines
    while (output.children.length > 1000) {
        output.removeChild(output.firstChild);
    }

    // Auto-scroll
    if (document.getElementById('autoscroll').checked) {
        container.scrollTop = container.scrollHeight;
    }
}

function classifyLogLine(line) {
    const lower = line.toLowerCase();
    if (/error|exception|traceback|failed|fatal|oom|cuda out of memory/.test(lower)) return 'log-error';
    if (/warning|warn/.test(lower)) return 'log-warn';
    if (/downloading|fetching|\.safetensors|\.bin|%\|/.test(lower)) return 'log-download';
    if (/loading|loaded|initializ|warming|profiling|weight|memory/.test(lower)) return 'log-loading';
    if (/started server|uvicorn running|application startup complete|serving/.test(lower)) return 'log-ready';
    if (/info/.test(lower)) return 'log-info';
    return '';
}

function clearLogs() {
    document.getElementById('log-output').innerHTML = '';
}

// ── Init ────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
    loadProfiles();
    connectStatusWs();
    connectLogWs();
});
