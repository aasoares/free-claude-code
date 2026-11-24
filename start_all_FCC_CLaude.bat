@echo off
chcp 65001 >nul
title INICIADOR FCC NVIDIA PROXY STACK (Duplo Clique)

REM ==============================================================================
REM PAUSA INICIAL - Para funcionar com duplo clique
REM ==============================================================================
echo.
echo ================================================================================
echo   INICIADOR FCC NVIDIA PROXY STACK
echo ================================================================================
echo.
echo Diretorio: %~dp0
echo ================================================================================
echo.
echo Pressione qualquer tecla para continuar (ou feche para cancelar)...
pause >nul

REM ==============================================================================
REM NVIDIA Proxy Stack - Startup Script (Windows)
REM ==============================================================================
REM Starts the full stack: NIM + NVIDIA Proxy + Hybrid Proxy + Prometheus + Grafana
REM
REM Prerequisites:
REM   - Docker & Docker Compose installed
REM   - NVIDIA Container Toolkit (for GPU support)
REM   - NGC_API_KEY set in .env or environment
REM
REM Usage:
REM   start_all.bat              # Start all services
REM   start_all.bat --build      # Rebuild images before starting
REM   start_all.bat --logs       # Follow logs after starting
REM   start_all.bat --stop       # Stop all services
REM   start_all.bat --clean      # Stop and remove volumes
REM ==============================================================================

setlocal enabledelayedexpansion

