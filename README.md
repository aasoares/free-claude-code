# FCC Proxy — Unified Multi-Provider LLM Proxy Stack

> **Production-ready local proxy** enabling `/model` command in **Claude Code** with 90+ real models from **NVIDIA NIM**, **Google Gemini**, and **Ollama (local/Vulkan)** — with tier routing, fallback chains, model aliases, custom provider registration, and active health checks.

---

## 🎯 Quick Start

```powershell
# 1. Clone/navigate to project
cd C:\FCC\ClaudeProxy

# 2. Configure environment
cp .env.example .env
# Edit .env with your NGC_API_KEY (get from https://ngc.nvidia.com/setup/api-key)

# 3. Start full stack (Ollama Vulkan + NVIDIA Proxy 8089 + Hybrid Proxy 3456)
INICIAR_STACK_UNIFICADO.bat
# Escolha a opção correspondente ao stack completo

# 4. Use /model in Claude Code
# /model qwen        → qwen2.5-coder:7b (100% GPU)
# /model nemotron    → Nemotron 3 Ultra (NIM)
# /model gemini-flash → Gemini 3.8 Flash
# /model kimi-pro    → Kimi K3.1 Pro (direct NIM)
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CLAUDE CODE / FCC SERVER                         │
│                         (Anthropic Messages API)                            │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ HTTP :3456  (Anthropic format)
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    HYBRID PROXY v1.2.0  (Python/FastAPI)                    │
│  • Model aliases (32 short names)                                           │
│  • Tier routing (fable/opus/sonnet/haiku) + fallback chains                 │
│  • Custom provider CRUD API                                                 │
│  • Active health checks / diagnostics                                       │
│  • Token counting (tiktoken)                                                │
│  • Anthropic → OpenAI format translation                                    │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ HTTP :8089 (OpenAI format)
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                   NVIDIA PROXY (FastAPI, port 8089)                        │
│  • Multi-provider: NVIDIA NIM + Google Gemini + Ollama                     │
│  • Auto-discovery + model registry (177 models)                             │
│  • Circuit breaker + rate limiting + metrics                               │
│  • Admin UI :8082                                                          │
└─────────┬───────────────────────┬───────────────────────┬───────────────────┘
          │                       │                       │
          ▼                       ▼                       ▼
   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
   │ NVIDIA NIM  │         │  GEMINI     │         │   OLLAMA    │
   │ (Cloud)     │         │  (Cloud)    │         │  (Local)    │
   │ 33 models   │         │ 15 models   │         │ 3 models    │
   │             │         │             │         │ Vulkan/GPU  │
   │ nemotron-3- │         │ gemini-2.5- │         │ qwen2.5-    │
   │ ultra,      │         │ pro,        │         │ coder:7b,   │
   │ kimi-k3.1,  │         │ gemini-3.8- │         │ qwen3:8b,   │
   │ starcoder2  │         │ flash, etc  │         │ deepseek    │
   └─────────────┘         └─────────────┘         └─────────────┘
```

---

## 🔌 Ports & Endpoints

| Service | Port | Protocol | Key Endpoints |
|---------|------|----------|---------------|
| **Hybrid Proxy** | 3456 | Anthropic Messages | `/v1/messages`, `/v1/models`, `/health`, `/diagnostics` |
| **NVIDIA Proxy** | 8089 | OpenAI Chat Completions | `/v1/chat/completions`, `/v1/models`, `/health`, `/admin/*`, `/metrics` |
| **Ollama** | 11434 | Ollama Native | `/api/tags`, `/api/chat`, `/api/generate` |
| **Admin UI / FCC** | 8082 | Web UI | NVIDIA Proxy admin panel |
| **Prometheus** | 9090 | Prometheus | `/-/healthy` |
| **Grafana** | 3000 | Grafana | `/api/health` |
| **Loki** | 3100 | Loki | `/ready` |
| **Alertmanager** | 9093 | Alertmanager | `/-/healthy` |
| **Metrics (NVIDIA Proxy)** | 9091 | Prometheus | `/metrics` |

---

## 🎭 Model Aliases (32)

