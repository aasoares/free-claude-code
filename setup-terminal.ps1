<#PSScriptInfo
.VERSION 1.0.0
.GUID 8f3e2a1b-7c4d-4e9f-8a2b-1f6d3e4c5a9b
.AUTHOR "Claude Code"
.COPYRIGHT "2026"
.TAGS "terminal", "oh-my-posh", "nerd-font", "starship", "setup"
.LICENSEURI "MIT"
.PROJECTURI "https://github.com/JanDeDobbeleer/oh-my-posh"
#>

<#
.SYNOPSIS
    Configuração automática do terminal com Oh My Posh + Nerd Font + Temas

.DESCRIPTION
    Instala Oh My Posh, JetBrains Mono Nerd Font, configura Windows Terminal,
    adiciona ao $PROFILE e oferece menu interativo para escolher tema.

.NOTES
    Requer: Windows 10/11, PowerShell 5.1+, Windows Terminal (recomendado)
    Execute como Administrador para instalar fonte system-wide (opcional)
#>

#region Configuração
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cores para output
$C = @{
    Reset   = [char]27 + '[0m'
    Red     = [char]27 + '[31m'
    Green   = [char]27 + '[32m'
    Yellow  = [char]27 + '[33m'
    Blue    = [char]27 + '[34m'
    Magenta = [char]27 + '[35m'
    Cyan    = [char]27 + '[36m'
    White   = [char]27 + '[37m'
    Bold    = [char]27 + '[1m'
    Dim     = [char]27 + '[2m'
}

function Write-Color([string]$Message, [string]$Color = 'White') {
    Write-Host "$($C.$Color)$Message$($C.Reset)"
}

function Write-Step([string]$Message) { Write-Color "▶ $Message" 'Cyan' }
function Write-Success([string]$Message) { Write-Color "✔ $Message" 'Green' }
function Write-Warning([string]$Message) { Write-Color "⚠ $Message" 'Yellow' }
function Write-ErrorMsg([string]$Message) { Write-Color "✖ $Message" 'Red' }
function Write-Info([string]$Message) { Write-Color "  $Message" 'Dim' }

#endregion

#region Verificações Iniciais
function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WindowsTerminal {
    return (Get-Command 'wt' -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA\Microsoft\Windows Terminal\wt.exe")
}

function Test-OhMyPosh {
    return Get-Command 'oh-my-posh' -ErrorAction SilentlyContinue
}

function Test-NerdFont {
    $fontPath = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFont-Regular.ttf"
    return Test-Path $fontPath
}

function Get-ProfilePath {
    $profilePaths = @(
        $PROFILE.CurrentUserAllHosts,
        $PROFILE.CurrentUserCurrentHost,
        $PROFILE.AllUsersAllHosts,
        $PROFILE.AllUsersCurrentHost
    )
    foreach ($p in $profilePaths) {
        if (Test-Path $p) { return $p }
    }
    return $PROFILE.CurrentUserAllHosts
}

#endregion

#region Instalação Oh My Posh
function Install-OhMyPosh {
    Write-Step "Verificando Oh My Posh..."
    if (Test-OhMyPosh) {
        $version = oh-my-posh --version 2>&1 | Select-Object -First 1
        Write-Success "Oh My Posh já instalado: $version"
        return $true
    }

    Write-Step "Instalando Oh My Posh via winget..."
    try {
        winget install JanDeDobbeleer.OhMyPosh --silent --accept-source-agreements --accept-package-agreements
        Write-Success "Oh My Posh instalado"
        return $true
    }
    catch {
        Write-ErrorMsg "Falha ao instalar Oh My Posh: ${_}"
        return $false
    }
}

#endregion

#region Instalação Nerd Font
function Install-NerdFont {
    Write-Step "Verificando JetBrains Mono Nerd Font..."
    if (Test-NerdFont) {
        Write-Success "Fonte já instalada"
        return $true
    }

    Write-Step "Baixando e instalando JetBrains Mono Nerd Font..."
    $url = "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/JetBrainsMono.zip"
    $zipPath = "$env:TEMP\JetBrainsMono.zip"
    $extractPath = "$env:TEMP\JetBrainsMono"
    $fontDest = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"

    try {
        if (-not (Test-Path $fontDest)) {
            New-Item -ItemType Directory -Path $fontDest -Force | Out-Null
        }

        Write-Info "Baixando de $url..."
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

        Write-Info "Extraindo..."
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $fonts = Get-ChildItem "$extractPath\*.ttf"
        $count = 0
        foreach ($font in $fonts) {
            $destFile = Join-Path $fontDest $font.Name
            if (-not (Test-Path $destFile)) {
                Copy-Item $font.FullName -Destination $destFile -Force
                $count++
            }
        }

        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

        Write-Success "$count arquivos de fonte instalados em $fontDest"
        Write-Warning "Reinicie o Windows Terminal para a fonte aparecer"
        return $true
    }
    catch {
        Write-ErrorMsg "Falha ao instalar fonte: ${_}"
        return $false
    }
}

#endregion

#region Configuração Windows Terminal
function Configure-WindowsTerminal {
    Write-Step "Configurando Windows Terminal..."

    $settingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (-not (Test-Path $settingsPath)) {
        Write-Warning "Windows Terminal não encontrado ou settings.json inexistente"
        Write-Info "Instale via: winget install Microsoft.WindowsTerminal"
        return $false
    }

    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $profileUpdated = $false

        $profiles = $settings.profiles.list
        $psProfile = $null

        foreach ($p in $profiles) {
            if ($p.commandline -like "*powershell*" -or $p.name -like "*PowerShell*" -or $p.source -eq "Windows.Terminal.PowershellCore") {
                $psProfile = $p
                break
            }
        }

        if (-not $psProfile -and $profiles.Count -gt 0) {
            $psProfile = $profiles[0]
        }

        if ($psProfile) {
            $psProfile.fontFace = "JetBrainsMono Nerd Font"
            $psProfile.fontSize = 11
            $profileUpdated = $true
            Write-Success "Perfil '$($psProfile.name)' atualizado com JetBrainsMono Nerd Font"
        }

        if ($profileUpdated) {
            Copy-Item $settingsPath "$settingsPath.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')" -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
            Write-Success "settings.json atualizado (backup criado)"
        }

        return $true
    }
    catch {
        Write-ErrorMsg "Falha ao configurar Windows Terminal: ${_}"
        return $false
    }
}

