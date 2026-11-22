<#
.SYNOPSIS
    Inicializador da stack FCC Proxy (Ollama, Hybrid Proxy, FCC Server) + Claude Code.
.DESCRIPTION
    Carrega variáveis de C:\FCC\ClaudeProxy\.env, valida/sobe os serviços nas portas
    configuradas e inicia o fcc-claude retomando a sessão especificada.
#>

[CmdletBinding()]
param(
    [string]$EnvFile = "C:\FCC\ClaudeProxy\.env",
    [string]$SessionId = "535c2fa1-6e9a-450b-b67d-2800cfd362ea"
)

$ErrorActionPreference = "Stop"

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Arquivo .env não encontrado em: $Path"
        return
    }
    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($key, $val, "Process")
    }
    Write-Host "[OK] Variáveis carregadas de $Path" -ForegroundColor Green
}

function Test-LocalPort {
    param(
        [string]$HostName = "127.0.0.1",
        [int]$Port,
        [int]$TimeoutMs = 400
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar) | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-LocalPort {
    param(
        [int]$Port,
        [string]$ServiceName,
        [int]$TimeoutSec = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-LocalPort -Port $Port) {
            Write-Host "[OK] $ServiceName ativo na porta $Port" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Warning "$ServiceName não respondeu na porta $Port após ${TimeoutSec}s."
    return $false
}

# 1. Carregar .env
Import-DotEnv -Path $EnvFile

$fccPort   = if ($env:PORT) { [int]$env:PORT } else { 8082 }
$proxyPort = if ($env:CLAUDE_PROXY_PORT) { [int]$env:CLAUDE_PROXY_PORT } else { 3456 }
$nimPort   = 8089
if ($env:NVIDIA_PROXY_BASE_URL -match ":(\d+)") {
    $nimPort = [int]$Matches[1]
}

# 2. Ollama (11434)
if (Test-LocalPort -Port 11434) {
    Write-Host "[OK] Ollama já ativo na porta 11434" -ForegroundColor Cyan
} elseif (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Host "[..] Iniciando Ollama (11434)..." -ForegroundColor Yellow
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Minimized
    Wait-LocalPort -Port 11434 -ServiceName "Ollama" -TimeoutSec 10 | Out-Null
} else {
    Write-Warning "Ollama não encontrado no PATH (porta 11434 offline)."
}

# 3. NVIDIA Proxy (8089)
if (Test-LocalPort -Port $nimPort) {
    Write-Host "[OK] NVIDIA Proxy já ativo na porta $nimPort" -ForegroundColor Cyan
} else {
    Write-Warning "NVIDIA Proxy não está escutando na porta $nimPort. Se necessário, inicie-o via C:\FCC\ClaudeProxy\init_stack.bat."
}

# 4. Hybrid Proxy (3456)
$hybridScript = "C:\FCC\ClaudeProxy\hybrid.py"
if (Test-LocalPort -Port $proxyPort) {
    Write-Host "[OK] Hybrid Proxy já ativo na porta $proxyPort" -ForegroundColor Cyan
} elseif (Test-Path -LiteralPath $hybridScript) {
    Write-Host "[..] Iniciando Hybrid Proxy ($proxyPort)..." -ForegroundColor Yellow
    $pyCmd = if (Get-Command uv -ErrorAction SilentlyContinue) { "uv" } else { "python" }
    $pyArgs = if ($pyCmd -eq "uv") { @("run", $hybridScript) } else { @($hybridScript) }
    Start-Process -FilePath $pyCmd -ArgumentList $pyArgs -WorkingDirectory "C:\FCC\ClaudeProxy" -WindowStyle Minimized
    Wait-LocalPort -Port $proxyPort -ServiceName "Hybrid Proxy" -TimeoutSec 10 | Out-Null
} else {
    Write-Warning "hybrid.py não encontrado em $hybridScript."
}

# 5. FCC Server (8082)
$fccExe = "$env:APPDATA\uv\tools\free-claude-code\Scripts\fcc-server.exe"
if (Test-LocalPort -Port $fccPort) {
    Write-Host "[OK] FCC Server já ativo na porta $fccPort" -ForegroundColor Cyan
} elseif (Test-Path -LiteralPath $fccExe) {
    Write-Host "[..] Iniciando FCC Server ($fccPort)..." -ForegroundColor Yellow
    Start-Process -FilePath $fccExe -WindowStyle Minimized
    Wait-LocalPort -Port $fccPort -ServiceName "FCC Server" -TimeoutSec 15 | Out-Null
} elseif (Get-Command fcc-server -ErrorAction SilentlyContinue) {
    Write-Host "[..] Iniciando fcc-server ($fccPort)..." -ForegroundColor Yellow
    Start-Process -FilePath "fcc-server" -WindowStyle Minimized
    Wait-LocalPort -Port $fccPort -ServiceName "FCC Server" -TimeoutSec 15 | Out-Null
} else {
    Write-Error "fcc-server.exe não encontrado em $fccExe nem no PATH."
}

# 6. Exportar chaves da sessão e iniciar fcc-claude
$env:ANTHROPIC_API_KEY = "local-proxy"
$env:LOCAL_API_KEY     = "local-proxy"
$env:FCC_API_KEY       = "local-proxy"
$env:PROXY_API_KEY     = "local-proxy"

Write-Host "[>>] Executando fcc-claude --resume $SessionId" -ForegroundColor Green
fcc-claude --resume $SessionId