| Alias | Resolves To | Provider | Tier |
|-------|-------------|----------|------|
| `fable` | `nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b` | NIM | fable |
| `nemotron` | `nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b` | NIM | fable |
| `opus` | `gemini/gemini-2.5-pro` | Gemini | opus |
| `gemini-pro` | `gemini/gemini-2.5-pro` | Gemini | opus |
| `sonnet` | `ollama/qwen2.5-coder:7b` | Ollama | sonnet |
| `qwen` | `ollama/qwen2.5-coder:7b` | Ollama | sonnet |
| `qwen-coder` | `ollama/qwen2.5-coder:7b` | Ollama | sonnet |
| `qwen3` | `ollama/qwen3:8b` | Ollama | sonnet |
| `deepseek` | `ollama/deepseek-coder:6.7b` | Ollama | sonnet |
| `gemini-flash` | `gemini/gemini-3.8-flash` | Gemini | haiku |
| `gemini-38-flash` | `gemini/gemini-3.8-flash` | Gemini | haiku |
| `starcoder2` | `nvidia_nim/bigcode/starcoder2-15b` | NIM | sonnet |
| `gemma-3-12b` | `nvidia_nim/google/gemma-3-12b-it` | NIM | sonnet |
| `minimax-m3` | `nvidia_nim/minimaxai/minimax-m3.1-flash` | NIM | haiku |
| `glm-53-flash` | `nvidia_nim/z-ai/glm-5.3-flash` | NIM | haiku |
| `haiku` | `gemini/gemini-3.1-flash-lite` | Gemini | haiku |
| `kimi-pro` | `custom/nim-direct/moonshotai/kimi-k3.1-pro` | Custom | fable |
| `kimi` | `custom/nim-direct/moonshotai/kimi-k3.1-pro` | Custom | fable |

> Use in Claude Code: `/model qwen`, `/model nemotron`, `/model kimi-pro`

---

## 🏷️ Tier Routing & Fallback Chains

**4 Tiers:** `fable` → `opus` → `sonnet` → `haiku`

Each tier has:
- **Preferred providers** (try first)
- **Fallback tiers** (cascade on failure)

**Example:** `ollama/qwen2.5-coder:7b` (sonnet) → falls back to `ollama/qwen3:8b` → `ollama/deepseek-coder:6.7b` → `gemini/gemini-3.8-flash` → `nvidia_nim/starcoder2-15b`

Cross-provider failover with **loop detection** (max 3 hops).

---

## 🛠️ Custom Provider Registration

Register any OpenAI-compatible endpoint:

```bash
# Via Hybrid Proxy API
curl -X POST http://127.0.0.1:3456/admin/providers \
  -H "x-api-key: local-proxy" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "my-provider",
    "name": "My Provider",
    "api_base": "https://api.example.com",
    "api_key": "sk-xxx",
    "chat_endpoint": "/v1/chat/completions",
    "models_endpoint": "/v1/models",
    "model_ids": ["model-1", "model-2"]
  }'
```

Models become available as: `custom/my-provider/model-1`

---

## 📊 Model Discovery & Registry

```bash
# Auto-discover from all 3 providers (registry persistido, 177 entradas efetivas)
python scripts/discover_models_uv.py

# Outputs:
# - Updates config.yaml (model_aliases, tier_routing, fallback_chains)
# - Updates data/model_registry.json (177 entries with tier, health, metadata)
```

**Features:**
- Parallel discovery from NIM, Gemini, Ollama
- JSON persistence with `keep_latest` deduplication
- Active health checks on discovery
- 30-min auto-refresh interval

---

## ⚡ Ollama Vulkan Backend (GTX 1060 6GB)

Optimized for **CUDA-unsupported** GTX 1060 6GB via **Vulkan + Flash Attention + KV Cache 8-bit**:

```yaml
# config.yaml per-model config
per_model_config:
  qwen2.5-coder:7b:
    num_gpu: 999              # 100% GPU offload
    flash_attention: true
    kv_cache_quant: Q8_0
    max_loaded_models: 1
  qwen3:8b:
    num_gpu: 32               # 90% GPU (32/36 layers)
    reasoning_effort_default: medium
  deepseek-coder:6.7b:
    num_gpu: 99               # 100% GPU offload
    num_batch: 128
```

---

## 🚀 Startup Scripts

| Script | Description |
|--------|-------------|
| `INICIAR_STACK_UNIFICADO.bat` | Unified initializer: Ollama → NVIDIA Proxy → Hybrid Proxy → Monitoring → free-claude-code. Health checks per service, prompts before killing processes on ports 8089/8082. |
| `init_stack.bat` | Interactive menu: full stack, individual services, configure Claude, verify |
| `start_all.bat` | Non-interactive: starts all 3 services sequentially |

**INICIAR_STACK_UNIFICADO.bat flow:**
1. Ollama Vulkan (porta 11434, `/api/tags`)
2. NVIDIA Proxy (porta 8089, `/health`)
3. Hybrid Proxy (porta 3456, `/health`)
4. Monitoring Stack Docker Compose (Prometheus 9090, Grafana 3000, Loki 3100, Alertmanager 9093)
5. free-claude-code --resume (janela separada)

---

## 🔧 Configuration