#endregion

#region Configuração $PROFILE
function Configure-Profile {
    param(
        [string]$ThemePath
    )

    Write-Step "Configurando $PROFILE..."
    $profilePath = Get-ProfilePath
    $profileDir = Split-Path $profilePath

    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $initLine = "oh-my-posh init pwsh --config `"$ThemePath`" | Invoke-Expression"
    $commentLine = "# Oh My Posh - Auto-configurado por setup-terminal.ps1"

    try {
        $content = @()
        if (Test-Path $profilePath) {
            $existing = Get-Content $profilePath -Raw
            $existing = $existing -split "`r?`n" | Where-Object {
                $_ -notmatch 'oh-my-posh init' -and $_ -notmatch 'Auto-configurado por setup-terminal'
            } -join "`n"
            if ($existing.Trim()) { $content += $existing.Trim() }
        }

        $content += ""
        $content += $commentLine
        $content += $initLine

        Set-Content -Path $profilePath -Value ($content -join "`n") -Encoding UTF8
        Write-Success "$PROFILE atualizado em $profilePath"
        return $true
    }
    catch {
        $err = ${_}
        $msg = 'Falha ao atualizar perfil: ' + $err
        Write-ErrorMsg $msg
        return $false
    }
}

#endregion

#region Menu Interativo
function Show-ThemeMenu {
    Write-Color "`n╔══════════════════════════════════════════════════════════════╗" 'Cyan'
    Write-Color "║          OH MY POSH - SELECIONAR TEMA                        ║" 'Cyan'
    Write-Color "╚══════════════════════════════════════════════════════════════╝`n" 'Cyan'

    $themes = @(
        @{ Name = "nerd-font";     Desc = "Mais completo (OS, Git, 12 linguagens, Docker, K8s, TF, .NET, Java, hora)"; File = "nerd-font.omp.json" },
        @{ Name = "catppuccin";    Desc = "Catppuccin Mocha (rosa, verde, azul, amarelo) + hg, azure, cmd_duration"; File = "catppuccin.omp.json" },
        @{ Name = "tokyo-night";   Desc = "Tokyo Night Storm (azul/roxo) + fetch_upstream"; File = "tokyo-night.omp.json" },
        @{ Name = "dracula";       Desc = "Dracula (alto contraste, roxo/verde/laranja)"; File = "dracula.omp.json" },
        @{ Name = "nord";          Desc = "Nord (tons frios, minimalista)"; File = "nord.omp.json" },
        @{ Name = "gruvbox";       Desc = "Gruvbox Material (terroso, quente)"; File = "gruvbox.omp.json" },
        @{ Name = "rose-pine";     Desc = "Rose Pine Moon (rosado, suave)"; File = "rose-pine.omp.json" },
        @{ Name = "one-dark";      Desc = "Atom One Dark (clássico IDE)"; File = "one-dark.omp.json" },
        @{ Name = "minimal";       Desc = "Ultra-limpo (path + git + status + hora)"; File = "minimal.omp.json" },
        @{ Name = "pure";          Desc = "Estilo Pure/Zsh (❯ marker, tempo >1s)"; File = "pure.omp.json" }
    )

    for ($i = 0; $i -lt $themes.Count; $i++) {
        $t = $themes[$i]
        Write-Color "  [$($i + 1)] $($t.Name.PadRight(12)) - $($t.Desc)" 'White'
    }

    Write-Color "`n  [0] Pular (não configurar tema no $PROFILE)`n" 'Dim'

    while ($true) {
        $choice = Read-Host "Escolha um tema (1-10 ou 0)"
        if ($choice -match '^[0-9]+$') {
            $choice = [int]$choice
            if ($choice -eq 0) { return $null }
            if ($choice -ge 1 -and $choice -le $themes.Count) {
                return $themes[$choice - 1]
            }
        }
        Write-Warning "Opção inválida. Digite 0-10."
    }
}

