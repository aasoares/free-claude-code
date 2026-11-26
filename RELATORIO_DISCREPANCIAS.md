# Relatório de Discrepâncias — Stack FCC NVIDIA Proxy

**Data:** 2026-11-25  
**Escopo:** comparação entre `README.md`, `config.yaml`, inicializador `INICIAR_STACK_UNIFICADO.bat` e portas efetivamente ouvidas (`netstat -ano`) + validação de endpoints de saúde (`curl`).  
**Idioma:** português brasileiro (conforme política operacional).

---

## 1. Fontes consultadas

| Fonte | Caminho | O que declara |
|-------|---------|---------------|
| Documentação | `C:\FCC\allinone\README.md` (v1.2.0, 2026-11-22) | portas, aliases (27), registry (89 modelos), arquitetura, scripts |
| Configuração | `C:\FCC\allinone\config.yaml` | porta 8089 (proxy), 8082 (admin_ui), 9090 (metrics), 32 aliases, ollama 11434 |
| Inicializador | `C:\FCC\allinone\INICIAR_STACK_UNIFICADO.bat` | orquestração: Ollama 11434 → NVIDIA Proxy 8089 → Hybrid Proxy 3456 → Monitoring 9090/3000/3100/9093 |
| Estado efetivo | `netstat -ano` + `curl` endpoints | portas ouvidas, PIDs, status de saúde real |

---

## 2. Tabela comparativa: declarado vs efetivo

| Serviço | Porta README.md | Porta config.yaml | Porta .bat | Porta efetiva (netstat) | Endpoint de saúde | Status efetivo |
|---------|-----------------|-------------------|------------|-------------------------|-------------------|----------------|
| Ollama (Vulkan) | 11434 | 11434 (base_url) | 11434 | 11434 (127.0.0.1, PID 30320) | `/api/tags` | ✅ Saudável (modelos listados) |
| NVIDIA Proxy | **18088** | **8089** | **8089** | **8089** (0.0.0.0, PID 6784) | `/health` | ✅ `healthy`, 4/4 providers |
| Hybrid Proxy | **8082** | — (não declarado) | **3456** | **3456** (127.0.0.1, PID 29280) | `/health` | ✅ `ok`, v1.2.0, upstream 8089 |
| Admin UI / FCC | 8082 | 8082 (`admin_ui.port`) | 8082 | 8082 (0.0.0.0, PID 3884) | `/health` | ✅ `healthy` |
| Métricas (config) | 9090 | 9090 (`metrics.port`) | — | 9090 (0.0.0.0/::1/127.0.0.1, PIDs 22024/19068) | — | ⚠️ ocupado por containers Docker |
| Prometheus | — | — | 9090 | 9090 | `/-/healthy` | ✅ Prometheus Server is Healthy |
| Grafana | — | — | 3000 | 3000 | `/api/health` | ✅ `ok`, v11.3.0 |
| Loki | — | — | 3100 | 3100 | `/ready` | ✅ `ready` |
| Alertmanager | — | — | 9093 | 9093 | `/-/healthy` | ✅ `OK` |

**Portas órfãs (ouvidas, não declaradas em nenhuma fonte):**  
- `8083` (PID 27644)  
- `8084` (PID 26308) — existe `C:\FCC\allinone\run_server_8084.py` no disco, usado em testes anteriores.

---

## 3. Discrepâncias encontradas

### D1 — Porta do NVIDIA Proxy divergente (alta)
- README.md declara **18088**; `config.yaml` e o `.bat` usam **8089**; o efetivo é **8089**.
- Impacto: qualquer consulta ao README leva o usuário a procurar o serviço na porta errada. O diagrama de arquitetura (`Hybrid Proxy :8082 → NVIDIA Proxy :18088`) não corresponde ao real (`:3456 → :8089`).

### D2 — Porta do Hybrid Proxy divergente (alta)
- README.md declara **8082**; o `.bat` sobe o Hybrid Proxy em **3456**; efetivamente **3456** está ouvido e saudável.
- A porta **8082** está ouvida (PID 3884) mas corresponde ao Admin UI / FCC (`admin_ui.port: 8082` no `config.yaml`), não ao Hybrid Proxy.

### D3 — Fluxo de arquitetura desatualizado (média)
- README: Claude Code → `:8082` (Hybrid) → `:18088` (NVIDIA Proxy).
- Real: Claude Code → `:3456` (Hybrid) → `:8089` (NVIDIA Proxy), com `ANTHROPIC_BASE_URL=http://127.0.0.1:3456`.

### D4 — Conflito de porta 9090 entre métricas e Prometheus (RESOLVIDA)
- `config.yaml` alterado: `metrics.port` de `9090` → **9091**.
- O Prometheus do Monitoring Stack permanece em 9090 sem conflito.
- O endpoint `/metrics` do NVIDIA Proxy fica acessível em 9091.