### `.env` (Required)
```bash
NGC_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxxxxxx  # From https://ngc.nvidia.com/setup/api-key
ADMIN_TOKEN=your-secure-token               # Optional, for admin API
```

### `config.yaml` (Main config)
- Provider instances (NIM, Gemini, Ollama, OpenAI)
- Model aliases (32)
- Tier routing & fallback chains (13 chains)
- Ollama per-model Vulkan config
- Reasoning effort mapping (Anthropic thinking → OpenAI reasoning_effort)
- NVIDIA Proxy metrics on port 9091 (avoid conflict with Prometheus on 9090)

### `data/model_registry.json` (Auto-generated)
- 177 model entries with metadata, health, tier assignment

### `data/custom_providers.json` (Auto-generated)
- Custom provider registrations

---

## 🧪 Testing

```bash
# Health checks
curl http://127.0.0.1:11434/api/tags
curl http://127.0.0.1:8089/health
curl http://127.0.0.1:3456/health
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:9090/-/healthy
curl http://127.0.0.1:3000/api/health
curl http://127.0.0.1:3100/ready
curl http://127.0.0.1:9093/-/healthy

# Model counts
curl -s http://127.0.0.1:8089/v1/models | python -c "import sys,json; print(len(json.load(sys.stdin)['data']))"
curl -s http://127.0.0.1:3456/v1/models | python -c "import sys,json; print(len(json.load(sys.stdin)['data']))"

# Test model alias
curl -X POST http://127.0.0.1:3456/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: local-proxy" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"qwen","max_tokens":50,"messages":[{"role":"user","content":"Hello"}]}'

# Diagnostics
curl http://127.0.0.1:3456/diagnostics
```

---

## 📁 Project Structure

```
C:\FCC\allinone\
├── INICIAR_STACK_UNIFICADO.bat   # Unified startup initializer
├── run_server.py                 # NVIDIA Proxy Windows-safe entry point
├── config.yaml                   # Main configuration
├── hybrid.py                     # Hybrid Proxy v1.2.0 (main entry)
├── setup-terminal.ps1            # Terminal theming (Oh My Posh + Starship)
├── .env.example                  # Environment template
├── scripts/
│   └── discover_models_uv.py     # Model discovery (uv-based)
├── data/
│   ├── model_registry.json       # 177 models (auto-generated)
│   └── custom_providers.json     # Custom providers (auto-generated)
├── README.md                     # This file
└── RELATORIO_DISCREPANCIAS.md    # Discrepancy report vs README/config/state
```

---

## 🔐 Security

- **No hardcoded secrets** — all via `.env` / environment variables
- **API key authentication** on Hybrid Proxy (`x-api-key: local-proxy`)
- **Admin token** for NVIDIA Proxy admin endpoints
- **Circuit breaker** prevents cascade failures
- **Rate limiting** per provider/key

---

## 📝 Requirements

- **Windows 10/11** (tested on 11 Pro 26300)
- **Python 3.11+** (with `uv` for discovery: `pip install uv`)
- **Ollama** (from https://ollama.com)
- **NVIDIA NGC API Key** (from https://ngc.nvidia.com/setup/api-key)
- **GTX 1060 6GB+** (for Vulkan backend) or CPU fallback
- **Claude Code** (for `/model` command)
- **Windows Terminal** (recommended for themes)

---

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| Port 8089/3456 in use | `INICIAR_STACK_UNIFICADO.bat` prompts before killing; or `netstat -ano \| findstr :8089` |
| `/model` shows only 2 options | Fix `settings.json`: `availableModels: []`, add `modelPicker.options` |
| NIM models not appearing | Check `NGC_API_KEY` in `.env`, verify NVIDIA Proxy health |
| Ollama Vulkan not working | Verify `OLLAMA_VULKAN=1`, `CUDA_VISIBLE_DEVICES=-1`, update drivers |
| Custom provider not routing | Check `data/custom_providers.json`, Hybrid Proxy debug logs |
| NVIDIA Proxy `/metrics` inaccessible | Prometheus occupies 9090; metrics moved to 9091 in `config.yaml` |

---

## 📄 License

MIT License — Free for personal and commercial use.

---

## 🤝 Credits

- **NVIDIA NIM** — Nemotron, Nemotron-Safety, Starcoder2, Gemma, Minimax, GLM
- **Google Gemini** — 2.5 Pro, 3.8 Flash, 3.1 Flash Lite
- **Ollama** — Local Vulkan inference
- **free-claude-code** — FCC Server inspiration
- **Oh My Posh / Starship** — Terminal theming

---

**Version:** 1.2.0  
**Date:** 2026-11-25  
**Status:** Production Ready ✅
