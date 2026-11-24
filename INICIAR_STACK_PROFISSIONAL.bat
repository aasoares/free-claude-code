@echo off
chcp 65001 >nul
title INICIADOR PROFISSIONAL - FCC NVIDIA PROXY STACK (Sem Docker)

REM ==============================================================================
REM PAUSA INICIAL - Para debug de clique duplo
REM ==============================================================================
echo.
echo ================================================================================
echo   INICIADOR PROFISSIONAL - FCC NVIDIA PROXY STACK
echo ================================================================================
echo.
echo Script iniciado com clique duplo ou linha de comando
echo Diretorio: %~dp0
echo Argumentos: %*
echo ================================================================================
echo.
echo Pressione qualquer tecla para continuar (ou feche para cancelar)...
pause >nul

REM ==============================================================================
REM CONFIGURACAO - Edite conforme necessario
REM ==============================================================================
set MODE=production
set SKIP_OLLAMA=false
set SKIP_FCC_SERVER=false
set SKIP_FREE_CLAUDE=false
set SHOW_WINDOWS=true

REM Parse de argumentos - usar loop simples
:PARSE_ARGS
if "%~1"=="" goto :PARSE_DONE
if "%~1"=="-test" set MODE=test
if "%~1"=="-skip-ollama" set SKIP_OLLAMA=true
if "%~1"=="-skip-fcc" set SKIP_FCC_SERVER=true
if "%~1"=="-skip-claude" set SKIP_FREE_CLAUDE=true
if "%~1"=="-no-windows" set SHOW_WINDOWS=false
if "%~1"=="-help" goto :SHOW_HELP
shift
goto :PARSE_ARGS
:PARSE_DONE

REM ==============================================================================
REM Diretorio do script
REM ==============================================================================
cd /d "%~dp0"
set SCRIPT_DIR=%~dp0

REM Verificar dependencias basicas
where python >nul 2>&1
if errorlevel 1 (
    echo [ERRO] Python nao encontrado no PATH
    echo Instale Python e adicione ao PATH do sistema.
    pause
    exit /b 1
)
where curl >nul 2>&1
if errorlevel 1 (
    echo [AVISO] curl nao encontrado - health checks podem falhar
)
where netstat >nul 2>&1
if errorlevel 1 (
    echo [AVISO] netstat nao encontrado - verificacao de portas desabilitada
)

REM ==============================================================================
REM EXECUCAO PRINCIPAL - DEVE VIR ANTES DAS SUBROTINAS
REM ==============================================================================
call :SHOW_BANNER
if errorlevel 1 goto :ERROR_EXIT

call :CHECK_ALL_PORTS
if errorlevel 1 goto :ERROR_EXIT

call :START_OLLAMA
if errorlevel 1 goto :ERROR_EXIT

call :START_NVPROXY
if errorlevel 1 goto :ERROR_EXIT

call :START_HPROXY
if errorlevel 1 goto :ERROR_EXIT

call :START_FCCSRV
if errorlevel 1 goto :ERROR_EXIT

call :VERIFY_MODELS
if errorlevel 1 goto :ERROR_EXIT

call :START_FCLAUDE
if errorlevel 1 goto :ERROR_EXIT

call :SHOW_SUMMARY
if errorlevel 1 goto :ERROR_EXIT

goto :CLEAN_EXIT

:ERROR_EXIT
echo.
echo ================================================================================
echo   ERRO DURANTE INICIALIZACAO
echo ================================================================================
echo.
echo Verifique as mensagens acima para identificar o problema.
echo.
pause >nul 2>&1
exit /b 1

:CLEAN_EXIT
echo.
echo ================================================================================
echo   INICIALIZACAO CONCLUIDA COM SUCESSO
echo ================================================================================
echo.
echo Pressione qualquer tecla para fechar esta janela...
pause >nul 2>&1
exit /b 0

REM ==============================================================================
REM SUBROTINAS (TODAS ABAIXO DA EXECUCAO PRINCIPAL)
REM ==============================================================================

REM ----------------------------------------------------------
REM Banner
REM ----------------------------------------------------------
:SHOW_BANNER
cls
echo.
echo ================================================================================
echo   FCC NVIDIA PROXY STACK - INICIADOR PROFISSIONAL (Sem Docker)
echo ================================================================================
echo.
if "%MODE%"=="test" goto :SHOW_BANNER_TEST
echo   MODO:           PRODUCAO
echo   NVIDIA Proxy:   10089   Hybrid Proxy:    3456
echo   FCC Server:     8082    Ollama:          11434
echo   free-claude:    --resume
echo ================================================================================
echo.
goto :EOF

