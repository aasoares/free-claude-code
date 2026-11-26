@echo off
chcp 65001 >nul

REM Ativar suporte a VT100/ANSI no Windows 10+
reg add HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1

title INICIADOR UNIFICADO - FCC NVIDIA PROXY STACK (Producao Completa)

REM ==============================================================================
REM INICIADOR UNIFICADO - FCC NVIDIA PROXY STACK
REM ==============================================================================
REM Base estrutural: start_all.bat + INICIAR_STACK_PROFISSIONAL.bat
REM Inicializa: Ollama Vulkan -> NVIDIA Proxy (8089) -> Hybrid Proxy (3456)
REM           -> Monitoring Stack (Docker: Prometheus 9090, Grafana 3000, Loki 3100, Alertmanager 9093)
REM           -> free-claude-code --resume 535c2fa1-6e9a-450b-b67d-2800cfd362ea
REM
REM Verbose: Apresenta arquivo carregado, funcao desempenhada, porta que ouve
REM ==============================================================================

REM ==============================================================================
REM CORES - usar escape real (0x1B) para ANSI
REM ==============================================================================
for /f %%a in ('echo prompt $E ^| cmd') do set ESC=%%a
set RED=%ESC%[0;31m
set GREEN=%ESC%[0;32m
set YELLOW=%ESC%[1;33m
set BLUE=%ESC%[0;34m
set CYAN=%ESC%[0;36m
set MAGENTA=%ESC%[0;35m
set BOLD=%ESC%[1m
set NC=%ESC%[0m

REM ==============================================================================
REM DIRETORIOS E ARQUIVOS
REM ==============================================================================
set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

set CONFIG_FILE=%SCRIPT_DIR%config.yaml
set ENV_FILE=%SCRIPT_DIR%.env
set MONITORING_COMPOSE=%SCRIPT_DIR%docker-compose.monitoring.yml
set NVPROXY_MAIN=%SCRIPT_DIR%nvidia_proxy\main.py
set HYPROXY_MAIN=%SCRIPT_DIR%hybrid.py
set FREE_CLAUDE_DIR=C:\Users\aasoa\free-claude-server
set SESSION_ID=535c2fa1-6e9a-450b-b67d-2800cfd362ea

REM ==============================================================================
REM PORTAS DEFINIDAS
REM ==============================================================================
set NVPROXY_PORT=8089
set HYPROXY_PORT=3456
set OLLAMA_PORT=11434
set FCC_ADMIN_PORT=8082
set PROMETHEUS_PORT=9090
set GRAFANA_PORT=3000
set LOKI_PORT=3100
set ALERTMANAGER_PORT=9093

REM ==============================================================================
REM EXECUCAO PRINCIPAL
REM ==============================================================================
call :SHOW_BANNER
if errorlevel 1 goto :ERROR_EXIT

call :CHECK_PREREQS
if errorlevel 1 goto :ERROR_EXIT

call :CHECK_PORTS
if errorlevel 1 goto :ERROR_EXIT

call :START_OLLAMA
if errorlevel 1 goto :ERROR_EXIT

call :START_NVPROXY
if errorlevel 1 goto :ERROR_EXIT

call :START_HYPROXY
if errorlevel 1 goto :ERROR_EXIT

call :START_MONITORING
if errorlevel 1 goto :ERROR_EXIT

call :FINAL_VALIDATION
if errorlevel 1 goto :ERROR_EXIT

call :START_FREE_CLAUDE
if errorlevel 1 goto :ERROR_EXIT

goto :CLEAN_EXIT

:ERROR_EXIT
echo.
echo %RED%================================================================================%NC%
echo %RED%  ERRO DURANTE INICIALIZACAO%NC%
echo %RED%================================================================================%NC%
echo.
echo Verifique as mensagens acima para identificar o problema.
echo.
pause >nul 2>&1
exit /b 1

:CLEAN_EXIT
echo.
echo %GREEN%================================================================================%NC%
echo %GREEN%  INICIALIZACAO UNIFICADA CONCLUIDA COM SUCESSO%NC%
echo %GREEN%================================================================================%NC%
echo.
echo Stack completa ativa:
echo   [1] Ollama Vulkan           ^> http://localhost:%OLLAMA_PORT%
echo   [2] NVIDIA Proxy (OpenAI)   ^> http://localhost:%NVPROXY_PORT%
echo   [3] Hybrid Proxy (Anthropic)^> http://localhost:%HYPROXY_PORT%
if "%DOCKER_AVAILABLE%"=="true" echo   [4] Monitoring Stack        ^> Prometheus:%PROMETHEUS_PORT% Grafana:%GRAFANA_PORT% Loki:%LOKI_PORT% Alertmanager:%ALERTMANAGER_PORT%
echo   [5] free-claude-code        ^> --resume %SESSION_ID% [janela separada]
echo.
echo Janelas de monitoramento abertas para cada servico.
echo Pressione Ctrl+C nas janelas dos proxies para parar.
echo %GREEN%================================================================================%NC%
echo.
echo Pressione qualquer tecla para fechar esta janela...
pause >nul 2>&1
exit /b 0

goto :EOF

REM ==============================================================================
REM SUBROTINAS
REM ==============================================================================

REM ----------------------------------------------------------
REM Funcoes de Log
REM ----------------------------------------------------------
:LOG_INFO
echo [INFO] %*
goto :EOF

:LOG_SUCCESS
echo [SUCCESS] %*
goto :EOF

:LOG_WARN
echo [WARN] %*
goto :EOF

:LOG_ERROR
echo [ERROR] %*
goto :EOF

:LOG_VERBOSE
echo [VERBOSE] %*
goto :EOF

:LOG_FILE
echo [FILE] Carregado: %~1
echo [FILE]   Funcao: %~2
echo [FILE]   Porta: %~3
goto :EOF


REM ----------------------------------------------------------
REM Health Check Function - usa arquivo temporario sem pipe
REM ----------------------------------------------------------
:CHECK_HEALTH
setlocal
set URL=%1
set PATTERN=%2
set TMPFILE=%TEMP%\healthchk_%RANDOM%.txt
curl -s -m 5 %URL% > "%TMPFILE%" 2>&1
findstr "%PATTERN%" "%TMPFILE%" >nul
set RESULT=%errorlevel%
del "%TMPFILE%" 2>nul
endlocal & exit /b %RESULT%
goto :EOF


REM ----------------------------------------------------------
REM Verifica se a porta esta ativa e saudavel (retorna 0 se sim, 1 se nao)
REM Usa: call :PORTA_SAUDAVEL <porta> <padrao_esperado> [endpoint]
REM   endpoint default: /health
REM ----------------------------------------------------------
:PORTA_SAUDAVEL
setlocal
set PORTA=%1
set PADRAO=%2
set ENDPOINT=%3
if not defined ENDPOINT set ENDPOINT=/health
set URL=http://localhost:%PORTA%%ENDPOINT%
set TMPFILE=%TEMP%\port_healthy_%RANDOM%.txt
curl -s -m 5 %URL% > "%TMPFILE%" 2>&1
findstr "%PADRAO%" "%TMPFILE%" >nul
set RESULT=%errorlevel%
del "%TMPFILE%" 2>nul
endlocal & exit /b %RESULT%
goto :EOF


REM ----------------------------------------------------------
REM Banner Inicial
REM ----------------------------------------------------------
:SHOW_BANNER
cls
echo.
echo %CYAN%================================================================================%NC%
echo %CYAN%  INICIADOR UNIFICADO - FCC NVIDIA PROXY STACK (Producao Completa)%NC%
echo %CYAN%================================================================================%NC%
echo.
echo   Base: start_all.bat + INICIAR_STACK_PROFISSIONAL.bat
echo   Sessao: %SESSION_ID%
echo.
echo   Servicos a iniciar (ordem de dependencia):
echo     1. Ollama Vulkan (GPU GTX 1060)           ^> Porta %OLLAMA_PORT%
echo     2. NVIDIA Proxy (config.yaml)             ^> Porta %NVPROXY_PORT%
echo     3. Hybrid Proxy (hybrid.py)               ^> Porta %HYPROXY_PORT%
echo     4. Monitoring Stack (Docker Compose)      ^> Portas %PROMETHEUS_PORT%,%GRAFANA_PORT%,%LOKI_PORT%,%ALERTMANAGER_PORT%
echo     5. free-claude-code --resume              ^> Sessao %SESSION_ID%
echo %CYAN%================================================================================%NC%
echo.
echo Iniciando automaticamente em 5 segundos...
ping -n 6 127.0.0.1 >nul
goto :EOF


REM ----------------------------------------------------------
REM Verificacao de Pre-requisitos
REM ----------------------------------------------------------
:CHECK_PREREQS
call :LOG_INFO Verificando prerequisitos...

where python >nul 2>&1
if errorlevel 1 (
    call :LOG_ERROR Python nao encontrado no PATH
    echo Instale Python 3.10+ e adicione ao PATH do sistema.
    pause
    exit /b 1
)
call :LOG_VERBOSE Python OK

where curl >nul 2>&1
if errorlevel 1 (
    call :LOG_WARN curl nao encontrado - health checks podem falhar
) else (
    call :LOG_VERBOSE curl OK
)

docker --version >nul 2>&1
if errorlevel 1 (
    call :LOG_WARN Docker nao encontrado - Monitoring Stack nao sera iniciado
    set DOCKER_AVAILABLE=false
) else (
    docker compose version >nul 2>&1
    if not errorlevel 1 (
        set COMPOSE_CMD=docker compose
        set DOCKER_AVAILABLE=true
    ) else (
        docker-compose --version >nul 2>&1
        if not errorlevel 1 (
            set COMPOSE_CMD=docker-compose
            set DOCKER_AVAILABLE=true
        ) else (
            call :LOG_WARN Docker Compose nao encontrado
            set DOCKER_AVAILABLE=false
        )
    )
)

if not exist "%ENV_FILE%" (
    call :LOG_ERROR Arquivo .env nao encontrado: %ENV_FILE%
    pause
    exit /b 1
)
call :LOG_FILE "%ENV_FILE%" "Variaveis de ambiente (API keys, configs)" "N/A"

if not exist "%CONFIG_FILE%" (
    call :LOG_ERROR Arquivo config.yaml nao encontrado: %CONFIG_FILE%
    pause
    exit /b 1
)
call :LOG_FILE "%CONFIG_FILE%" "Configuracao principal NVIDIA Proxy (providers, modelos, tiers, fallbacks)" "%NVPROXY_PORT%"

if not exist "%NVPROXY_MAIN%" (
    call :LOG_ERROR NVIDIA Proxy main nao encontrado: %NVPROXY_MAIN%
    pause
    exit /b 1
)
call :LOG_FILE "%NVPROXY_MAIN%" "Entry point NVIDIA Proxy (FastAPI, OpenAI-compatible, 4 providers)" "%NVPROXY_PORT%"

if not exist "%HYPROXY_MAIN%" (
    call :LOG_ERROR Hybrid Proxy main nao encontrado: %HYPROXY_MAIN%
    pause
    exit /b 1
)
call :LOG_FILE "%HYPROXY_MAIN%" "Entry point Hybrid Proxy (Anthropic Messages API -> NVIDIA Proxy)" "%HYPROXY_PORT%"

call :LOG_SUCCESS Prerequisitos verificados
goto :EOF


REM ----------------------------------------------------------
REM Verificar Portas (NAO matar processos - apenas avisar)
REM ----------------------------------------------------------
:CHECK_PORTS
call :LOG_INFO Verificando disponibilidade das portas...
call :CHECK_ONE_PORT %NVPROXY_PORT%
call :CHECK_ONE_PORT %HYPROXY_PORT%
call :CHECK_ONE_PORT %OLLAMA_PORT%
call :CHECK_ONE_PORT %FCC_ADMIN_PORT%
call :CHECK_ONE_PORT %PROMETHEUS_PORT%
call :CHECK_ONE_PORT %GRAFANA_PORT%
call :CHECK_ONE_PORT %LOKI_PORT%
call :CHECK_ONE_PORT %ALERTMANAGER_PORT%
goto :EOF

:CHECK_ONE_PORT
netstat -ano | findstr /r /c":%1 " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    call :LOG_WARN Porta %1 ja em uso (processo existente sera mantido)
) else (
    call :LOG_VERBOSE Porta %1 livre
)
goto :EOF


REM ----------------------------------------------------------
REM 1. INICIAR OLLAMA VULKAN
REM ----------------------------------------------------------
:START_OLLAMA
call :LOG_INFO === [1/5] Iniciando Ollama Vulkan (GTX 1060 6GB) ===

REM Verifica se a porta ja esta ativa e saudavel
call :PORTA_SAUDAVEL %OLLAMA_PORT% "models" "/api/tags"
if not errorlevel 1 (
    call :LOG_SUCCESS Ollama ja esta ativo e saudavel na porta %OLLAMA_PORT%
    call :LOG_FILE "ollama.exe (processo existente)" "LLM Local com Vulkan/GPU offload" "%OLLAMA_PORT%"
    goto :EOF
)

call :PORTA_OCUPADA_PERGUNTAR_ENCERRAR %OLLAMA_PORT%
if errorlevel 1 (
    call :LOG_ERROR Ollama nao esta saudavel na porta %OLLAMA_PORT% e nao pode ser iniciado (porta ocupada por outro processo).
    exit /b 1
)

set OLLAMA_VULKAN=1
set GGML_VK_VISIBLE_DEVICES=0
set OLLAMA_NUM_GPU=999
set OLLAMA_FLASH_ATTENTION=1
set OLLAMA_KV_CACHE_TYPE=q8_0
set OLLAMA_NUM_PARALLEL=1
set CUDA_VISIBLE_DEVICES=-1
call :LOG_VERBOSE Variaveis Vulkan configuradas - OLLAMA_VULKAN=1, GGML_VK_VISIBLE_DEVICES=0, NUM_GPU=999

set OLLAMA_EXE=ollama
if exist "%SCRIPT_DIR%..\Ollama\ollama.exe" set OLLAMA_EXE="%SCRIPT_DIR%..\Ollama\ollama.exe"
if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" set OLLAMA_EXE="%LOCALAPPDATA%\Programs\Ollama\ollama.exe"
call :LOG_VERBOSE Ollama executavel - %OLLAMA_EXE%

REM Janela separada com cor verde (0A) - estilo start_all.bat
start "Ollama Vulkan (GTX 1060)" cmd /k "title Ollama Vulkan (GTX 1060 6GB) & color 0A & echo [OLLAMA] Iniciando com Vulkan/GPU offload... & echo [OLLAMA] Variaveis: VULKAN=1 GPU_LAYERS=999 FLASH_ATTENTION=1 & echo. & %OLLAMA_EXE% serve"

call :LOG_INFO Aguardando Ollama ficar saudavel (max 60s)....
set WAITED=0
:OLLAMA_WAIT
call :PORTA_SAUDAVEL %OLLAMA_PORT% "models" "/api/tags"
if not errorlevel 1 (
    call :LOG_SUCCESS Ollama pronto e saudavel na porta %OLLAMA_PORT%!
    call :LOG_FILE "ollama.exe (novo processo)" "LLM Local - Modelos: qwen2.5-coder:7b-gpu90, qwen3:8b-gpu90, deepseek-coder:6.7b-gpu90, qwen2.5-coder:1.5b, qwen2.5:0.5b, tinyllama:1.1b" "%OLLAMA_PORT%"
    goto :EOF
)
if %WAITED% geq 60 (
    call :LOG_ERROR Timeout aguardando Ollama ficar saudavel (60s)
    exit /b 1
)
ping -n 4 127.0.0.1 >nul
set /a WAITED+=3
goto :OLLAMA_WAIT


REM ----------------------------------------------------------
REM 2. INICIAR NVIDIA PROXY
REM ----------------------------------------------------------
:START_NVPROXY
call :LOG_INFO === [2/5] Iniciando NVIDIA Proxy (config.yaml) ===

REM Verifica se a porta ja esta ativa e saudavel
call :PORTA_SAUDAVEL %NVPROXY_PORT% "healthy"
if not errorlevel 1 (
    call :LOG_SUCCESS NVIDIA Proxy ja esta ativo e saudavel na porta %NVPROXY_PORT%
    call :LOG_FILE "%NVPROXY_MAIN% (processo existente)" "NVIDIA Proxy - 4 providers (NIM, Gemini, Ollama, OpenAI) + Model Registry + Fallback Chains + Tier Routing + Metrics" "%NVPROXY_PORT%"
    goto :EOF
)

call :PORTA_OCUPADA_PERGUNTAR_ENCERRAR %NVPROXY_PORT%
if errorlevel 1 (
    call :LOG_ERROR NVIDIA Proxy nao esta saudavel na porta %NVPROXY_PORT% e nao pode ser iniciado (porta ocupada por outro processo).
    exit /b 1
)

set FCC_CONFIG_PATH=%CONFIG_FILE%
call :LOG_VERBOSE FCC_CONFIG_PATH=%FCC_CONFIG_PATH%

call :LOG_FILE "%CONFIG_FILE%" "YAML config: nim_instances, gemini_instances, ollama_instances, openai_instances, model_aliases (32), tier_routing (4 tiers), fallback_chains (13), model_registry, reasoning_effort" "%NVPROXY_PORT%"
call :LOG_FILE "%NVPROXY_MAIN%" "Python module: run_server.py -> FastAPI app com routes: /v1/chat/completions, /v1/models, /health, /metrics, /admin/*" "%NVPROXY_PORT%"

REM Criar wrapper para NVIDIA Proxy (evita problemas de aspas no start)
set NVPROXY_WRAPPER=%TEMP%\nvproxy_launcher_%RANDOM%.bat
echo @echo off > "%NVPROXY_WRAPPER%"
echo title NVIDIA Proxy (8089) >> "%NVPROXY_WRAPPER%"
echo color 0A >> "%NVPROXY_WRAPPER%"
echo cd /d %SCRIPT_DIR% >> "%NVPROXY_WRAPPER%"
echo set FCC_CONFIG_PATH=%CONFIG_FILE% >> "%NVPROXY_WRAPPER%"
echo echo [NVPROXY] Carregando config: %CONFIG_FILE% >> "%NVPROXY_WRAPPER%"
echo echo [NVPROXY] Providers: NIM(1), Gemini(1), Ollama(1), OpenAI(1) >> "%NVPROXY_WRAPPER%"
echo echo [NVPROXY] Model aliases: 32 ^| Tier routing: 4 ^| Fallback chains: 13 >> "%NVPROXY_WRAPPER%"
echo echo. >> "%NVPROXY_WRAPPER%"
echo python run_server.py --port %NVPROXY_PORT% >> "%NVPROXY_WRAPPER%"

REM Janela separada com cor verde (0A) - estilo start_all.bat
start "NVIDIA Proxy (8089)" cmd /k "%NVPROXY_WRAPPER%"

call :LOG_INFO Aguardando NVIDIA Proxy ficar saudavel (max 120s)...
set WAITED=0
:NVPROXY_WAIT
call :PORTA_SAUDAVEL %NVPROXY_PORT% "healthy"
if not errorlevel 1 (
    call :LOG_SUCCESS NVIDIA Proxy pronto e saudavel na porta %NVPROXY_PORT%!
    call :LOG_FILE "%NVPROXY_MAIN% (novo processo)" "NVIDIA Proxy ATIVO - OpenAI-compatible API, Model Registry com auto-discovery 30min, Circuit Breaker, Rate Limiting, SSE Streaming" "%NVPROXY_PORT%"
    goto :EOF
)
if %WAITED% geq 120 (
    call :LOG_ERROR Timeout aguardando NVIDIA Proxy ficar saudavel (120s)
    exit /b 1
)
ping -n 6 127.0.0.1 >nul
set /a WAITED+=5
goto :NVPROXY_WAIT


REM ----------------------------------------------------------
REM 3. INICIAR HYBRID PROXY
REM ----------------------------------------------------------
:START_HYPROXY
call :LOG_INFO === [3/5] Iniciando Hybrid Proxy (hybrid.py) ===

REM Verifica se a porta ja esta ativa e saudavel
call :PORTA_SAUDAVEL %HYPROXY_PORT% "ok"
if not errorlevel 1 (
    call :LOG_SUCCESS Hybrid Proxy ja esta ativo e saudavel na porta %HYPROXY_PORT%
    call :LOG_FILE "%HYPROXY_MAIN% (processo existente)" "Hybrid Proxy - Anthropic Messages API -> NVIDIA Proxy (OpenAI-compatible)" "%HYPROXY_PORT%"
    goto :EOF
)

call :PORTA_OCUPADA_PERGUNTAR_ENCERRAR %HYPROXY_PORT%
if errorlevel 1 (
    call :LOG_ERROR Hybrid Proxy nao esta saudavel na porta %HYPROXY_PORT% e nao pode ser iniciado (porta ocupada por outro processo).
    exit /b 1
)

set FCC_CONFIG_PATH=%CONFIG_FILE%
call :LOG_VERBOSE FCC_CONFIG_PATH=%FCC_CONFIG_PATH%

call :LOG_FILE "%HYPROXY_MAIN%" "Python module: hybrid.py -> FastAPI app (Anthropic Messages API format) com VRAM Scheduler, Rate Limiting Adaptativo, Unicode Sanitization (8-layer), SSE Translation (OpenAI->Anthropic), Correlation ID Middleware" "%HYPROXY_PORT%"
call :LOG_VERBOSE Upstream configurado - http://127.0.0.1:%NVPROXY_PORT% (NVIDIA Proxy)

REM Criar wrapper para Hybrid Proxy
set HYPROXY_WRAPPER=%TEMP%\hyproxy_launcher_%RANDOM%.bat
echo @echo off > "%HYPROXY_WRAPPER%"
echo title Hybrid Proxy (3456) >> "%HYPROXY_WRAPPER%"
echo color 0B >> "%HYPROXY_WRAPPER%"
echo cd /d %SCRIPT_DIR% >> "%HYPROXY_WRAPPER%"
echo set FCC_CONFIG_PATH=%CONFIG_FILE% >> "%HYPROXY_WRAPPER%"
echo echo [HYPROXY] Carregando config: %CONFIG_FILE% >> "%HYPROXY_WRAPPER%"
echo echo [HYPROXY] Upstream: http://127.0.0.1:%NVPROXY_PORT% >> "%HYPROXY_WRAPPER%"
echo echo [HYPROXY] VRAM Scheduler: heavy=1 light=2 micro=4 (GTX 1060 6GB) >> "%HYPROXY_WRAPPER%"
echo echo [HYPROXY] Endpoints: /v1/messages, /health, /health/full, /metrics >> "%HYPROXY_WRAPPER%"
echo echo. >> "%HYPROXY_WRAPPER%"
echo python hybrid.py >> "%HYPROXY_WRAPPER%"

REM Janela separada com cor azul (0B) - estilo start_all.bat
start "Hybrid Proxy (3456)" cmd /k "%HYPROXY_WRAPPER%"

call :LOG_INFO Aguardando Hybrid Proxy ficar saudavel (max 60s)....
set WAITED=0
:HYPROXY_WAIT
call :PORTA_SAUDAVEL %HYPROXY_PORT% "ok"
if not errorlevel 1 (
    call :LOG_SUCCESS Hybrid Proxy pronto e saudavel na porta %HYPROXY_PORT%!
    call :LOG_FILE "%HYPROXY_MAIN% (novo processo)" "Hybrid Proxy ATIVO - Anthropic Messages API, VRAM Scheduler tiered, Streaming SSE, Unicode sanitization, Correlation ID propagation" "%HYPROXY_PORT%"
    goto :EOF
)
if %WAITED% geq 60 (
    call :LOG_ERROR Timeout aguardando Hybrid Proxy ficar saudavel (60s)
    exit /b 1
)
ping -n 4 127.0.0.1 >nul
set /a WAITED+=3
goto :HYPROXY_WAIT


REM ----------------------------------------------------------
REM 4. INICIAR MONITORING STACK (Docker Compose)
REM ----------------------------------------------------------
:START_MONITORING
if "%DOCKER_AVAILABLE%"=="false" (
    call :LOG_WARN Docker nao disponivel - Pulando Monitoring Stack
    call :LOG_VERBOSE Prometheus, Grafana, Loki, Alertmanager NAO iniciados
    goto :EOF
)

call :LOG_INFO === [4/5] Iniciando Monitoring Stack (Docker Compose) ===

REM Verifica se cada servico ja esta ativo e saudavel
call :PORTA_SAUDAVEL %PROMETHEUS_PORT% "Prometheus" "/-/healthy"
if not errorlevel 1 (
    call :LOG_SUCCESS Prometheus ja esta ativo e saudavel na porta %PROMETHEUS_PORT%
    set PROM_SKIP=1
) else (
    set PROM_SKIP=0
)

call :PORTA_SAUDAVEL %GRAFANA_PORT% "ok" "/api/health"
if not errorlevel 1 (
    call :LOG_SUCCESS Grafana ja esta ativa e saudavel na porta %GRAFANA_PORT%
    set GRAF_SKIP=1
) else (
    set GRAF_SKIP=0
)

call :PORTA_SAUDAVEL %LOKI_PORT% "ready" "/ready"
if not errorlevel 1 (
    call :LOG_SUCCESS Loki ja esta ativo e saudavel na porta %LOKI_PORT%
    set LOKI_SKIP=1
) else (
    set LOKI_SKIP=0
)

call :PORTA_SAUDAVEL %ALERTMANAGER_PORT% "OK" "/-/healthy"
if not errorlevel 1 (
    call :LOG_SUCCESS Alertmanager ja esta ativo e saudavel na porta %ALERTMANAGER_PORT%
    set ALERT_SKIP=1
) else (
    set ALERT_SKIP=0
)

REM Se todos ja estao saudaveis, pula o restante
if %PROM_SKIP%==1 if %GRAF_SKIP%==1 if %LOKI_SKIP%==1 if %ALERT_SKIP%==1 (
    call :LOG_SUCCESS Monitoring Stack ja esta completamente ativo e saudavel.
    goto :EOF
)

if not exist "%MONITORING_COMPOSE%" (
    call :LOG_ERROR docker-compose.monitoring.yml nao encontrado: %MONITORING_COMPOSE%
    goto :EOF
)
call :LOG_FILE "%MONITORING_COMPOSE%" "Docker Compose: Prometheus(9090) + Alertmanager(9093) + Loki(3100) + Promtail + Grafana(3000) com provisioning auto" "Multi-portas"

%COMPOSE_CMD% -f "%MONITORING_COMPOSE%" down >nul 2>&1

call :LOG_INFO Subindo containers: Prometheus, Alertmanager, Loki, Promtail, Grafana...
%COMPOSE_CMD% -f "%MONITORING_COMPOSE%" up -d

call :LOG_INFO Aguardando inicializacao dos containers (30s)....
ping -n 31 127.0.0.1 >nul

call :LOG_INFO Aguardando servicos de monitoramento ficarem saudaveis (max 90s)....
set WAITED=0
:MON_WAIT
set PROM_OK=0
set GRAF_OK=0
set LOKI_OK=0
set ALERT_OK=0

if %PROM_SKIP%==0 (
    call :PORTA_SAUDAVEL %PROMETHEUS_PORT% "Prometheus" "/-/healthy"
    if not errorlevel 1 set PROM_OK=1
) else set PROM_OK=1

if %GRAF_SKIP%==0 (
    call :PORTA_SAUDAVEL %GRAFANA_PORT% "ok" "/api/health"
    if not errorlevel 1 set GRAF_OK=1
) else set GRAF_OK=1

if %LOKI_SKIP%==0 (
    call :PORTA_SAUDAVEL %LOKI_PORT% "ready" "/ready"
    if not errorlevel 1 set LOKI_OK=1
) else set LOKI_OK=1

if %ALERT_SKIP%==0 (
    call :PORTA_SAUDAVEL %ALERTMANAGER_PORT% "OK" "/-/healthy"
    if not errorlevel 1 set ALERT_OK=1
) else set ALERT_OK=1

if %PROM_OK%==0 goto :MON_NOT_READY
if %GRAF_OK%==0 goto :MON_NOT_READY
if %LOKI_OK%==0 goto :MON_NOT_READY
if %ALERT_OK%==0 goto :MON_NOT_READY

call :LOG_SUCCESS Monitoring Stack pronto e saudavel!
call :LOG_FILE "prometheus.yml" "Scraping targets: hybrid-proxy:3456, nvidia-proxy:8089, ollama:11434 (interval 10s/30s)" "%PROMETHEUS_PORT%"
call :LOG_FILE "alert_rules.yml" "21 alertas: VRAM(2), RateLimit(2), Fallback(3), CircuitBreaker(2), UpstreamHealth(2), Latency(2), ErrorRate(2), Registry(2), TierRouting(1), Streaming(2), CorrelationID(1)" "%PROMETHEUS_PORT%"
call :LOG_FILE "loki-config.yml + promtail-config.yml" "Log aggregation com labels: correlation_id, request_id, job, level, service, model, provider" "%LOKI_PORT%"
call :LOG_FILE "grafana-dashboard.json (17 paineles) + datasources.yml" "Dashboards provisionados: Prometheus, Loki, Alertmanager" "%GRAFANA_PORT%"
goto :EOF

:MON_NOT_READY
if %WAITED% geq 90 (
    call :LOG_WARN Timeout aguardando Monitoring Stack - alguns servicos podem ainda estar subindo
    goto :EOF
)
ping -n 6 127.0.0.1 >nul
set /a WAITED+=5
goto :MON_WAIT


REM ----------------------------------------------------------
REM 5. VALIDACAO FINAL E HEALTH CHECKS
REM ----------------------------------------------------------
:FINAL_VALIDATION
call :LOG_INFO === [5/5] Validacao final dos servicos ===

echo.
call :LOG_VERBOSE ------------------------------------------
call :LOG_VERBOSE HEALTH CHECKS FINAIS
call :LOG_VERBOSE ------------------------------------------

call :PORTA_SAUDAVEL %NVPROXY_PORT% "healthy"
if not errorlevel 1 (
    call :LOG_SUCCESS NVIDIA Proxy: HEALTHY - porta %NVPROXY_PORT%
    call :LOG_VERBOSE   Providers saudaveis - 4/4 (NIM, Gemini, Ollama, OpenAI)
) else (
    call :LOG_ERROR NVIDIA Proxy: UNHEALTHY
)

call :PORTA_SAUDAVEL %HYPROXY_PORT% "ok"
if not errorlevel 1 (
    call :LOG_SUCCESS Hybrid Proxy: HEALTHY - porta %HYPROXY_PORT%
    call :PORTA_SAUDAVEL %HYPROXY_PORT% "upstream"
    if not errorlevel 1 call :LOG_VERBOSE   Health cascata - Disponivel em /health/full
) else (
    call :LOG_ERROR Hybrid Proxy: UNHEALTHY
)

call :PORTA_SAUDAVEL %OLLAMA_PORT% "models" "/api/tags"
if not errorlevel 1 (
    call :LOG_SUCCESS Ollama: HEALTHY - porta %OLLAMA_PORT%
) else (
    call :LOG_ERROR Ollama: UNHEALTHY
)

if "%DOCKER_AVAILABLE%"=="true" (
    call :PORTA_SAUDAVEL %PROMETHEUS_PORT% "Prometheus" "/-/healthy" && call :LOG_SUCCESS Prometheus: HEALTHY - porta %PROMETHEUS_PORT% || call :LOG_WARN Prometheus: Verificar
    call :PORTA_SAUDAVEL %GRAFANA_PORT% "ok" "/api/health" && call :LOG_SUCCESS Grafana: HEALTHY - porta %GRAFANA_PORT% || call :LOG_WARN Grafana: Verificar
    call :PORTA_SAUDAVEL %LOKI_PORT% "ready" "/ready" && call :LOG_SUCCESS Loki: HEALTHY - porta %LOKI_PORT% || call :LOG_WARN Loki: Verificar
    call :PORTA_SAUDAVEL %ALERTMANAGER_PORT% "OK" "/-/healthy" && call :LOG_SUCCESS Alertmanager: HEALTHY - porta %ALERTMANAGER_PORT% || call :LOG_WARN Alertmanager: Verificar
)

echo.
call :LOG_VERBOSE ------------------------------------------
call :LOG_VERBOSE RESUMO DE ENDPOINTS ATIVOS
call :LOG_VERBOSE ------------------------------------------
echo   NVIDIA Proxy (OpenAI):      http://localhost:%NVPROXY_PORT%
echo   Hybrid Proxy (Anthropic):   http://localhost:%HYPROXY_PORT%
echo   Ollama (Local GPU):         http://localhost:%OLLAMA_PORT%
if "%DOCKER_AVAILABLE%"=="true" echo   Prometheus (Metrics):       http://localhost:%PROMETHEUS_PORT%
if "%DOCKER_AVAILABLE%"=="true" echo   Grafana (Dashboards):       http://localhost:%GRAFANA_PORT% [admin/admin]
if "%DOCKER_AVAILABLE%"=="true" echo   Loki (Logs):                http://localhost:%LOKI_PORT%
if "%DOCKER_AVAILABLE%"=="true" echo   Alertmanager (Alerts):      http://localhost:%ALERTMANAGER_PORT%
echo.
echo   Health Checks:
echo     NVIDIA:  curl http://localhost:%NVPROXY_PORT%/health
echo     Hybrid:  curl http://localhost:%HYPROXY_PORT%/health
echo     Full:    curl http://localhost:%HYPROXY_PORT%/health/full
echo     Ollama:  curl http://localhost:%OLLAMA_PORT%/api/tags
echo.
echo   Modelos (via Hybrid Proxy):
echo     curl -H "Authorization: Bearer local-proxy" http://localhost:%HYPROXY_PORT%/v1/models
echo.
echo   Aliases principais (32 total, 4 tiers):
echo     fable/nemotron/nemotron-ultra  ^> nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b
echo     sonnet/qwen/qwen-coder       ^> ollama/qwen2.5-coder:7b-gpu90
echo     opus/gemini-pro/haiku        ^> gemini/gemini-3.1-flash-lite
echo     gpt/gpt-4o                   ^> openai/gpt-4o
echo.
echo   Fallback Chains: 13 chains cross-provider [max 3 hops, loop detection]
echo   VRAM Scheduler: heavy[1] / light[2] / micro[4] concurrency
echo   Correlation ID: propagado via x-request-id header
echo   Log Query: Loki com labels correlation_id / request_id
echo.
call :LOG_VERBOSE ------------------------------------------
goto :EOF


REM ----------------------------------------------------------
REM 6. INICIAR FREE-CLAUDE-CODE COM --RESUME
REM ----------------------------------------------------------
:START_FREE_CLAUDE
call :LOG_INFO === Iniciando free-claude-code --resume %SESSION_ID% ===

if not exist "%FREE_CLAUDE_DIR%" (
    call :LOG_WARN Diretorio free-claude-server nao encontrado: %FREE_CLAUDE_DIR%
    goto :EOF
)

set ANTHROPIC_BASE_URL=http://127.0.0.1:%HYPROXY_PORT%
set ANTHROPIC_API_KEY=local-proxy
set LOCAL_API_KEY=local-proxy
set FCC_API_KEY=local-proxy
set PROXY_API_KEY=local-proxy
set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
set CLAUDE_PROXY_HOST=127.0.0.1
set CLAUDE_PROXY_PORT=%HYPROXY_PORT%
set NVIDIA_PROXY_BASE_URL=http://127.0.0.1:%NVPROXY_PORT%
set NVIDIA_PROXY_API_KEY=sk-local-proxy-20261112
set CLAUDE_PROXY_CLIENT_API_KEY=local-proxy
set CLAUDE_PROXY_AUTH_ENABLED=true

call :LOG_VERBOSE Variaveis configuradas para free-claude-code
call :LOG_VERBOSE   ANTHROPIC_BASE_URL=%ANTHROPIC_BASE_URL%
call :LOG_VERBOSE   ANTHROPIC_API_KEY=local-proxy
call :LOG_VERBOSE   CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

set WRAPPER=%TEMP%\fcc_claude_launcher_%RANDOM%.bat
echo @echo off > "%WRAPPER%"
echo title free-claude-code (--resume %SESSION_ID%) >> "%WRAPPER%"
echo color 0D >> "%WRAPPER%"
echo cd /d "%FREE_CLAUDE_DIR%" >> "%WRAPPER%"
echo set ANTHROPIC_BASE_URL=http://127.0.0.1:%HYPROXY_PORT% >> "%WRAPPER%"
echo set ANTHROPIC_API_KEY=local-proxy >> "%WRAPPER%"
echo set LOCAL_API_KEY=local-proxy >> "%WRAPPER%"
echo set FCC_API_KEY=local-proxy >> "%WRAPPER%"
echo set PROXY_API_KEY=local-proxy >> "%WRAPPER%"
echo set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 >> "%WRAPPER%"
echo echo. >> "%WRAPPER%"
echo echo [FCC-CLAUDE] Iniciando com --resume %SESSION_ID% >> "%WRAPPER%"
echo echo [FCC-CLAUDE] Hybrid Proxy: http://127.0.0.1:%HYPROXY_PORT% >> "%WRAPPER%"
echo echo [FCC-CLAUDE] NVIDIA Proxy: http://127.0.0.1:%NVPROXY_PORT% >> "%WRAPPER%"
echo echo. >> "%WRAPPER%"
echo fcc-claude --resume %SESSION_ID% >> "%WRAPPER%"

REM Janela separada com cor roxa (0D) - estilo start_all.bat
start "free-claude-code (--resume)" cmd /k "%WRAPPER%"

call :LOG_SUCCESS free-claude-code lancado com --resume %SESSION_ID% em janela separada!
call :LOG_FILE "fcc-claude (wrapper: %WRAPPER%)" "Claude Code CLI conectado ao Hybrid Proxy (Anthropic Messages API) com gateway model discovery habilitado" "N/A"


REM ----------------------------------------------------------
REM Pergunta ao usuario se deseja encerrar processo em porta ocupada e nao saudavel
REM Retorna 0 se a porta esta livre ou foi liberada com sucesso, 1 se nao pode prosseguir
REM ----------------------------------------------------------
:PORTA_OCUPADA_PERGUNTAR_ENCERRAR
setlocal
set PORTA_ALVO=%1
set PID_ENCONTRADO=
set RESULTADO=0
netstat -ano > "%TEMP%\port_chk_%PORTA_ALVO%.txt" 2>&1
findstr /r /c:" :%PORTA_ALVO% " "%TEMP%\port_chk_%PORTA_ALVO%.txt" | findstr "LISTENING" >nul 2>&1
if errorlevel 1 (
    del "%TEMP%\port_chk_%PORTA_ALVO%.txt" 2>nul
    endlocal & exit /b 0
)
for /f "tokens=5" %%A in ('findstr /r /c:" :%PORTA_ALVO% " "%TEMP%\port_chk_%PORTA_ALVO%.txt" ^| findstr "LISTENING"') do set PID_ENCONTRADO=%%A
del "%TEMP%\port_chk_%PORTA_ALVO%.txt" 2>nul

if defined PID_ENCONTRADO (
    call :LOG_WARN Porta %PORTA_ALVO% ocupada pelo PID %PID_ENCONTRADO% (nao esta respondendo healthy).
    echo.
    echo %YELLOW%  Deseja encerrar o processo PID %PID_ENCONTRADO% para liberar a porta %PORTA_ALVO%?%NC%
    echo  (S = sim, encerra e continua;  N = nao, aborta esta etapa)
    set /p RESP_ENCERR=  Escolha [S/N]:
    if /I "%RESP_ENCERR%"=="S" (
        call :LOG_INFO Encerrando processo PID %PID_ENCONTRADO% na porta %PORTA_ALVO%...
        taskkill /PID %PID_ENCONTRADO% /F >nul 2>&1
        ping -n 3 127.0.0.1 >nul
        call :LOG_SUCCESS Processo PID %PID_ENCONTRADO% encerrado. Porta %PORTA_ALVO% liberada.
        set RESULTADO=0
    ) else (
        call :LOG_ERROR Operacao cancelada pelo usuario. Porta %PORTA_ALVO% permanece ocupada.
        set RESULTADO=1
    )
)
endlocal & exit /b %RESULTADO%

goto :EOF