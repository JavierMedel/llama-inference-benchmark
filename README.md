# Local LLM Inference Benchmark Dashboard

A sleek local dashboard for benchmarking `llama.cpp` models with live GPU telemetry, prompt workflows, and structured benchmark history.

Built for Windows, designed for fast local model evaluation, and optimized for comparing throughput, latency, power draw, and speculative decoding behavior without leaving the browser.

## Why this project

This dashboard helps you answer practical questions quickly:

- Which model is fastest on my hardware?
- How does draft / MTP decoding affect throughput?
- What is the real latency to first token?
- How much power and VRAM is being used during generation?
- Which prompts and settings produce the most stable results?

Instead of juggling multiple terminals and JSON logs, the project gives you a single local control panel for server startup, prompt execution, live metrics, and saved benchmark comparisons.

---

## Highlights

- Discover and select local `llama.cpp` builds
- Scan recursively for GGUF models and draft / MTP variants
- Start, monitor, and stop the local inference server from the browser
- Stream model output with live token throughput updates
- View real-time GPU telemetry: power, utilization, temperature, clocks, VRAM, and p-state
- Save reusable prompt templates and reload them instantly
- Keep benchmark history in `benchmark-history.json`
- Filter, sort, and inspect saved benchmark results in the history table
- Export the saved history as JSON when needed
- Zero frontend framework, zero package install, zero build pipeline

---

## Quick start

From the project root:

```powershell
cd "C:\Users\alien51\Desktop\llama-inference-benchmark"
.\dashboard.ps1
```

Or with custom directories:

```powershell
.\dashboard.ps1 -BuildsDir "C:\Users\alien51\Documents\Llama-Server" -ModelsDir "C:\AI\Models"
```

Open the dashboard here:

```text
http://localhost:8090/
```

If port 8090 is already in use, run another instance on another port:

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

## Typical folder layout

### Builds folder

Each child folder should contain a `llama-server.exe` binary.

```text
C:\Users\alien51\Documents\Llama-Server\
  ├─ llama-b10586-bin-win-cuda-13.3-x64\llama-server.exe
  └─ llama-b10662-bin-win-cuda-13.3-x64\llama-server.exe
```

### Models folder

The dashboard scans recursively for GGUF files and recognizes draft / MTP models in directories named `MTP` or `draft`.

```text
C:\AI\Models\
  └─ Qwen3.8-27B\
       ├─ Qwen3.8-27B-UD-Q5_K_XL.gguf
       └─ MTP\
            └─ mtp-Qwen3.8-27B-Q4_0.gguf
```

---

## How to use the dashboard

1. Point the dashboard at your builds folder and click Scan.
2. Point it at your models folder and click Scan.
3. Select the `llama.cpp` build and model.
4. Optionally choose a draft or MTP model to compare speculative decoding setups.
5. Configure runtime settings:
   - context size
   - GPU layers
   - spec type
   - spec draft n-max
   - reasoning effort
   - host and port
   - extra args
6. Click Start Server.
7. Enter a prompt and set max tokens / temperature.
8. Click Run Prompt to stream the output and watch the live throughput metric update.
9. Review the generated output and saved benchmark history.

The interface also includes:

- a live server status indicator
- startup progress feedback
- prompt template save/load support
- history filtering and sorting
- JSON export for saved benchmark data

---

## Saved prompt templates

The dashboard includes a Save Template and Load Template flow.

- Templates are stored in `prompt-templates.json` at the project root.
- You can save repeated prompts and re-use them later from the dropdown.
- This is ideal for code-review prompts, summarization tasks, and structured-response benchmarks.

---

## Benchmark history

Every completed benchmark request is appended to `benchmark-history.json` in the project root.

Each entry stores:

- build and model identity
- optional draft / MTP model
- context size and GPU layers
- spec type and n-max settings
- reasoning effort
- throughput and elapsed time
- time-to-first-token metrics
- acceptance percentage when available
- measured power draw, temperature, and VRAM usage

If repeat runs are enabled, the dashboard records a grouped benchmark summary and preserves the individual run values underneath it for comparison.

You can:

- refresh history from the UI
- clear all saved runs
- download the JSON file
- sort by column
- filter by build, model, reasoning level, context, spec, n-max, and run count

---

## Live telemetry

The dashboard polls `nvidia-smi` once per second to update the live card statistics.

The GPU name is detected with:

```powershell
nvidia-smi --query-gpu=name --format=csv,noheader
```

The full telemetry query used by the poller is:

```powershell
nvidia-smi --query-gpu=timestamp,name,pstate,power.draw,temperature.gpu,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits
```

If `nvidia-smi` is missing, the dashboard still works and the GPU metrics simply fall back to empty values instead of crashing.

---

## HTTP API

The dashboard exposes a compact JSON API for automation and scripting.

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

## Architecture

`dashboard.ps1` uses PowerShell runspaces and a synchronized shared state hashtable so the UI stays responsive while long-running tasks execute in the background.

| Component | Role |
|---|---|
| GPU poller | Reads `nvidia-smi` telemetry and updates dashboard state |
| HTTP server | Serves the HTML interface and JSON endpoints |
| Generation worker | Streams completions from llama-server and stores results |

The browser polls `/api/state` and re-renders the dashboard without a frontend framework or a separate build step.

---

## Batch benchmark support

The project also includes a batch benchmark script for repeatable benchmarking against a running server.

```powershell
.\benchmark.ps
```

That script sends a fixed prompt multiple times and prints averages, per-run results, and summary metrics.

---

## Notes

- This project is intentionally lightweight and local-first.
- It is designed around PowerShell, `llama-server`, and `nvidia-smi` on Windows.
- The app is built with plain HTML and JavaScript, so there is no dependency install or frontend compilation needed.

---

## Project snapshot

This project is best used when you want a fast evaluation loop for local inference:

- benchmark a model under the exact conditions you care about
- compare draft / MTP strategies quickly
- keep a record of your best-performing runs
- iterate on prompts and runtime settings without leaving the dashboard