:SHOW_BANNER_TEST
echo   MODO:           TESTE (portas alternativas)
echo   NVIDIA Proxy:   10090   Hybrid Proxy:    3457
echo   FCC Server:     8082    Ollama:          11434
echo   free-claude:    --resume
echo ================================================================================
echo.
goto :EOF

REM ----------------------------------------------------------
REM Funcao de espera (evita problemas de timeout /nobreak)
REM ----------------------------------------------------------
:LOG_WAIT
timeout /t %1 >nul 2>&1
goto :EOF

REM ----------------------------------------------------------
REM Verificar se porta esta em uso
REM ----------------------------------------------------------
:CHECK_PORT
set PORT=%1
set SERVICE_NAME=%2
netstat -ano > "%TEMP%\portchk.txt" 2>&1
findstr /r /c:" :%PORT% " "%TEMP%\portchk.txt" | findstr "LISTENING" >nul 2>&1
if %errorlevel% neq 0 goto :CHECK_PORT_FREE
for /f "tokens=5" %%a in ('findstr /r /c:" :%PORT% " "%TEMP%\portchk.txt" ^| findstr "LISTENING"') do set PID=%%a
echo [AVISO] %SERVICE_NAME% (porta %PORT%) ja esta em uso - PID: %PID%
set PORT_IN_USE=true
del "%TEMP%\portchk.txt" 2>nul
goto :EOF

:CHECK_PORT_FREE
echo [OK] %SERVICE_NAME% (porta %PORT%) livre
set PORT_IN_USE=false
del "%TEMP%\portchk.txt" 2>nul
goto :EOF

REM ----------------------------------------------------------
REM Verificar todas as portas
REM ----------------------------------------------------------
:CHECK_ALL_PORTS
echo.
echo === Verificando disponibilidade das portas ===

if "%MODE%"=="test" (
    set NVPORT=10090
    set HPPORT=3457
) else (
    set NVPORT=10089
    set HPPORT=3456
)

set FCCPORT=8082
set OLLAMAPORT=11434

call :CHECK_PORT %NVPORT% "NVIDIA_Proxy"
call :CHECK_PORT %HPPORT% "Hybrid_Proxy"
call :CHECK_PORT %FCCPORT% "FCC_Server"
call :CHECK_PORT %OLLAMAPORT% "Ollama"

echo.
goto :EOF

REM ----------------------------------------------------------
REM Iniciar Ollama Vulkan
REM ----------------------------------------------------------
:START_OLLAMA
if "%SKIP_OLLAMA%"=="true" (
    echo [AVISO] Pulando Ollama (-skip-ollama^)
    goto :EOF
)

echo.
echo === Iniciando Ollama Vulkan (GTX 1060 6GB)...

REM Verificar se Ollama ja responde
curl -s http://localhost:%OLLAMAPORT%/api/tags >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Ollama ja esta rodando na porta %OLLAMAPORT%
    for /f "tokens=*" %%a in ('curl -s http://localhost:%OLLAMAPORT%/api/tags ^| findstr /c:"models"') do (
        echo    Modelos disponiveis: %%a
    )
    goto :EOF
)

REM Configurar variaveis Vulkan
set OLLAMA_VULKAN=1
set GGML_VK_VISIBLE_DEVICES=0
set OLLAMA_NUM_GPU=999
set OLLAMA_FLASH_ATTENTION=1
set OLLAMA_KV_CACHE_TYPE=q8_0
set OLLAMA_NUM_PARALLEL=1
set CUDA_VISIBLE_DEVICES=-1

REM Encontrar ollama.exe
set OLLAMA_EXE=ollama
if exist "%SCRIPT_DIR%..\Ollama\ollama.exe" set OLLAMA_EXE="%SCRIPT_DIR%..\Ollama\ollama.exe"
if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" set OLLAMA_EXE="%LOCALAPPDATA%\Programs\Ollama\ollama.exe"

echo [INFO] Iniciando: %OLLAMA_EXE% serve
if "%SHOW_WINDOWS%"=="true" (
    start "Ollama Vulkan" cmd /k "title Ollama Vulkan (GTX 1060) & color 0A & echo Iniciando Ollama com Vulkan... & %OLLAMA_EXE% serve"
) else (
    start /b "" %OLLAMA_EXE% serve
)

