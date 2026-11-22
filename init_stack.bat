@echo off
REM ==============================================================================
REM FCC Proxy Stack - Local Development Startup (Windows)
REM ==============================================================================
REM Starts: Ollama (Vulkan) + NVIDIA Proxy (18088) + Hybrid Proxy (3456)
REM Enables: /model command in Claude Code via FCC Server
REM ==============================================================================

setlocal enabledelayedexpansion

REM ==============================================================================
REM ANSI Colors (Windows 10+)
REM ==============================================================================
set RED=\033[0;31m
set GREEN=\033[0;32m
set YELLOW=\033[1;33m
set BLUE=\033[0;34m
set CYAN=\033[0;36m
set MAGENTA=\033[0;35m
set BOLD=\033[1m
set NC=\033[0m

REM ==============================================================================
REM Helper Functions
REM ==============================================================================
:LOG_INFO
echo [%BLUE%INFO%NC%] %~1
goto :EOF

:LOG_SUCCESS
echo [%GREEN%OK%NC%] %~1
goto :EOF

:LOG_WARN
echo [%YELLOW%WARN%NC%] %~1
goto :EOF

:LOG_ERROR
echo [%RED%ERROR%NC%] %~1
goto :EOF

:LOG_STEP
echo.
echo %CYAN%================================================================================%NC%
echo %CYAN%  %~1%NC%
echo %CYAN%================================================================================%NC%
goto :EOF

:LOG_BANNER
echo.
echo %MAGENTA%================================================================================%NC%
echo %MAGENTA%%BOLD%  FCC PROXY STACK - LOCAL INITIALIZATION%NC%
echo %MAGENTA%================================================================================%NC%
echo %MAGENTA%%BOLD%  Ollama (Vulkan) ^| NVIDIA Proxy:10089 ^| Hybrid Proxy:3456%NC%
echo %MAGENTA%================================================================================%NC%
echo.
goto :EOF

REM ==============================================================================
REM Check if process is running on port
REM ==============================================================================
:CHECK_PORT
set PORT_TO_CHECK=%1
set PROC_NAME=%2
netstat -ano | findstr ":%PORT_TO_CHECK% " | findstr "LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    call :LOG_WARN "%PROC_NAME% ja esta rodando na porta %PORT_TO_CHECK%"
    set PORT_%PORT_TO_CHECK%_IN_USE=true
) else (
    set PORT_%PORT_TO_CHECK%_IN_USE=false
)
goto :EOF

:KILL_PORT
set PORT_TO_KILL=%1
set PROC_NAME=%2
call :LOG_INFO "Verificando porta %PORT_TO_KILL% (%PROC_NAME%)..."
call :CHECK_PORT %PORT_TO_KILL% "%PROC_NAME%"
if "!PORT_%PORT_TO_KILL%_IN_USE!"=="true" (
    call :LOG_WARN "Encerrando processo na porta %PORT_TO_KILL%..."
    for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT_TO_KILL% " ^| findstr "LISTENING"') do (
        taskkill /F /PID %%a >nul 2>&1
        if !errorlevel! equ 0 (
            call :LOG_SUCCESS "Processo %%a encerrado"
        ) else (
            call :LOG_ERROR "Falha ao encerrar processo %%a"
        )
    )
    timeout /t 2 /nobreak >nul
)
goto :EOF

REM ==============================================================================
REM Start Ollama with Vulkan
REM ==============================================================================
:START_OLLAMA
call :LOG_STEP "INICIANDO OLLAMA (VULKAN BACKEND)"

call :KILL_PORT 11434 "Ollama"

REM Variaveis de ambiente para Vulkan + Flash Attention + KV Cache 8-bit
set OLLAMA_VULKAN=1
set CUDA_VISIBLE_DEVICES=-1
set GGML_VK_VISIBLE_DEVICES=0
set OLLAMA_NUM_GPU=999
set OLLAMA_FLASH_ATTENTION=1
set OLLAMA_KV_CACHE_TYPE=q8_0
set OLLAMA_NUM_PARALLEL=1

call :LOG_INFO "Variaveis Vulkan configuradas:"
echo   CUDA_VISIBLE_DEVICES=-1
echo   OLLAMA_VULKAN=1
echo   GGML_VK_VISIBLE_DEVICES=0
echo   OLLAMA_NUM_GPU=999
echo   OLLAMA_FLASH_ATTENTION=1
echo   OLLAMA_KV_CACHE_TYPE=q8_0
echo   OLLAMA_NUM_PARALLEL=1

REM Iniciar ollama serve em background
call :LOG_INFO "Iniciando ollama serve..."
start "Ollama Vulkan" cmd /k "set OLLAMA_VULKAN=1 && set CUDA_VISIBLE_DEVICES=-1 && set GGML_VK_VISIBLE_DEVICES=0 && set OLLAMA_NUM_GPU=999 && set OLLAMA_FLASH_ATTENTION=1 && set OLLAMA_KV_CACHE_TYPE=q8_0 && set OLLAMA_NUM_PARALLEL=1 && ollama serve"

timeout /t 5 /nobreak >nul

REM Verificar se Ollama subiu
call :CHECK_PORT 11434 "Ollama"
if "!PORT_11434_IN_USE!"=="true" (
    call :LOG_SUCCESS "Ollama rodando na porta 11434"
) else (
    call :LOG_ERROR "Ollama NAO subiu na porta 11434"
    goto :EOF
)

REM Carregar modelos necessarios
call :LOG_INFO "Carregando modelos (qwen2.5-coder:7b, qwen3:8b, deepseek-coder:6.7b)..."
ollama pull qwen2.5-coder:7b >nul 2>&1
ollama pull qwen3:8b >nul 2>&1
ollama pull deepseek-coder:6.7b >nul 2>&1

call :LOG_SUCCESS "Modelos carregados"
goto :EOF

REM ==============================================================================
REM Start NVIDIA Proxy (Multi-Provider with Model Discovery)
REM ==============================================================================
:START_NVIDIA_PROXY
call :LOG_STEP "INICIANDO NVIDIA PROXY (PORTA 10089)"

call :KILL_PORT 10089 "NVIDIA Proxy"

call :LOG_INFO "Iniciando NVIDIA Proxy (Multi-Provider) em background..."
cd /d "C:\Users\aasoa\free-claude-server\NvidiaProxy"
start "NVIDIA Proxy 10089" cmd /k "python -m uvicorn nvidiaproxy:app --host 127.0.0.1 --port 10089 --workers 1"

timeout /t 8 /nobreak >nul

call :CHECK_PORT 10089 "NVIDIA Proxy"
if "!PORT_10089_IN_USE!"=="true" (
    call :LOG_SUCCESS "NVIDIA Proxy rodando em http://127.0.0.1:10089"
    call :LOG_INFO "Testando health check..."
    curl -s http://127.0.0.1:10089/health >nul 2>&1
    if %errorlevel% equ 0 (
        call :LOG_SUCCESS "Health check OK"
    ) else (
        call :LOG_WARN "Health check falhou - aguarde mais alguns segundos"
    )
    call :LOG_INFO "Testando /v1/models..."
    curl -s -H "x-api-key: sk-local-proxy-20261112" http://127.0.0.1:10089/v1/models | python -c "import sys,json; d=json.load(sys.stdin); print(f'Modelos descobertos: {len(d.get(\"data\",[]))}')" 2>nul
) else (
    call :LOG_ERROR "NVIDIA Proxy NAO subiu na porta 10089"
    goto :EOF
)
goto :EOF

REM ==============================================================================
REM Start Hybrid Proxy (Anthropic Messages -> OpenAI Chat Completions)
REM ==============================================================================
:START_HYBRID_PROXY
call :LOG_STEP "INICIANDO HYBRID PROXY (PORTA 3456)"

call :KILL_PORT 3456 "Hybrid Proxy"

call :LOG_INFO "Iniciando Hybrid Proxy em background..."
cd /d "C:\FCC\ClaudeProxy"
start "Hybrid Proxy 3456" cmd /k "python hybrid.py"

timeout /t 5 /nobreak >nul

call :CHECK_PORT 3456 "Hybrid Proxy"
if "!PORT_3456_IN_USE!"=="true" (
    call :LOG_SUCCESS "Hybrid Proxy rodando em http://127.0.0.1:3456"
    call :LOG_INFO "Testando health check..."
    curl -s http://127.0.0.1:3456/health >nul 2>&1
    if %errorlevel% equ 0 (
        call :LOG_SUCCESS "Health check OK"
    ) else (
        call :LOG_WARN "Health check falhou - aguarde mais alguns segundos"
    )
) else (
    call :LOG_ERROR "Hybrid Proxy NAO subiu na porta 3456"
    goto :EOF
)
goto :EOF

REM ==============================================================================
REM Configure Claude Code for /model command
REM ==============================================================================
:CONFIGURE_CLAUDE
call :LOG_STEP "CONFIGURANDO CLAUDE CODE PARA /model"

call :LOG_INFO "Configurando anthropic_base_url e anthropic_api_key..."
claude config set anthropic_base_url http://127.0.0.1:3456
claude config set anthropic_api_key local-proxy

call :LOG_SUCCESS "Claude Code configurado:"
echo   anthropic_base_url = http://127.0.0.1:3456
echo   anthropic_api_key  = local-proxy
echo.
call :LOG_INFO "Agora voce pode usar /model no Claude Code (88+ modelos disponiveis):"
echo   /model qwen           -^> qwen2.5-coder:7b (Ollama Vulkan)
echo   /model qwen3          -^> qwen3:8b (Ollama Vulkan + reasoning)
echo   /model deepseek       -^> deepseek-coder:6.7b (Ollama Vulkan)
echo   /model nemotron       -^> Nemotron 3 Ultra (NIM)
echo   /model gemini-flash   -^> Gemini 3.8 Flash (Gemini API)
echo   /model kimi           -^> Kimi K3.1 Pro (NIM Direct)
echo   /model gemma-31b      -^> Gemma 4 31B IT (NIM)
echo   /model fable          -^> Fable 5.2 (NIM)
echo   ... e 80+ outros modelos via /v1/models
goto :EOF

REM ==============================================================================
REM Verify Full Stack
REM ==============================================================================
:VERIFY_STACK
call :LOG_STEP "VERIFICACAO COMPLETA DO STACK"

call :LOG_INFO "Testando endpoints..."

echo.
echo %BOLD%=== NVIDIA Proxy (10089) ===%NC%
curl -s http://127.0.0.1:10089/health
echo.
curl -s -H "x-api-key: sk-local-proxy-20261112" http://127.0.0.1:10089/v1/models | python -c "import sys,json; d=json.load(sys.stdin); print(f'Modelos: {len(d.get(\"data\",[]))}')" 2>nul

echo.
echo %BOLD%=== Hybrid Proxy (3456) ===%NC%
curl -s http://127.0.0.1:3456/health
echo.
curl -s -H "x-api-key: local-proxy" http://127.0.0.1:3456/v1/models | python -c "import sys,json; d=json.load(sys.stdin); print(f'Modelos: {len(d.get(\"data\",[]))}')" 2>nul

echo.
echo %BOLD%=== Testando /model aliases ===%NC%
curl -s -X POST http://127.0.0.1:3456/v1/messages ^
  -H "Content-Type: application/json" ^
  -H "x-api-key: local-proxy" ^
  -H "anthropic-version: 2023-06-01" ^
  -d "{\"model\":\"qwen\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" | python -c "import sys,json; d=json.load(sys.stdin); print(f'Resposta: {d.get(\"content\",[{}])[0].get(\"text\",\"OK\")[:60]}...')" 2>nul

echo.
call :LOG_SUCCESS "Stack verificado com sucesso!"
goto :EOF

REM ==============================================================================
REM Main Menu
REM ==============================================================================
:SHOW_MENU
echo.
echo %BOLD%================================================================================%NC%
echo %BOLD%  FCC PROXY STACK - MENU PRINCIPAL%NC%
echo %BOLD%================================================================================%NC%
echo.
echo  [1] Iniciar STACK COMPLETO (Ollama + NVIDIA Proxy + Hybrid Proxy)
echo  [2] Iniciar apenas OLLAMA (Vulkan)
echo  [3] Iniciar apenas NVIDIA PROXY (10089)
echo  [4] Iniciar apenas HYBRID PROXY (3456)
echo  [5] Configurar Claude Code para /model
echo  [6] Verificar stack completo
echo  [7] Parar todos os servicos
echo  [0] Sair
echo.
set /p CHOICE="Escolha uma opcao: "

if "%CHOICE%"=="1" goto :FULL_STACK
if "%CHOICE%"=="2" goto :ONLY_OLLAMA
if "%CHOICE%"=="3" goto :ONLY_NVIDIA
if "%CHOICE%"=="4" goto :ONLY_HYBRID
if "%CHOICE%"=="5" goto :CONFIGURE_CLAUDE
if "%CHOICE%"=="6" goto :VERIFY_STACK
if "%CHOICE%"=="7" goto :STOP_ALL
if "%CHOICE%"=="0" goto :EXIT
echo Opcao invalida!
goto :SHOW_MENU

REM ==============================================================================
REM Execution Paths
REM ==============================================================================
:FULL_STACK
call :START_OLLAMA
call :START_NVIDIA_PROXY
call :START_HYBRID_PROXY
call :CONFIGURE_CLAUDE
call :VERIFY_STACK
goto :SHOW_MENU

:ONLY_OLLAMA
call :START_OLLAMA
goto :SHOW_MENU

:ONLY_NVIDIA
call :START_NVIDIA_PROXY
goto :SHOW_MENU

:ONLY_HYBRID
call :START_HYBRID_PROXY
goto :SHOW_MENU

:STOP_ALL
call :LOG_STEP "PARANDO TODOS OS SERVICOS"
call :KILL_PORT 3456 "Hybrid Proxy"
call :KILL_PORT 10089 "NVIDIA Proxy"
call :KILL_PORT 11434 "Ollama"
call :LOG_SUCCESS "Todos os servicos parados"
goto :SHOW_MENU

:EXIT
call :LOG_INFO "Saindo..."
exit /b 0

REM ==============================================================================
REM Entry Point
REM ==============================================================================
call :LOG_BANNER

REM Verificar se .env existe
if not exist "C:\FCC\ClaudeProxy\.env" (
    call :LOG_ERROR "Arquivo .env nao encontrado em C:\FCC\ClaudeProxy\"
    call :LOG_INFO "Copie .env.example para .env e configure as chaves"
    pause
    exit /b 1
)

REM Verificar python
python --version >nul 2>&1
if %errorlevel% neq 0 (
    call :LOG_ERROR "Python nao encontrado no PATH"
    pause
    exit /b 1
)

REM Verificar ollama
ollama --version >nul 2>&1
if %errorlevel% neq 0 (
    call :LOG_ERROR "Ollama nao encontrado. Instale em https://ollama.com"
    pause
    exit /b 1
)

REM Verificar curl
curl --version >nul 2>&1
if %errorlevel% neq 0 (
    call :LOG_WARN "curl nao encontrado - health checks serao limitados"
)

REM Verificar claude CLI
claude --version >nul 2>&1
if %errorlevel% neq 0 (
    call :LOG_WARN "Claude Code CLI nao encontrado - /model nao funcionara"
)

goto :SHOW_MENU