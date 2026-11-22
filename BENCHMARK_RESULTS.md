# FCC Proxy Chain - Benchmark Results

**Data**: 2026-11-22  
**Configuração**: Hybrid Proxy (porta 3456, Anthropic Messages) → NVIDIA Proxy (porta 10089, OpenAI Chat Completions) → Upstreams (NVIDIA NIM, Google Gemini, Ollama Local, Custom Providers)

---

## Resumo Executivo

A arquitetura de dois proxies está **funcionando end-to-end** com 211 modelos expostos (88 reais + 32 aliases + 7 custom + 84 duplicatas de registro). O VRAM Scheduler para GTX 1060 6GB está operacional com concorrência tiered (heavy=1, light=2, micro=4).

---

## Latência por Modelo (média de 3 runs)

| Proxy | Modelo | Alias | Média | Mín | Máx | Provedor |
|-------|--------|-------|-------|-----|-----|----------|
| **NVIDIA Direct** | ollama/qwen2.5-coder:7b-gpu90 | sonnet/qwen | **2.65s** | 0.12s | 7.72s | Ollama GPU |
| **NVIDIA Direct** | ollama/qwen3:8b-gpu90 | qwen3 | **2.88s** | 0.13s | 8.38s | Ollama GPU (reasoning) |
| **NVIDIA Direct** | ollama/deepseek-coder:6.7b-gpu90 | deepseek | **2.49s** | 0.11s | 7.25s | Ollama GPU |
| **NVIDIA Direct** | nvidia_nim/bigcode/starcoder2-15b | starcoder2 | **30.20s** | 22.70s | 40.34s | NVIDIA NIM |
| **NVIDIA Direct** | nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b | nemotron/fable | **32.82s** | 27.27s | 41.82s | NVIDIA NIM |
| **NVIDIA Direct** | gemini/gemini-3.1-flash-lite | haiku/gemini-flash-lite | **5.92s** | 4.93s | 6.49s | Google Gemini |
| **Hybrid (Anthropic)** | sonnet → qwen2.5-coder:7b-gpu90 | sonnet | **2.67s** | 0.12s | 7.39s | Ollama GPU |
| **Hybrid (Anthropic)** | qwen → qwen2.5-coder:7b-gpu90 | qwen | **0.43s** | 0.27s | 0.51s | Ollama GPU (cached) |
| **Hybrid (Anthropic)** | qwen3 → qwen3:8b-gpu90 | qwen3 | **3.14s** | 0.13s | 8.79s | Ollama GPU (reasoning) |
| **Hybrid (Anthropic)** | deepseek → deepseek-coder:6.7b-gpu90 | deepseek | **2.69s** | 0.12s | 7.44s | Ollama GPU |
| **Hybrid (Anthropic)** | nemotron → nemotron-3-ultra | nemotron | **40.84s** | 33.05s | 50.42s | NVIDIA NIM |
| **Hybrid (Anthropic)** | starcoder2 → bigcode/starcoder2-15b | starcoder2 | **39.74s** | 23.30s | 62.48s | NVIDIA NIM |
| **Hybrid (Anthropic)** | kimi → custom/nim-direct | kimi | **41.27s** | 30.51s | 48.69s | Custom NIM Direct |

---

## Análise de Desempenho

### Ollama Local (GTX 1060 6GB via Vulkan)
- **Primeira request (cold load)**: ~7-8s (carregamento do modelo na VRAM)
- **Requests subsequentes (warm)**: ~0.12-0.5s
- **VRAM Scheduler**: Gerencia offload LRU automático entre modelos heavy (7B-8B = ~4-5GB cada)
- **Concorrência testada**: 3 modelos heavy simultâneos → scheduler fez offload/load sequencial com sucesso

### NVIDIA NIM (Cloud)
- **Latência consistente**: 27-42s (dependência de rede/API externa)
- **Modelos grandes**: Nemotron 3 Ultra (550B), Nemotron 3.5 Super VL (120B)
- **Via custom/nim-direct**: Latência similar (~40s), mas roteamento direto

### Google Gemini (Cloud)
- **Flash Lite**: ~5-6s consistente
- **Pro/Flash**: Alguns modelos com quota excedida (503)
- **Descoberta dinâmica**: 49 modelos Gemini descobertos automaticamente

### Custom Providers (free-claude-server style)
- **nim-direct**: 7 modelos NIM roteados direto para integrate.api.nvidia.com
- **test-local**: 1 modelo Ollama local via custom provider
- **Funcionando**: Kimi K3.1 Pro, Nemotron 3 Ultra, Gemma 3 12B, etc.

---

## VRAM Scheduler Status (GTX 1060 6GB = ~5.5GB usable)