REM Aguardar Ollama ficar pronto
echo [INFO] Aguardando Ollama ficar pronto (max 30s)...
set WAITED=0
:OLLAMA_WAIT
curl -s http://localhost:%OLLAMAPORT%/api/tags >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Ollama pronto!
    goto :EOF
)
if %WAITED% geq 30 (
    echo [ERRO] Timeout aguardando Ollama
    exit /b 1
)
call :LOG_WAIT 2
set /a WAITED+=2
goto :OLLAMA_WAIT

REM ----------------------------------------------------------
REM Iniciar NVIDIA Proxy
REM ----------------------------------------------------------
:START_NVPROXY
echo.
echo === Iniciando NVIDIA Proxy...

if "%MODE%"=="test" (
    set CONFIG=config.test.yaml
    set ENV=.env.test
    set NVPORT=10090
) else (
    set CONFIG=config.yaml
    set ENV=.env
    set NVPORT=10089
)

REM Verificar se ja esta rodando
curl -s http://localhost:%NVPORT%/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] NVIDIA Proxy ja esta rodando na porta %NVPORT%
    goto :EOF
)

set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG%
if "%SHOW_WINDOWS%"=="true" (
    start "NVIDIA Proxy" cmd /k "title NVIDIA Proxy (%NVPORT%) & color 0A & cd /d %SCRIPT_DIR% & set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG% & python -m nvidia_proxy.cli --port %NVPORT%"
) else (
    start /b "" cmd /c "cd /d %SCRIPT_DIR% & set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG% & python -m nvidia_proxy.cli --port %NVPORT%"
)

REM Aguardar health check
echo [INFO] Aguardando NVIDIA Proxy (max 60s)...
set WAITED=0
:NVPROXY_WAIT
curl -s http://localhost:%NVPORT%/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] NVIDIA Proxy pronto na porta %NVPORT%!
    goto :EOF
)
if %WAITED% geq 60 (
    echo [ERRO] Timeout aguardando NVIDIA Proxy
    exit /b 1
)
call :LOG_WAIT 3
set /a WAITED+=3
goto :NVPROXY_WAIT

REM ----------------------------------------------------------
REM Iniciar Hybrid Proxy
REM ----------------------------------------------------------
:START_HPROXY
echo.
echo === Iniciando Hybrid Proxy...

if "%MODE%"=="test" (
    set HPPORT=3457
) else (
    set HPPORT=3456
)

REM Verificar se ja esta rodando
curl -s http://localhost:%HPPORT%/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Hybrid Proxy ja esta rodando na porta %HPPORT%
    goto :EOF
)

set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG%
if "%SHOW_WINDOWS%"=="true" (
    start "Hybrid Proxy" cmd /k "title Hybrid Proxy (%HPPORT%) & color 0B & cd /d %SCRIPT_DIR% & set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG% & python hybrid.py"
) else (
    start /b "" cmd /c "cd /d %SCRIPT_DIR% & set FCC_CONFIG_PATH=%SCRIPT_DIR%%CONFIG% & python hybrid.py"
)

REM Aguardar health check
echo [INFO] Aguardando Hybrid Proxy (max 30s)...
set WAITED=0
:HPROXY_WAIT
curl -s http://localhost:%HPPORT%/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Hybrid Proxy pronto na porta %HPPORT%!
    goto :EOF
)
if %WAITED% geq 30 (
    echo [ERRO] Timeout aguardando Hybrid Proxy
    exit /b 1
)
call :LOG_WAIT 2
set /a WAITED+=2
goto :HPROXY_WAIT

REM ----------------------------------------------------------
REM Iniciar FCC Server (porta 8082)
REM ----------------------------------------------------------
:START_FCCSRV
if "%SKIP_FCC_SERVER%"=="true" (
    echo [AVISO] Pulando FCC Server (-skip-fcc^)
    goto :EOF
)

echo.
echo === Iniciando FCC Server (porta 8082)...

curl -s http://localhost:8082/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] FCC Server ja esta rodando na porta 8082
    goto :EOF
)

REM Procurar servidor FCC
set FCC_SERVER=
if exist "%SCRIPT_DIR%server.py" set FCC_SERVER=%SCRIPT_DIR%server.py
if exist "%SCRIPT_DIR%fcc_proxy\server.py" set FCC_SERVER=%SCRIPT_DIR%fcc_proxy\server.py
if exist "C:\Users\aasoa\free-claude-server\server.py" set FCC_SERVER=C:\Users\aasoa\free-claude-server\server.py