### D5 — Contagem de aliases desatualizada (média)
- README.md declara **27 aliases**.
- `config.yaml` declara **32 aliases** (inclui `nemotron-ultra`, `gemini-35-pro`, `qwen2.5-coder`, `deepseek-coder:6.7b`, `qwen-light`, `qwen-micro`, `tinyllama`, `gpt-*`, etc.).

### D6 — Contagem do model registry desatualizada (média)
- README.md declara **89 modelos** no registry / `data/model_registry.json`.
- Efetivo: `data/model_registry.json` contém **177 entradas** (auto-discovery de 30 min acrescentou modelos além do snapshot do README).

### D7 — Scripts de inicialização não correspondem (baixa)
- README lista `init_stack.bat` e `start_all.bat`.
- O inicializador efetivo consolidado é `C:\FCC\allinone\INICIAR_STACK_UNIFICADO.bat` (781 linhas, com subrotinas `:PORTA_SAUDAVEL`, `:PORTA_OCUPADA_PERGUNTAR_ENCERRAR`, `:CHECK_ONE_PORT`), não mencionado no README.

### D8 — Endpoints de saúde não documentados (baixa)
- README (seção Testing) usa `/health` genérico para `18088` e `8082`.
- O `.bat` consolidado usa endpoints específicos por serviço: Ollama `/api/tags`, Prometheus `/-/healthy`, Grafana `/api/health`, Loki `/ready`, Alertmanager `/-/healthy` — corretos e validados, mas ausentes da documentação.

### D9 — Porta do Hybrid Proxy e monitoring ausentes do config.yaml (RESOLVIDA)
- `config.yaml` agora declara: `hybrid_proxy.port: 3456`, `grafana.port: 3000`, `loki.port: 3100`, `alertmanager.port: 9093`.
- Todas as portas do stack estão documentadas no `config.yaml` como única fonte da verdade.

### D10 — Porta 8082 identificada: Admin UI do free-claude-code (resolvida)
- `8082` (PID 3884) corresponde ao Admin UI do **free-claude-code (free server)**, conforme confirmação do usuário. Responde `/health` com `{"status":"healthy"}`. Discrepância resolvida: não há incerteza sobre o processo nesta porta.

---

## 4. Portas órfãs — pendência de investigação

| Porta | PID | Declarado em? | Hipótese |
|-------|-----|---------------|----------|
| 8083 | 27644 | Nenhuma fonte | Pode ser resquício de testes anteriores em outra porta |
| 8084 | 26308 | Nenhuma fonte | `run_server_8084.py` existe no disco (instância de teste do NVIDIA Proxy) |

Recomenda-se confirmar se esses processos ainda são necessários; caso não sejam, encerrá-los para evitar confusão em futuros health checks do inicializador.

---

## 5. Resumo de status

- **Inicializador `.bat`:** funcional, validado em execução real. Todos os serviços sobem e permanecem; nenhum processo nas 8089/8082 é encerrado sem autorização do usuário; health checks usam endpoints específicos por serviço.
- **Serviços efetivos:** 8 de 8 saudáveis (Ollama 11434, NVIDIA Proxy 8089, Hybrid 3456, Admin 8082, Prometheus 9090, Grafana 3000, Loki 3100, Alertmanager 9093).
- **Documentação (`README.md`):** desatualizada em relação à configuração e ao estado efetivo (portas 18088→8089, 8082→3456, aliases 27→32, registry 89→177, scripts antigos, endpoints de saúde).

---

## 6. Recomendações

1. Atualizar `README.md`: corrigir a tabela de portas (NVIDIA Proxy 8089, Hybrid Proxy 3456), o diagrama de arquitetura, as contagens de aliases (32) e registry (177), os nomes dos scripts (`INICIAR_STACK_UNIFICADO.bat`) e os endpoints de saúde por serviço.
2. Resolver o conflito da porta 9090: alterar `metrics.port` em `config.yaml` (ex: 9091) ou a porta do Prometheus no `docker-compose.monitoring.yml`, para que o endpoint `/metrics` do NVIDIA Proxy fique acessível.
3. Investigar e liberar as portas órfãs 8083 e 8084, se não forem mais usadas.
4. Declarar no `config.yaml` as portas do Hybrid Proxy (3456) e do monitoring (3000/3100/9093) para manter a configuração única fonte da verdade.
5. Manter o comportamento do `.bat` de não encerrar processos sem autorização do usuário (já validado).

---

**Evidências coletadas:** `netstat -ano` (portas e PIDs), `curl` nos 8 endpoints de saúde (todos com resposta HTTP 200 e corpo esperado), contagem programática de `model_registry.json` (177 entradas) e leitura direta de `config.yaml` (32 aliases).

**Conformidade:** relatório redigido em português brasileiro; nenhuma alteração feita na autenticação NVIDIA Proxy (`ANTHROPIC_AUTH_TOKEN` preservada); nenhum recurso exclusivo do Claude.ai utilizado.
