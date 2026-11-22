@echo off
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
set NC=\033[0m

set SCRIPT_DIR=%~dp0
set COMPOSE_FILE=%SCRIPT_DIR%docker-compose.yml
set ENV_FILE=%SCRIPT_DIR%.env

REM Default options
set BUILD=false
set FOLLOW_LOGS=false
set STOP=false
set CLEAN=false

REM Parse arguments
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
REM Main execution
REM ==============================================================================
echo ==============================================================================
echo         NVIDIA Proxy Stack - Startup Script (Windows)
echo ==============================================================================
echo.

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