if "%FCC_SERVER%"=="" (
    echo [AVISO] FCC Server nao encontrado (server.py), pulando...
    goto :EOF
)

if "%SHOW_WINDOWS%"=="true" (
    start "FCC Server" cmd /k "title FCC Server (8082) & color 0C & cd /d %~dp1 & python %~nx1"
) else (
    start /b "" cmd /c "cd /d %~dp1 & python %~nx1"
)

echo [INFO] Aguardando FCC Server (max 20s)...
set WAITED=0
:FCC_WAIT
curl -s http://localhost:8082/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] FCC Server pronto na porta 8082!
    goto :EOF
)
if %WAITED% geq 20 (
    echo [AVISO] FCC Server pode nao ter iniciado completamente
    goto :EOF
)
call :LOG_WAIT 2
set /a WAITED+=2
goto :FCC_WAIT

REM ----------------------------------------------------------
REM Verificar modelos GPT no catalogo
REM ----------------------------------------------------------
:VERIFY_MODELS
echo.
echo === Verificando catalogo de modelos (GPT)...

if "%MODE%"=="test" (
    set HPPORT=3457
) else (
    set HPPORT=3456
)

for /f "tokens=*" %%a in ('curl -s -H "Authorization: Bearer local-proxy" http://localhost:%HPPORT%/v1/models 2^>nul ^| find /c /i "gpt"') do set GPT_COUNT=%%a
for /f "tokens=*" %%a in ('curl -s -H "Authorization: Bearer local-proxy" http://localhost:%HPPORT%/v1/models 2^>nul ^| find /c "id"') do set TOTAL_COUNT=%%a

if "%GPT_COUNT%"=="" set GPT_COUNT=0
if "%TOTAL_COUNT%"=="" set TOTAL_COUNT=0

echo [OK] Total de modelos: %TOTAL_COUNT% ^| GPT: %GPT_COUNT%

REM Testar inferencia rapida
echo [INFO] Teste rapido de inferencia (gpt)...
set TEST_CMD=curl -s -X POST -H "Authorization: Bearer local-proxy" -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" -d "{\"model\":\"gpt\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":5}" http://localhost:%HPPORT%/v1/messages
for /f "tokens=*" %%a in ('%TEST_CMD% 2^>nul') do set TEST_RESULT=%%a
if defined TEST_RESULT (
    echo [OK] Inferencia funcionando
) else (
    echo [AVISO] Inferencia pode ter problemas (verifique logs)
)

goto :EOF

REM ----------------------------------------------------------
REM Iniciar free-claude-code com --resume
REM ----------------------------------------------------------
:START_FCLAUDE
if "%SKIP_FREE_CLAUDE%"=="true" (
    echo [AVISO] Pulando free-claude-code (-skip-claude^)
    goto :EOF
)

echo.
echo === Iniciando free-claude-code com --resume...

set FREE_CLAUDE_DIR=C:\Users\aasoa\free-claude-server
if not exist "%FREE_CLAUDE_DIR%" (
    echo [AVISO] Diretorio free-claude-server nao encontrado: %FREE_CLAUDE_DIR%
    goto :EOF
)

if "%MODE%"=="test" (
    set NVPORT=10090
    set HPPORT=3457
) else (
    set NVPORT=10089
    set HPPORT=3456
)

set NVIDIA_PROXY_BASE_URL=http://127.0.0.1:%NVPORT%
set ANTHROPIC_BASE_URL=http://127.0.0.1:%HPPORT%
set CLAUDE_PROXY_HOST=127.0.0.1
set CLAUDE_PROXY_PORT=%HPPORT%
set NVIDIA_PROXY_API_KEY=sk-local-proxy-20261112
set CLAUDE_PROXY_CLIENT_API_KEY=local-proxy
set CLAUDE_PROXY_AUTH_ENABLED=true
set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
set ANTHROPIC_API_KEY=local-proxy