REM Colors (using ANSI codes - works in Windows 10+)
set RED=\033[0;31m
set GREEN=\033[0;32m
set YELLOW=\033[1;33m
set BLUE=\033[0;34m
set CYAN=\033[0;36m
set MAGENTA=\033[0;35m
set BOLD=\033[1m
set NC=\033[0m

set SCRIPT_DIR=%~dp0
set COMPOSE_FILE=%SCRIPT_DIR%docker-compose.yml
set ENV_FILE=%SCRIPT_DIR%.env

REM Default options
set BUILD=false
set FOLLOW_LOGS=false
set STOP=false
set CLEAN=false

REM ==============================================================================
REM Banner profissional
REM ==============================================================================
:SHOW_BANNER
echo.
echo %MAGENTA%%BOLD%==============================================================================%NC%
echo %MAGENTA%%BOLD%  FCC NVIDIA PROXY STACK - INICIALIZADOR PROFISSIONAL%NC%
echo %MAGENTA%%BOLD%==============================================================================%NC%
echo %CYAN%  NVIDIA Proxy:    %GREEN%8089%NC%   Hybrid Proxy:    %GREEN%3456%NC%
echo %CYAN%  Prometheus:      %GREEN%9091%NC%   Grafana:         %GREEN%3000%NC%
echo %CYAN%  NVIDIA NIM:      %GREEN%8000%NC%   Ollama:          %GREEN%11434%NC%
echo %MAGENTA%%BOLD%==============================================================================%NC%
echo.

:PARSE_ARGS
if "%~1"=="" goto :PARSE_DONE
if "%~1"=="--build" set BUILD=true & shift & goto :PARSE_ARGS
if "%~1"=="--logs" set FOLLOW_LOGS=true & shift & goto :PARSE_ARGS
if "%~1"=="--stop" set STOP=true & shift & goto :PARSE_ARGS
if "%~1"=="--clean" set CLEAN=true & shift & goto :PARSE_ARGS
if "%~1"=="--help" goto :SHOW_HELP
if "%~1"=="-h" goto :SHOW_HELP
echo Unknown option: %~1
exit /b 1
:PARSE_DONE

REM Helper functions
:LOG_INFO
echo [%BLUE%INFO%NC%] %~1
goto :EOF

:LOG_SUCCESS
echo [%GREEN%SUCCESS%NC%] %~1
goto :EOF

:LOG_WARN
echo [%YELLOW%WARN%NC%] %~1
goto :EOF

:LOG_ERROR
echo [%RED%ERROR%NC%] %~1
goto :EOF

:CHECK_PREREQS
call :LOG_INFO "Checking prerequisites..."

REM Check Docker
docker --version >nul 2>&1
if errorlevel 1 (
    call :LOG_ERROR "Docker not found. Please install Docker first."
    exit /b 1
)

REM Check Docker Compose
docker compose version >nul 2>&1
if errorlevel 1 (
    docker-compose --version >nul 2>&1
    if errorlevel 1 (
        call :LOG_ERROR "Docker Compose not found. Please install Docker Compose first."
        exit /b 1
    ) else (
        set COMPOSE_CMD=docker-compose
    )
) else (
    set COMPOSE_CMD=docker compose
)

REM Check .env file
if not exist "%ENV_FILE%" (
    call :LOG_WARN ".env file not found. Creating template..."
    echo # NVIDIA Proxy Stack Environment Variables > "%ENV_FILE%"
    echo # ======================================== >> "%ENV_FILE%"
    echo # Get your NGC API key from: https://ngc.nvidia.com/setup/api-key >> "%ENV_FILE%"
    echo NGC_API_KEY=your-ngc-api-key-here >> "%ENV_FILE%"
    echo  >> "%ENV_FILE%"
    echo # Admin UI authentication token (optional) >> "%ENV_FILE%"
    echo ADMIN_TOKEN=your-secure-admin-token >> "%ENV_FILE%"
    echo  >> "%ENV_FILE%"
    echo # Grafana admin password >> "%ENV_FILE%"
    echo GRAFANA_PASSWORD=admin >> "%ENV_FILE%"
    call :LOG_WARN "Please edit .env and add your NGC_API_KEY before starting!"
    exit /b 1
)

REM Check NGC_API_KEY
for /f "tokens=1,* delims==" %%a in ('type "%ENV_FILE%" ^| findstr /R "^NGC_API_KEY="') do (
    set NGC_API_KEY=%%b
)

if "%NGC_API_KEY%"=="" (
    call :LOG_ERROR "NGC_API_KEY not set in .env file!"
    call :LOG_ERROR "Get your API key from: https://ngc.nvidia.com/setup/api-key"
    exit /b 1
)

if "%NGC_API_KEY%"=="your-ngc-api-key-here" (
    call :LOG_ERROR "NGC_API_KEY not set in .env file!"
    call :LOG_ERROR "Get your API key from: https://ngc.nvidia.com/setup/api-key"
    exit /b 1
)

call :LOG_SUCCESS "Prerequisites check passed"
goto :EOF

:STOP_SERVICES
call :LOG_INFO "Stopping services..."
%COMPOSE_CMD% -f "%COMPOSE_FILE%" down
call :LOG_SUCCESS "Services stopped"
goto :EOF

:CLEAN_SERVICES
call :LOG_WARN "This will remove all data volumes! Press Ctrl+C to cancel..."
timeout /t 3 /nobreak >nul
call :LOG_INFO "Stopping and removing services with volumes..."
%COMPOSE_CMD% -f "%COMPOSE_FILE%" down -v --remove-orphans
call :LOG_SUCCESS "Services stopped and volumes removed"
goto :EOF

:START_SERVICES
call :LOG_INFO "Starting NVIDIA Proxy Stack..."

set BUILD_FLAG=
if "%BUILD%"=="true" (
    set BUILD_FLAG=--build
    call :LOG_INFO "Building images..."
)

%COMPOSE_CMD% -f "%COMPOSE_FILE%" up -d %BUILD_FLAG%

call :LOG_SUCCESS "Services started!"

REM Wait for health checks
call :LOG_INFO "Waiting for services to be healthy..."
timeout /t 5 /nobreak >nul

REM Check service status
%COMPOSE_CMD% -f "%COMPOSE_FILE%" ps

echo.
call :LOG_SUCCESS "=== Service Endpoints ==="
echo   NVIDIA Proxy:       http://localhost:8089
echo   Admin Dashboard:    http://localhost:8089/admin/dashboard
echo   Metrics:            http://localhost:8089/metrics
echo   Hybrid Proxy:       http://localhost:3456
echo   Prometheus:         http://localhost:9091
echo   Grafana:            http://localhost:3000 (admin/admin)
echo.
echo   Health Checks:
echo     NVIDIA Proxy:  curl http://localhost:8089/health
echo     Hybrid Proxy:  curl http://localhost:3456/health
echo     NIM:           curl http://localhost:8000/v1/models
echo.

REM ==============================================================================
REM Lançar janelas separadas para cada proxy (visual profissional)
REM ==============================================================================
call :LOG_INFO "Abrindo janelas separadas para cada proxy..."

start "NVIDIA Proxy - 8089" cmd /k "title NVIDIA Proxy (8089) & color 0A & echo NVIDIA Proxy rodando em http://localhost:8089 & echo. & :loop & curl -s http://localhost:8089/health 2>nul & echo. & timeout /t 5 /nobreak >nul & goto loop"
start "Hybrid Proxy - 3456" cmd /k "title Hybrid Proxy (3456) & color 0B & echo Hybrid Proxy rodando em http://localhost:3456 & echo. & :loop & curl -s http://localhost:3456/health 2>nul & echo. & timeout /t 5 /nobreak >nul & goto loop"
start "Prometheus - 9091" cmd /k "title Prometheus (9091) & color 0C & echo Prometheus rodando em http://localhost:9091 & echo. & :loop & curl -s http://localhost:9091/-/healthy 2>nul & echo. & timeout /t 5 /nobreak >nul & goto loop"
start "Grafana - 3000" cmd /k "title Grafana (3000) & color 0D & echo Grafana rodando em http://localhost:3000 & echo. & :loop & curl -s http://localhost:3000/api/health 2>nul & echo. & timeout /t 5 /nobreak >nul & goto loop"

call :LOG_SUCCESS "Janelas separadas abertas para todos os proxies."
echo.
goto :EOF

:FOLLOW_LOGS
call :LOG_INFO "Following logs (Ctrl+C to exit)..."
%COMPOSE_CMD% -f "%COMPOSE_FILE%" logs -f --tail=100
goto :EOF

:SHOW_HELP
echo Usage: %~nx0 [--build] [--logs] [--stop] [--clean]
echo   --build    Rebuild Docker images before starting
echo   --logs     Follow logs after starting
echo   --stop     Stop all services
echo   --clean    Stop and remove volumes (data loss!)
exit /b 0





REM ==============================================================================
REM Iniciar free-claude-code com --resume
REM ==============================================================================
:START_FREE_CLAUDE
set FREE_CLAUDE_DIR=C:\Users\aasoa\free-claude-server
if exist "%FREE_CLAUDE_DIR%" (
    cd /d "%FREE_CLAUDE_DIR%"
    set ANTHROPIC_BASE_URL=http://127.0.0.1:3456
    set ANTHROPIC_API_KEY=local-proxy
    set LOCAL_API_KEY=local-proxy
    set FCC_API_KEY=local-proxy
    set PROXY_API_KEY=local-proxy
    set CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
    set ANTHROPIC_MODEL=nvidia/nemotron-3-ultra-550b-a55b
    echo Iniciando free-claude-code com --resume...
    start "free-claude-code" cmd /k "title free-claude-code (--resume) & color 0D & fcc-claude --resume 535c2fa1-6e9a-450b-b67d-2800cfd362ea"
) else (
    echo [AVISO] Diretorio free-claude-server nao encontrado
)
goto :EOF













REM ==============================================================================
REM Main execution
REM ==============================================================================
call :SHOW_BANNER

call :CHECK_PREREQS

if "%STOP%"=="true" (
    call :STOP_SERVICES
    exit /b 0
)

if "%CLEAN%"=="true" (
    call :CLEAN_SERVICES
    exit /b 0
)

call :START_SERVICES

if "%FOLLOW_LOGS%"=="true" (
    call :FOLLOW_LOGS
)

call :START_FREE_CLAUDE

echo.
echo ================================================================================
echo   INICIALIZACAO CONCLUIDA
echo ================================================================================
echo.
echo Pressione qualquer tecla para fechar esta janela...
pause >nul