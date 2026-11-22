# Release Checklist — FCC Proxy v1.2.0

## Pre-Release Verification

### Core Services
- [x] **NVIDIA Proxy** starts on port 18088
- [x] **Hybrid Proxy** starts on port 8082
- [x] **Ollama Vulkan** starts on port 11434
- [x] All three services start via `init_stack.bat` option [1]

### Health Checks
- [x] `GET /health` returns 200 on both proxies
- [x] `GET /v1/models` returns expected model counts
  - NVIDIA Proxy: ~33 NIM models
  - Hybrid Proxy: 31+ models (with aliases)
- [x] `/diagnostics` endpoint works on Hybrid Proxy
- [x] `/v1/messages/count_tokens` works

### Model System
- [x] **27 model aliases** defined in `config.yaml`
- [x] **4-tier routing** (fable/opus/sonnet/haiku) configured
- [x] **11 fallback chains** with cross-provider failover
- [x] **Loop detection** (max 3 hops) implemented
- [x] **Custom provider CRUD** API functional
- [x] **Kimi via nim-direct** works (custom provider)

### Model Discovery
- [x] `scripts/discover_models_uv.py` discovers 89 models
- [x] Updates `config.yaml` (aliases, tiers, fallbacks)
- [x] Updates `data/model_registry.json` (89 entries)
- [x] `keep_latest` deduplication works
- [x] Active health checks on discovery
- [x] 30-min auto-refresh interval configured

### Claude Code Integration
- [x] `/model` command shows 6+ options (was 2)
- [x] `availableModels: []` in settings.json
- [x] `modelPicker.options` populated
- [x] Model persistence works ("saved as default for new sessions")
- [x] Tested: Kimi K3.1 Pro, Gemma 4 31B IT, Fable 5.2 switching

### Ollama Vulkan (GTX 1060 6GB)
- [x] `OLLAMA_VULKAN=1`, `CUDA_VISIBLE_DEVICES=-1`
- [x] `num_gpu: 999` for qwen2.5-coder:7b (100% GPU)
- [x] `num_gpu: 32` for qwen3:8b (90% GPU + reasoning)
- [x] `num_gpu: 99` for deepseek-coder:6.7b (100% GPU + batch 128)
- [x] Flash Attention enabled
- [x] KV Cache Q8_0

### Configuration
- [x] `.env.example` template complete
- [x] `config.yaml` fully documented
- [x] No hardcoded secrets
- [x] Admin token support
- [x] Rate limiting configured
- [x] Circuit breaker configured

### Startup Scripts
- [x] `init_stack.bat` — Interactive menu (7 options)
- [x] `start_all.bat` — Non-interactive startup
- [x] Proper port checking & killing
- [x] Health verification after start
- [x] Claude Code auto-configuration

### Terminal Theming (Bonus)
- [x] 10 Oh My Posh themes in `~/.config/omp-themes/`
- [x] 10 Starship themes in `~/.config/starship-themes/`
- [x] `setup-terminal.ps1` auto-installs & configures

### Documentation
- [x] `README.md` — Complete architecture, usage, config
- [x] `RELEASE_NOTES.md` — v1.2.0 features, migration, roadmap
- [x] `VERSION` file (1.2.0)
- [x] Inline code comments (hybrid.py, discover_models_uv.py)

### Security
- [x] No hardcoded API keys
- [x] `.env` for secrets (gitignored)
- [x] API key auth on Hybrid Proxy
- [x] Admin token for NVIDIA Proxy
- [x] Circuit breaker prevents cascade
- [x] Rate limiting per provider/key

---

## Post-Release

- [ ] Tag release: `git tag v1.2.0`
- [ ] Push tags: `git push origin v1.2.0`
- [ ] Create GitHub Release with RELEASE_NOTES.md
- [ ] Update any dependent projects

---

**Signed off:** 2026-11-22  
**Status:** ✅ Ready for release