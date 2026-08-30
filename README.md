# Local LLM Inference Benchmark Dashboard

A local browser dashboard for running and benchmarking llama.cpp models with live GPU telemetry, prompt templates, and saved benchmark history.

## Features

- Select a llama.cpp build from a discovered builds folder
- Discover GGUF models from a configured models directory
- Choose an optional draft / MTP model for speculative decoding
- Launch, monitor, and stop llama-server directly from the browser
- Auto-detect the installed NVIDIA GPU model name from `nvidia-smi`
- Show live GPU telemetry: power, utilization, VRAM, temperature, clocks, p-state
- Stream generation output in real time and watch tokens/sec update live
- Save benchmark runs to `benchmark-history.json`
- Save and reload prompt templates from `prompt-templates.json`
- Clear history and download saved benchmark history as JSON
- No Node.js, no build step, no package install required

---

## Quick start

From the project root:

```powershell
cd "C:\Users\alien51\Desktop\benchmark"
.\dashboard.ps1
```

Or with custom directories:

```powershell
.\dashboard.ps1 -BuildsDir "C:\Users\alien51\Documents\Llama-Server" -ModelsDir "C:\AI\Models"
```

Then open:

```text
http://localhost:8090/
```

If port 8090 is already in use, run with a different port:

```powershell
.\dashboard.ps1 -Port 8091
```

---

## Supported parameters

| Parameter | Default | Description |
|---|---|---|
| `-BuildsDir` | `%USERPROFILE%\Documents\Llama-Server` | Folder containing one subfolder per llama.cpp build |
| `-ModelsDir` | `C:\AI\Models` | Root folder searched recursively for `.gguf` files |
| `-LlamaHost` | `127.0.0.1` | Host used by llama-server |
| `-LlamaPort` | `8080` | Port used by llama-server |
| `-Port` | `8090` | Port used by the dashboard web UI |

---

## Expected folder layout

### Builds folder

Each child folder should contain a `llama-server.exe` binary.

```text
C:\Users\alien51\Documents\Llama-Server\
  ├─ llama-b10586-bin-win-cuda-13.3-x64\llama-server.exe
  └─ llama-b10662-bin-win-cuda-13.3-x64\llama-server.exe
```

### Models folder

The dashboard scans recursively for GGUF files, and will also recognize draft / MTP files in folders named `MTP` or `draft`.

```text
C:\AI\Models\
  └─ Qwen3.8-27B\
       ├─ Qwen3.8-27B-UD-Q5_K_XL.gguf
       └─ MTP\
            └─ mtp-Qwen3.8-27B-Q4_0.gguf
```

---

## Using the dashboard

1. Set the builds folder and click Scan.
2. Set the models folder and click Scan.
3. Select the llama.cpp build and model.
4. Optionally choose a draft / MTP model.
5. Configure runtime settings:
   - context size
   - GPU layers
   - spec type
   - spec draft n-max
   - reasoning effort
   - host and port
   - extra args
6. Click Start Server.
7. Enter a prompt and choose a max token count and temperature.
8. Click Run Prompt to stream the completion and watch tokens/sec update live.
9. Review the output panel and saved history.

The dashboard also exposes:

- a server status pill and startup progress indicator
- live metadata about generation timing and throughput
- a copy-output button for the current generation output
- prompt template save/load support
- benchmark history refresh, clear, and JSON download

---

## Saved prompt templates

The web UI includes a Save Template and Load Template workflow.

- Templates are stored in `prompt-templates.json` in the project root.
- You can save a named prompt and reload it later from the dropdown.
- This is useful for repeated benchmark prompts like code reviews, summarization, or structured output tests.

---

## Benchmark history

Every completed benchmark request is appended to `benchmark-history.json` in the project root.

Each saved record includes:

- build and model information
- optional draft / MTP model
- context size and GPU layers
- spec type and draft n-max
- reasoning effort
- token throughput and elapsed time
- time-to-first-token
- GPT-style aggregate metrics when available
- GPU name, power draw, temperature, and VRAM usage

If repeat runs are set to more than 1, the row stores a single averaged result for that benchmark run.

You can:

- refresh history from the UI
- clear all saved runs
- download the history file as JSON
- sort the table columns by clicking the headers

---

## Live telemetry behavior

The dashboard polls `nvidia-smi` once per second to read the current card state and updates the UI in real time.

The model name is auto-detected using:

```powershell
nvidia-smi --query-gpu=name --format=csv,noheader
```

The full telemetry query used by the poller is:

```powershell
nvidia-smi --query-gpu=timestamp,name,pstate,power.draw,temperature.gpu,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits
```

If `nvidia-smi` is unavailable or not installed, the app still runs and the GPU values fall back to empty or zero values instead of crashing.

---

## HTTP API

The dashboard exposes a small JSON API that can be used by scripts or tooling.

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/state` | Current GPU, generation, and server state |
| `GET` | `/api/builds?dir=` | Discover llama.cpp builds |
| `GET` | `/api/models?dir=` | Discover `.gguf` models |
| `POST` | `/api/server/start` | Launch llama-server with a config |
| `POST` | `/api/server/stop` | Stop the running server |
| `POST` | `/api/gpu/offload` | Stop GPU-consuming processes |
| `POST` | `/api/generate` | Run a streaming prompt |
| `GET` | `/api/templates` | Get saved prompt templates |
| `POST` | `/api/templates` | Save a prompt template |
| `GET` | `/api/history` | Fetch saved benchmark runs |
| `POST` | `/api/history/clear` | Delete all saved benchmark history |

---

## How it works

`dashboard.ps1` uses PowerShell runspaces and a synchronized shared state hashtable to keep the UI responsive while running the background tasks.

| Component | Role |
|---|---|
| GPU poller | Reads `nvidia-smi` telemetry and updates the dashboard state |
| HTTP server | Serves the HTML UI and JSON API |
| Generation worker | Streams completions from llama-server and persists results to history |

The browser polls `/api/state` and re-renders the dashboard without needing a frontend framework or build pipeline.

---

## Batch benchmark support

The project also includes a batch benchmark script for repeatable benchmarking against a running server.

```powershell
.\benchmark.ps
```

That script sends a fixed prompt multiple times and prints averages, per-run results, and summary metrics.

---

## Notes

- This project is intentionally zero-dependency and designed for local benchmarking.
- It is Windows-focused and built around PowerShell + `llama-server` + `nvidia-smi`.
- The app uses plain static HTML + JavaScript, so there is no framework to install or compile.