### Perfis Configurados (config.yaml → ollama_instances[0].per_model_config)

| Modelo | Tier | VRAM | Max Loaded | num_gpu | Concurrency |
|--------|------|------|------------|---------|-------------|
| qwen2.5-coder:7b | heavy | 4200MB | 1 | 999 | 1 |
| qwen3:8b-gpu90 | heavy | 4800MB | 1 | 32 | 1 |
| deepseek-coder:6.7b | heavy | 4000MB | 1 | 99 | 1 |
| qwen2.5-coder:1.5b | light | 1000MB | 2 | 999 | 2 |
| qwen2.5:0.5b | light | 400MB | 2 | 999 | 2 |
| tinyllama:1.1b | light | 700MB | 2 | 999 | 2 |

### Comportamento Observado
- **Safety margin**: 500MB reservado
- **VRAM total tracked**: 5500MB
- **LRU offload**: Automático quando VRAM insuficiente
- **Warmup**: `num_predict=1` via `/api/generate` antes de requests reais
- **Keep-alive**: 5min (configurável via `keep_alive` no config)
- **Endpoint**: `GET /vram/status` no Hybrid Proxy

---

## Funcionalidades Validadas

✅ **Model Aliases** (32 aliases no config.yaml): sonnet, qwen, qwen3, deepseek, nemotron, fable, opus, haiku, starcoder2, kimi, etc.  
✅ **Custom Providers** (API estilo free-claude-server): 7 providers nim-direct + 1 test-local  
✅ **VRAM Scheduler** (tiered concurrency para GTX 1060 6GB)  
✅ **Fallback Chains** (config.yaml → fallback_chains)  
✅ **Tier Routing** (fable → opus → sonnet → haiku)  
✅ **Thinking/Reasoning Support** (qwen3 thinking parameter, reasoning_content no response)  
✅ **SSE Streaming** (OpenAI SSE → Anthropic SSE translation)  
✅ **Health Checks** (VERIFY_MODEL_LIVENESS opcional)  
✅ **Anthropic Messages Format** (compatível com Claude Code /model)  
✅ **Rate Limiting Adaptativo** (429 backoff, RPM dinâmico)  
✅ **Retry com Jitter** (exponential backoff + Retry-After parsing)  

---

## Problemas Conhecidos / Pendências

| Item | Status | Detalhes |
|------|--------|----------|
| Porta 10089 "already in use" | ⚠️ Workaround | TIME_WAIT no Windows; aguardar ou `taskkill` antes de restart |
| Gemini quota (503) | 🔴 Parcial | Alguns modelos Pro/Flash com quota excedida na API key gratuita |
| VRAM cleanup task | 🟡 Pendente | Periodic idle model unload não implementado (keep-alive apenas) |
| Hybrid Proxy .env path | 🟡 Hardcoded | `C:\FCC\ClaudeProxy\.env` fixo; deveria usar `C:\FCC\allinone\.env` |
| NVIDIA Proxy log level | 🟡 Hardcoded | Variável `VRAM_LOG_LEVEL` existe mas logger do NVIDIA Proxy não usa |

---

## Recomendação de Configuração Ótima

Para **menor latência** (desenvolvimento local):
```
sonnet / qwen / deepseek → Ollama GPU (0.1-0.5s warm)
qwen3 → Ollama GPU com reasoning (0.13s sem thinking, ~7-8s com thinking)
haiku / gemini-flash-lite → Gemini Flash Lite (~5-6s)
```

Para **máxima capacidade** (tarefas complexas):
```
nemotron / fable → NVIDIA NIM Nemotron 3 Ultra (~30-40s)
opus → Gemini 2.5 Pro (quota permitting)
kimi → Custom NIM Direct (~40s)
starcoder2 → NVIDIA NIM StarCoder2 15B (~30s)
```

---

## Arquivos de Evidência

- `benchmark_results.json` - Dados brutos de latência
- `config.yaml` - Configuração completa (88 modelos, 32 aliases, VRAM profiles)
- `hybrid.py` - Hybrid Proxy com VRAM Scheduler integrado
- `vram_scheduler.py` - Scheduler VRAM-aware (singleton, tiered concurrency)
- `nvidiaproxy.py` - NVIDIA Proxy com Gemini/Ollama/thinking fixes

---

**Conclusão**: A arquitetura **Hybrid → NVIDIA Proxy → Upstreams** está operacional e validada. O VRAM Scheduler permite rodar modelos 7B-8B na GTX 1060 6GB com offload automático. Para produção, recomenda-se monitorar quota Gemini e implementar cleanup task periódica do VRAM Scheduler.