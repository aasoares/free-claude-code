# Release FCC NVIDIA Proxy Stack — v1.3.0

**Data:** 2026-11-25  
**Status:** Pronto para release  
**Ambiente:** Windows 11 Pro 26300, NVIDIA Proxy (ANTHROPIC_AUTH_TOKEN preservado)

---

## 1. Resumo do release

Consolidação do inicializador unificado `INICIAR_STACK_UNIFICADO.bat` e adequação de toda a documentação e configuração à realidade dos processos e portas ouvintes efetivas no ambiente do usuário.

Este release corrige divergências entre o `README.md`, o `config.yaml` e o estado efetivo observado via `netstat -ano` + `curl` nos endpoints de saúde.

---

## 2. Mudanças desta versão

### 2.1 README.md — adequado à realidade efetiva

| Item | Antes (desatualizado) | Depois (release v1.3.0) |
|------|----------------------|-------------------------|
| Porta NVIDIA Proxy | 18088 | **8089** |
| Porta Hybrid Proxy | 8082 | **3456** |
| Fluxo de arquitetura | `:8082 → :18088` | `:3456 → :8089` |
| Porta métricas NVIDIA Proxy | 9090 | **9091** |
| Contagem de aliases | 27 | **32** |
| Contagem model registry | 89 | **177** |
| Script de inicialização | `init_stack.bat` / `start_all.bat` | `INICIAR_STACK_UNIFICADO.bat` |
| Endpoints de saúde | `/health` genérico | Específicos por serviço |

### 2.2 config.yaml — portas declaradas e conflito resolvido

| Seção | Valor |
|-------|-------|
| `admin_ui.port` | 8082 (inalterado) |
| `metrics.port` | **9091** (era 9090 — conflito com Prometheus) |
| `hybrid_proxy.port` | **3456** (novo) |
| `grafana.port` | **3000** (novo) |
| `loki.port` | **3100** (novo) |
| `alertmanager.port` | **9093** (novo) |
| `model_aliases` | 32 entradas |
| `fallback_chains` | 13 chains |
| `tier_routing` | 4 tiers (fable → opus → sonnet → haiku) |

### 2.3 INICIAR_STACK_UNIFICADO.bat — já validado (sem alterações de código neste release)

O inicializador já estava consolidado e funcional:
- Verifica saúde antes de iniciar (não recria processos desnecessários)
- Pergunta ao usuário antes de encerrar processo em porta ocupada e não saudável
- Não encerra processos nas portas 8089 e 8082 sem autorização
- Usa endpoints de saúde específicos por serviço (`/api_tags`, `/health`, `/-/healthy`, `/api/health`, `/ready`)

---

## 3. Portas efetivas ouvintes (validadas com netstat + curl)

| Serviço | Porta | PID | Endpoint saúde | Status |
|---------|-------|-----|----------------|--------|
| Ollama (Vulkan) | 11434 | 30320 | `/api/tags` | ✅ Saudável |
| NVIDIA Proxy | 8089 | 6784 | `/health` | ✅ healthy (4/4 providers) |
| Hybrid Proxy | 3456 | 29280 | `/health` | ✅ ok (v1.2.0) |
| Admin UI / free-claude-code | 8082 | 3884 | `/health` | ✅ healthy |
| Prometheus | 9090 | 22024/19068 | `/-/healthy` | ✅ Saudável |
| Grafana | 3000 | 19068 | `/api/health` | ✅ ok |
| Loki | 3100 | 19068 | `/ready` | ✅ ready |
| Alertmanager | 9093 | 19068 | `/-/healthy` | ✅ OK |

---

## 4. Discrepâncias resolvidas neste release

| ID | Discrepância | Severidade | Status |
|----|--------------|------------|--------|
| D1 | NVIDIA Proxy: README dizia 18088, real é 8089 | Alta | ✅ Corrigido no README |
| D2 | Hybrid Proxy: README dizia 8082, real é 3456 | Alta | ✅ Corrigido no README |
| D3 | Fluxo de arquitetura desatualizado | Média | ✅ Corrigido no README |
| D4 | Conflito porta 9090 (métricas vs Prometheus) | Alta | ✅ Resolvido (metrics.port → 9091) |
| D5 | Contagem de aliases desatualizada (27) | Média | ✅ Corrigido (32) |
| D6 | Contagem registry desatualizada (89) | Média | ✅ Corrigido (177) |
| D7 | Scripts de inicialização desatualizados | Baixa | ✅ Corrigido (INICIAR_STACK_UNIFICADO.bat) |
| D8 | Endpoints de saúde não documentados | Baixa | ✅ Documentados no README |
| D9 | Portas Hybrid/monitoring ausentes do config.yaml | Baixa | ✅ Adicionadas ao config.yaml |
| D10 | Porta 8082 não identificada | Média | ✅ Identificada: Admin UI free-claude-code (PID 3884) |

---

## 5. Pendências pós-release (não bloqueantes)

| Item | Descrição |
|------|-----------|
| Portas órfãs | 8083 (PID 27644) e 8084 (PID 26308) não declaradas em nenhuma fonte — investigar se ainda são necessárias |
| Porta 8082 | Confirmar que o PID 3884 é realmente o Admin UI do free-claude-code (identificado pelo usuário) |

---

## 6. Arquivos do release

| Arquivo | Caminho | Função |
|---------|---------|--------|
| Inicializador | `C:\FCC\allinone\INICIAR_STACK_UNIFICADO.bat` | Orquestração do stack (781 linhas) |
| Configuração | `C:\FCC\allinone\config.yaml` | Providers, aliases, tiers, fallbacks, métricas, portas |
| Documentação | `C:\FCC\allinone\README.md` | Guia completo atualizado à v1.3.0 |
| Relatório de discrepâncias | `C:\FCC\allinone\RELATORIO_DISCREPANCIAS.md` | Análise detalhada D1–D10 |
| Entrypoint Windows-safe | `C:\FCC\allinone\run_server.py` | Inicia NVIDIA Proxy sem double-bind |
| Memória da sessão | `C:\Users\aasoa\.claude\projects\C--WINDOWS-system32\memory\MEMORY.md` | Indexado com referência ao relatório |

---

## 7. Conformidade

- Redigido em português brasileiro.
- Autenticação NVIDIA Proxy (`ANTHROPIC_AUTH_TOKEN`) preservada integralmente.
- Nenhum recurso exclusivo do Claude.ai utilizado.
- Nenhum segredo/credencial gravado em texto simples.
- Validação sintática do `config.yaml` executada com sucesso.

---

**Versão:** 1.3.0  
**Data:** 2026-11-25  
**Status:** ✅ Release consolidado