function Show-StarshipOption {
    Write-Color "`n╔══════════════════════════════════════════════════════════════╗" 'Magenta'
    Write-Color "║          STARSHIP (alternativa ao Oh My Posh)                ║" 'Magenta'
    Write-Color "╚══════════════════════════════════════════════════════════════╝`n" 'Magenta'

    $choice = Read-Host "Também quer configurar Starship? (s/N) "
    if ($choice -like 's*') {
        return $true
    }
    return $false
}

function Configure-Starship {
    Write-Step "Verificando Starship..."
    if (-not (Get-Command 'starship' -ErrorAction SilentlyContinue)) {
        Write-Step "Instalando Starship via winget..."
        try {
            winget install Starship.Starship --silent --accept-source-agreements --accept-package-agreements
            Write-Success "Starship instalado"
        }
        catch {
            Write-ErrorMsg "Falha ao instalar Starship: ${_}"
            return $false
        }
    }
    else {
        Write-Success "Starship já instalado"
    }

    $themes = @(
        @{ Name = "nerd-font";   Desc = "Completo + custom .NET, Java, Bun"; File = "nerd-font.toml" },
        @{ Name = "tokyo-night"; Desc = "Tokyo Night"; File = "tokyo-night.toml" },
        @{ Name = "catppuccin";  Desc = "Catppuccin Mocha"; File = "catppuccin.toml" },
        @{ Name = "dracula";     Desc = "Dracula"; File = "dracula.toml" },
        @{ Name = "nord";        Desc = "Nord"; File = "nord.toml" },
        @{ Name = "gruvbox";     Desc = "Gruvbox"; File = "gruvbox.toml" },
        @{ Name = "rose-pine";   Desc = "Rose Pine"; File = "rose-pine.toml" },
        @{ Name = "one-dark";    Desc = "One Dark"; File = "one-dark.toml" },
        @{ Name = "minimal";     Desc = "Minimal"; File = "minimal.toml" },
        @{ Name = "pure";        Desc = "Pure"; File = "pure.toml" }
    )

    Write-Color "`nTemas Starship disponíveis:" 'Cyan'
    for ($i = 0; $i -lt $themes.Count; $i++) {
        Write-Color "  [$($i + 1)] $($themes[$i].Name) - $($themes[$i].Desc)" 'White'
    }
    Write-Color "  [0] Pular`n" 'Dim'

    $choice = Read-Host 'Escolha tema Starship (1-10 ou 0)'
    if ($choice -match '^[1-9]$|^10$') {
        $choice = [int]$choice
        if ($choice -ge 1 -and $choice -le $themes.Count) {
            $theme = $themes[$choice - 1]
            $themePath = "~/.config/starship-themes/$($theme.File)"
            $profilePath = Get-ProfilePath

            $initLine = "starship init powershell --config `"$themePath`" | Invoke-Expression"
            $commentLine = "# Starship - Auto-configurado por setup-terminal.ps1"

            try {
                $content = @()
                if (Test-Path $profilePath) {
                    $existing = Get-Content $profilePath -Raw
                    $existing = $existing -split "`r?`n" | Where-Object {
                        $_ -notmatch 'starship init' -and $_ -notmatch 'Auto-configurado por setup-terminal'
                    } -join "`n"
                    if ($existing.Trim()) { $content += $existing.Trim() }
                }
                $content += ""
                $content += $commentLine
                $content += $initLine
                Set-Content -Path $profilePath -Value ($content -join "`n") -Encoding UTF8
                Write-Success "Starship configurado no $PROFILE com tema $($theme.Name)"
            }
            catch {
                $err = ${_}
                $msg = 'Falha ao configurar Starship no perfil: ' + $err
                Write-ErrorMsg $msg
            }
        }
    }
}