REM Criar wrapper temporario que seta vars e chama fcc-claude com session ID
set WRAPPER=%TEMP%\fcc_claude_launcher_%RANDOM%.bat
echo @echo off > "%WRAPPER%"
echo setlocal >> "%WRAPPER%"
echo title free-claude-code (--resume) >> "%WRAPPER%"
echo cd /d "%FREE_CLAUDE_DIR%" >> "%WRAPPER%"
echo set ANTHROPIC_BASE_URL=http://127.0.0.1:%HPPORT% >> "%WRAPPER%"
echo set ANTHROPIC_API_KEY=local-proxy >> "%WRAPPER%"
echo set LOCAL_API_KEY=local-proxy >> "%WRAPPER%"
echo set FCC_API_KEY=local-proxy >> "%WRAPPER%"
echo set PROXY_API_KEY=local-proxy >> "%WRAPPER%"
echo set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 >> "%WRAPPER%"
echo set ANTHROPIC_MODEL=nvidia/nemotron-3-ultra-550b-a55b >> "%WRAPPER%"
echo echo NVIDIA Proxy (OpenAI): %NVIDIA_PROXY_BASE_URL% >> "%WRAPPER%"
echo echo Hybrid Proxy (Anthropic): http://127.0.0.1:%HPPORT% >> "%WRAPPER%"
echo echo. >> "%WRAPPER%"
echo fcc-claude --resume 535c2fa1-6e9a-450b-b67d-2800cfd362ea >> "%WRAPPER%"
echo pause >> "%WRAPPER%"

if "%SHOW_WINDOWS%"=="true" (
    start "free-claude-code" cmd /k "%WRAPPER%"
    echo [OK] free-claude-code lancado com --resume em janela separada!
) else (
    echo [AVISO] Modo -no-windows: free-claude-code nao iniciado (precisa terminal interativo)
    echo [INFO] Execute manual: cd /d "%FREE_CLAUDE_DIR%" && fcc-claude --resume 535c2fa1-6e9a-450b-b67d-2800cfd362ea
    REM No-windows mode: nao falhar, apenas avisar
    exit /b 0
)

goto :EOF

REM ----------------------------------------------------------
REM Resumo final
REM ----------------------------------------------------------
:SHOW_SUMMARY
echo.
echo ================================================================================
echo   STACK IA LOCAL INICIALIZADA COM SUCESSO
echo ================================================================================
echo.

if "%MODE%"=="test" (
    set NVPORT=10090
    set HPPORT=3457
) else (
    set NVPORT=10089
    set HPPORT=3456
)

echo Servicos ativos:
echo   - Ollama Vulkan:     http://localhost:11434
echo   - NVIDIA Proxy:      http://127.0.0.1:%NVPORT%
echo   - Hybrid Proxy:      http://127.0.0.1:%HPPORT%
echo   - FCC Server:        http://127.0.0.1:8082
if "%SKIP_FREE_CLAUDE%"=="false" echo   - free-claude-code:  Rodando com --resume
echo.

echo Endpoints uteis:
echo   - Health NVIDIA:     http://127.0.0.1:%NVPORT%/health
echo   - Health Hybrid:     http://127.0.0.1:%HPPORT%/health
echo   - Modelos NVIDIA:    http://127.0.0.1:%NVPORT%/v1/models
echo   - Modelos Hybrid:    http://127.0.0.1:%HPPORT%/v1/models
echo   - Admin UI (FCC):    http://127.0.0.1:8082/admin
echo   - Metricas Prometheus: http://127.0.0.1:9090/metrics
echo.

echo Comandos no free-claude-code:
echo   - /model              -^> Lista todos os modelos (inclui GPT aliases)
echo   - /model gpt          -^> Seleciona GPT-4o (fallback se sem creditos)
echo   - /model gpt-4o-mini  -^> Seleciona GPT-4o-mini
echo   - /model sonnet       -^> Seleciona Qwen 2.5 Coder 7B (GPU)
echo   - /model fable        -^> Seleciona Nemotron 3 Ultra (NIM)
echo.

echo Janelas de monitoramento abertas para cada servico.
echo Pressione Ctrl+C nas janelas dos proxies para parar.
echo ================================================================================

exit /b 0

REM ----------------------------------------------------------
REM Help
REM ----------------------------------------------------------
:SHOW_HELP
echo.
echo Uso: %~nx0 [opcoes]
echo.
echo Opcoes:
echo   -test           Modo teste (portas 10090/3457)
echo   -skip-ollama    Nao iniciar Ollama (se ja estiver rodando)
echo   -skip-fcc       Nao iniciar FCC Server (porta 8082)
echo   -skip-claude    Nao iniciar free-claude-code
echo   -no-windows     Nao abrir janelas separadas (modo background)
echo   -help           Mostra esta ajuda
echo.
echo Exemplos:
echo   %~nx0                    # Producao completo
echo   %~nx0 -test              # Teste em portas alternativas
echo   %~nx0 -skip-ollama       # Producao sem Ollama
echo   %~nx0 -no-windows        # Background sem janelas
echo.
pause
goto :EOF