#endregion

#region Teste Imediato
function Test-ThemeNow {
    param([string]$ThemePath)

    Write-Color "`n╔══════════════════════════════════════════════════════════════╗" 'Green'
    Write-Color "║          TESTAR TEMA AGORA                                   ║" 'Green'
    Write-Color "╚══════════════════════════════════════════════════════════════╝`n" 'Green'

    $choice = Read-Host "Aplicar tema na sessão atual para testar? (S/n) "
    if ($choice -notlike 'n*') {
        Write-Step "Aplicando tema..."
        try {
            oh-my-posh init pwsh --config $ThemePath | Invoke-Expression
            Write-Success "Tema aplicado! (válido apenas nesta sessão)"
            Write-Info "Abra um NOVO terminal para ver o tema permanente"
        }
        catch {
            Write-ErrorMsg "Falha ao aplicar tema: ${_}"
        }
    }
}

#endregion

#region Main
function Main {
    Write-Color "`n╔══════════════════════════════════════════════════════════════╗" 'Bold'
    Write-Color "║     SETUP TERMINAL - Oh My Posh + Nerd Font + Temas          ║" 'Bold'
    Write-Color "╚══════════════════════════════════════════════════════════════╝`n" 'Bold'

    $isAdmin = Test-Admin
    if ($isAdmin) { Write-Info "Executando como Administrador" }
    else { Write-Info "Executando como usuário padrão (fonte será user-only)" }

    if (-not (Install-OhMyPosh)) { return }
    if (-not (Install-NerdFont)) { return }

    if (Test-WindowsTerminal) {
        Configure-WindowsTerminal | Out-Null
    }
    else {
        Write-Warning "Windows Terminal não detectado. Instale com: winget install Microsoft.WindowsTerminal"
    }

    $selectedTheme = Show-ThemeMenu
    if ($selectedTheme) {
        $themePath = "~/.config/omp-themes/$($selectedTheme.File)"
        if (-not (Configure-Profile -ThemePath $themePath)) { return }
        Test-ThemeNow -ThemePath $themePath
    }

    if (Show-StarshipOption) {
        Configure-Starship
    }

    Write-Color "`n╔══════════════════════════════════════════════════════════════╗" 'Green'
    Write-Color "║                    ✅ CONCLUÍDO                              ║" 'Green'
    Write-Color "╚══════════════════════════════════════════════════════════════╝`n" 'Green'

    Write-Color "Próximos passos:" 'Cyan'
    Write-Info "1. Reinicie o Windows Terminal (ou abra nova aba Ctrl+Shift+N)"
    Write-Info "2. Verifique se a fonte está: Settings → Profile → Appearance → Font face: 'JetBrainsMono Nerd Font'"
    Write-Info "3. O tema selecionado carregará automaticamente"
    Write-Info ""
    Write-Info "Para trocar tema depois:"
    Write-Info "  oh-my-posh init pwsh --config ~/.config/omp-themes/<tema>.omp.json | Invoke-Expression"
    Write-Info "  # Edite $PROFILE para tornar permanente"
    Write-Info ""
    Write-Info "Temas Oh My Posh em: ~/.config/omp-themes/"
    Write-Info "Temas Starship em:  ~/.config/starship-themes/"

    Read-Host "`nPressione Enter para sair"
}

Main

#endregion