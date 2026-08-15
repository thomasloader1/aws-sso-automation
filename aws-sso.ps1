<#
.SYNOPSIS
  AWS SSO helper: list, login, status and optional DEV DB tunnel.

.DESCRIPTION
  Reusable CLI for Bayer AWS SSO profiles on Windows PowerShell.
  Reads profiles from %USERPROFILE%\.aws\config (no credentials stored here).

.EXAMPLE
  .\scripts\aws-sso.ps1 list
.EXAMPLE
  .\scripts\aws-sso.ps1 status
.EXAMPLE
  .\scripts\aws-sso.ps1 login
.EXAMPLE
  .\scripts\aws-sso.ps1 login -Profiles bayco_cl_dev,sso-standard-user-490184323245
.EXAMPLE
  .\scripts\aws-sso.ps1 login -All
.EXAMPLE
  .\scripts\aws-sso.ps1 use bayco_cl_dev
.EXAMPLE
  .\scripts\aws-sso.ps1 db-tunnel
.EXAMPLE
  .\scripts\aws-sso.ps1 db-tunnel -LocalPort 15432 -AwsProfile bayco_cl_dev
.EXAMPLE
  .\scripts\aws-sso.ps1 menu
.EXAMPLE
  .\scripts\aws-sso.ps1 discover
.EXAMPLE
  .\scripts\aws-sso.ps1 sql-console
.EXAMPLE
  .\scripts\aws-sso.ps1 migrate-setup
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "status", "login", "use", "db-tunnel", "menu", "discover", "targets", "sql-console", "migrate-setup", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$ProfileName,

    [string[]]$Profiles,

    [switch]$All,

    [string]$AwsProfile = "",

    [string]$Environment = "",

    [int]$LocalPort = 5432,

    [string]$DbEngine = "",

    [string]$BastionId = ""
)

$ErrorActionPreference = "Stop"

function Write-Info([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-ErrLine([string]$Message) { Write-Host $Message -ForegroundColor Red }

$AwsConfigPath = Join-Path $env:USERPROFILE ".aws\config"
$script:IsDotSourced = ($MyInvocation.InvocationName -eq ".") -or ($MyInvocation.Line -match '^\s*\.\s+')

$DevTargets = @{}

function Get-AvailableEnvironments {
    if ($discovered -and $discovered.Environments) {
        return @($discovered.Environments.PSObject.Properties.Name)
    }
    return @()
}

function Set-DevTargetsFromConfig {
    param([string]$EnvName)

    $script:DevTargets = @{}
    $targetConfig = $null

    if ($discovered -and $discovered.Environments) {
        $available = @($discovered.Environments.PSObject.Properties.Name)
        if ($available -contains $EnvName) {
            $targetConfig = $discovered.Environments.$EnvName
        }
        elseif ($available.Count -gt 0) {
            $targetConfig = $discovered.Environments.$($available[0])
            Write-WarnLine ("Ambiente '{0}' no encontrado en {1}. Usando '{2}'." -f $EnvName, $TargetsFile, $available[0])
            $script:Environment = $available[0]
        }
    }
    elseif ($discovered -and $discovered.Targets) {
        $targetConfig = $discovered
    }

    if ($targetConfig) {
        if ($targetConfig.BastionId -and -not $PSBoundParameters.ContainsKey('BastionId')) {
            $script:BastionId = $targetConfig.BastionId
        }
        if ($targetConfig.Targets) {
            foreach ($key in $targetConfig.Targets.PSObject.Properties.Name) {
                $t = $targetConfig.Targets.$key
                $script:DevTargets[$key] = @{
                    Host    = $t.Host
                    Port    = $t.Port
                    Catalog = $t.Catalog
                    Note    = $t.Note
                }
            }
        }
    }
}

function Select-Environment {
    param([string]$Prompt = "Elegí un ambiente")

    if ($Environment -and -not [string]::IsNullOrWhiteSpace($Environment)) {
        return $Environment.Trim()
    }

    $envNames = Get-AvailableEnvironments
    if ($envNames.Count -gt 0) {
        Write-Info "Ambientes disponibles:"
        for ($i = 0; $i -lt $envNames.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $envNames[$i])
        }
        Write-Host "  [n] Crear un ambiente nuevo"
        while ($true) {
            $sel = Read-Host ("{0} (numero/n, o 'q' para cancelar)" -f $Prompt)
            if ($sel -eq 'q') { throw "Operacion cancelada." }
            if ($sel -eq 'n') { break }
            $n = 0
            if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $envNames.Count) {
                return $envNames[$n - 1]
            }
            Write-ErrLine "Opcion invalida."
        }
    }

    while ($true) {
        $envName = Read-Host ("{0} (nombre del ambiente, o 'q' para cancelar)" -f $Prompt)
        if ($envName -eq 'q') { throw "Operacion cancelada." }
        if (-not [string]::IsNullOrWhiteSpace($envName)) {
            return $envName.Trim()
        }
        Write-ErrLine "Debes indicar un nombre de ambiente."
    }
}

function Select-AwsProfile {
    param([string]$Prompt = "Elegí un perfil AWS SSO")

    if ($AwsProfile -and -not [string]::IsNullOrWhiteSpace($AwsProfile)) {
        return $AwsProfile.Trim()
    }

    $profiles = Get-AwsConfigProfiles
    if ($profiles.Count -eq 0) {
        throw "No se encontraron perfiles SSO en $AwsConfigPath"
    }

    if ($Environment -and -not [string]::IsNullOrWhiteSpace($Environment)) {
        $matching = @($profiles | Where-Object { @($_.Name -split '[^a-zA-Z0-9]+') -contains $Environment })
        if ($matching.Count -gt 0) {
            $profiles = $matching
        }
        else {
            Write-WarnLine ("No se encontro ningun perfil para el ambiente '{0}'. Mostrando todos los perfiles." -f $Environment)
        }
    }

    Write-Info $Prompt
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        Write-Host ("  [{0}] {1}  (cuenta {2}, rol {3})" -f ($i + 1), $p.Name, $p.SsoAccountId, $p.SsoRoleName)
    }

    while ($true) {
        $sel = Read-Host "Ingresa el numero de perfil (o 'q' para cancelar)"
        if ($sel -eq 'q') { throw "Operacion cancelada." }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
            return $profiles[$n - 1].Name
        }
        Write-ErrLine "Opcion invalida."
    }
}

function Select-DbEngine {
    param([string]$Prompt = "Elegí un target DB")

    if ($DbEngine -and -not [string]::IsNullOrWhiteSpace($DbEngine)) {
        return $DbEngine.Trim()
    }

    $keys = @($DevTargets.Keys | Sort-Object)
    if ($keys.Count -eq 0) {
        Write-WarnLine ("El ambiente '{0}' no tiene targets configurados." -f $Environment)
        $create = Read-HostOrDefault -Prompt "Querés crear un target ahora? (s/n)" -Default "s"
        if ($create -match '^(s|si|y|yes)$') {
            Invoke-Targets
            Set-DevTargetsFromConfig -EnvName $Environment
            $keys = @($DevTargets.Keys | Sort-Object)
        }
        if ($keys.Count -eq 0) {
            throw "No hay targets configurados en el ambiente seleccionado. Usa 'targets' o 'discover' primero."
        }
    }

    Write-Info $Prompt
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $key = $keys[$i]
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $key, $DevTargets[$key].Note)
    }

    while ($true) {
        $sel = Read-Host "Ingresa el numero de target (o 'q' para cancelar)"
        if ($sel -eq 'q') { throw "Operacion cancelada." }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $keys.Count) {
            return $keys[$n - 1]
        }
        Write-ErrLine "Opcion invalida."
    }
}

$TargetsFile = Join-Path $PSScriptRoot "aws-sso.targets.json"
if (Test-Path -Path $TargetsFile) {
    try {
        $discovered = Get-Content -Raw -Path $TargetsFile | ConvertFrom-Json
        Set-DevTargetsFromConfig -EnvName $Environment
    }
    catch {
        Write-Host ("No se pudo leer {0}: {1}" -f $TargetsFile, $_.Exception.Message) -ForegroundColor Yellow
    }
}

$StateFile = Join-Path $PSScriptRoot "aws-sso.state.json"

function Get-PersistedProfile {
    if (-not (Test-Path -Path $StateFile)) { return $null }
    try {
        $state = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        return $state.LastProfile
    }
    catch {
        return $null
    }
}

function Set-PersistedProfile {
    param([Parameter(Mandatory)][string]$ProfileName)
    $state = [ordered]@{ LastProfile = $ProfileName }
    [System.IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json))
}

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    # aws.exe a veces escribe a stderr aunque el exit code sea 0; con
    # $ErrorActionPreference = "Stop" eso se vuelve un error terminante.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = & aws @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    [pscustomobject]@{
        Output   = ($raw | Out-String)
        ExitCode = $exitCode
    }
}

function Test-AwsCli {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw "AWS CLI no encontrado. Instala AWS CLI v2 y reinicia la terminal."
    }
}

function Get-AwsConfigProfiles {
    if (-not (Test-Path $AwsConfigPath)) {
        throw "No existe $AwsConfigPath"
    }

    $profiles = @()
    $current = $null

    foreach ($raw in Get-Content -Path $AwsConfigPath) {
        $line = $raw.Trim()
        if ($line -match '^\[profile\s+(.+)\]$') {
            if ($null -ne $current) { $profiles += [pscustomobject]$current }
            $current = [ordered]@{
                Name         = $Matches[1].Trim()
                SsoSession   = $null
                SsoStartUrl  = $null
                SsoAccountId = $null
                SsoRoleName  = $null
                Region       = $null
            }
            continue
        }
        if ($line -match '^\[default\]$') {
            if ($null -ne $current) { $profiles += [pscustomobject]$current }
            $current = [ordered]@{
                Name         = "default"
                SsoSession   = $null
                SsoStartUrl  = $null
                SsoAccountId = $null
                SsoRoleName  = $null
                Region       = $null
            }
            continue
        }
        if ($line -match '^\[sso-session\s+') {
            if ($null -ne $current) { $profiles += [pscustomobject]$current; $current = $null }
            continue
        }
        if ($null -eq $current) { continue }

        if ($line -match '^sso_session\s*=\s*(.+)$') { $current.SsoSession = $Matches[1].Trim() }
        elseif ($line -match '^sso_start_url\s*=\s*(.+)$') { $current.SsoStartUrl = $Matches[1].Trim() }
        elseif ($line -match '^sso_account_id\s*=\s*(.+)$') { $current.SsoAccountId = $Matches[1].Trim() }
        elseif ($line -match '^sso_role_name\s*=\s*(.+)$') { $current.SsoRoleName = $Matches[1].Trim() }
        elseif ($line -match '^region\s*=\s*(.+)$') { $current.Region = $Matches[1].Trim() }
    }

    if ($null -ne $current) { $profiles += [pscustomobject]$current }

    return @(
        $profiles | Where-Object {
            ($_.SsoSession -or $_.SsoStartUrl) -and $_.SsoAccountId -and $_.SsoRoleName
        }
    )
}

function Get-ProfileAuthStatus {
    param([Parameter(Mandatory)][string]$Name)

    $result = [ordered]@{
        Name    = $Name
        Status  = "expired"
        Account = $null
        Arn     = $null
        Detail  = $null
    }

    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $json = & aws sts get-caller-identity --profile $Name --output json 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEap

        if ($exitCode -ne 0) {
            $text = ($json | Out-String).Trim()
            if ($text -match "Token has expired|refresh failed|SSO.*expired|Unable to locate credentials|Error loading SSO") {
                $result.Status = "expired"
            }
            else {
                $result.Status = "error"
            }
            $result.Detail = (($text -split "`n") | Select-Object -First 2) -join " "
            return [pscustomobject]$result
        }

        $identity = ($json | Out-String) | ConvertFrom-Json
        $result.Status = "ok"
        $result.Account = $identity.Account
        $result.Arn = $identity.Arn
    }
    catch {
        $result.Status = "error"
        $result.Detail = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Show-Help {
    Write-Host @"
aws-sso.ps1 - helper AWS SSO (multi-perfil)

Uso:
  .\scripts\aws-sso.ps1 list
  .\scripts\aws-sso.ps1 status
  .\scripts\aws-sso.ps1 login [-Profiles p1,p2] [-All]
  .\scripts\aws-sso.ps1 use NOMBRE_PERFIL
  .\scripts\aws-sso.ps1 db-tunnel [-Environment dev|qa|prd] [-DbEngine postgres|sqlserver] [-LocalPort N] [-AwsProfile P]
  .\scripts\aws-sso.ps1 menu
  .\scripts\aws-sso.ps1 discover [-Environment dev|qa|prd] [-AwsProfile P]
  .\scripts\aws-sso.ps1 targets [-Environment dev|qa|prd]
  .\scripts\aws-sso.ps1 sql-console [-Environment dev|qa|prd] [-AwsProfile P] [-LocalPort N]
  .\scripts\aws-sso.ps1 migrate-setup [-Environment dev|qa|prd] [-AwsProfile P]

Ejemplos:
  .\scripts\aws-sso.ps1 list
  .\scripts\aws-sso.ps1 login -Profiles bayco_cl_dev,sso-standard-user-490184323245
  .\scripts\aws-sso.ps1 login -All
  .\scripts\aws-sso.ps1 use bayco_cl_dev
  .\scripts\aws-sso.ps1 db-tunnel -Environment dev -DbEngine postgres -LocalPort 5432
  .\scripts\aws-sso.ps1 menu
  .\scripts\aws-sso.ps1 discover -Environment qa -AwsProfile tu-perfil-qa
  .\scripts\aws-sso.ps1 targets -Environment prd
  .\scripts\aws-sso.ps1 sql-console -Environment prd -AwsProfile tu-perfil-prd
  .\scripts\aws-sso.ps1 migrate-setup -Environment dev -AwsProfile tu-perfil-dev

Notas:
  - use setea AWS_PROFILE solo en la sesion actual de PowerShell.
  - Para persistir en la sesion: . .\scripts\aws-sso.ps1 use bayco_cl_dev
  - db-tunnel requiere Session Manager Plugin:
    https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
  - Credenciales de DB no estan en este script; pedilas al equipo / Secrets Manager.
  - menu elige ambiente, perfil y motor de una lista y abre el tunnel en una ventana nueva,
    para poder tener varios tunnels en paralelo. Si el puerto sugerido esta ocupado
    busca uno libre automaticamente; si no encuentra ninguno, te lo pide.
  - discover busca instancias SSM online (bastions) y bases RDS del perfil elegido,
    prueba conectividad TCP real desde el bastion hacia cada base, y guarda las
    alcanzables en aws-sso.targets.json (junto al script). db-tunnel y menu leen
    ese archivo automaticamente si existe, sin tocar el codigo del script.
  - sql-console abre el tunnel SSM a SQL Server en segundo plano (sin ventana nueva),
    pide usuario/password de la base, y te deja tirar queries SELECT/WITH directo
    desde la terminal. Es solo lectura: bloquea INSERT/UPDATE/DELETE/DROP/etc.
    Pensado para cuando SSMS u otras GUI no pueden conectar (ej. bloqueo de EDR).
    Escribi 'exit' para salir; el tunnel se cierra solo al terminar.
  - migrate-setup arma perfiles para migrate-cli (../migrate-cli/.profiles.json):
    abre tunnel a una base descubierta (origen), pide usuario/password, y guarda
    el perfil de origen. Para destino te deja elegir uno ya guardado (ej. bases
    locales) o crear uno nuevo. Al final imprime el comando node migrate.js listo
    para copiar. A diferencia de sql-console, el tunnel NO se cierra solo (queda
    corriendo para que migrate-cli lo use) - el comando te muestra como cerrarlo.
"@
}

function Invoke-List {
    $profiles = Get-AwsConfigProfiles
    if ($profiles.Count -eq 0) {
        Write-WarnLine "No se encontraron perfiles SSO en $AwsConfigPath"
        return
    }

    Write-Info "Perfiles SSO en $AwsConfigPath"
    $profiles | ForEach-Object {
        [pscustomobject]@{
            Profile = $_.Name
            Account = $_.SsoAccountId
            Role    = $_.SsoRoleName
            Session = $_.SsoSession
            Region  = $_.Region
        }
    } | Format-Table -AutoSize
}

function Invoke-Status {
    $profiles = Get-AwsConfigProfiles
    if ($profiles.Count -eq 0) {
        Write-WarnLine "No se encontraron perfiles SSO."
        return
    }

    Write-Info "Estado de autenticacion SSO"
    $rows = foreach ($p in $profiles) {
        $s = Get-ProfileAuthStatus -Name $p.Name
        [pscustomobject]@{
            Profile = $s.Name
            Status  = $s.Status
            Account = $s.Account
            Arn     = $s.Arn
        }
    }
    $rows | Format-Table -AutoSize

    if ($env:AWS_PROFILE) {
        Write-Ok ("AWS_PROFILE actual: {0}" -f $env:AWS_PROFILE)
    }
    else {
        Write-WarnLine "AWS_PROFILE no esta seteado en esta sesion."
    }
}

function Resolve-LoginTargets {
    if ($All) {
        return @(Get-AwsConfigProfiles | ForEach-Object { $_.Name })
    }

    $names = @()
    if ($Profiles) { $names += $Profiles }
    if ($ProfileName) { $names += $ProfileName }
    if ($names.Count -eq 0 -and $AwsProfile) { $names += $AwsProfile }

    $names = $names | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
    if ($names.Count -eq 0) {
        throw "Indica -Profiles, un nombre de perfil, o -All."
    }
    return @($names)
}

function Invoke-Login {
    $targets = Resolve-LoginTargets
    Write-Info ("Login SSO para: {0}" -f ($targets -join ", "))
    Write-Host "Se abrira el navegador (Bayer SSO). Autoriza cada sesion si te lo pide." -ForegroundColor DarkGray

    $config = Get-AwsConfigProfiles
    $bySession = @{}
    $noSession = @()

    foreach ($name in $targets) {
        $meta = $config | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($meta -and $meta.SsoSession) {
            if (-not $bySession.ContainsKey($meta.SsoSession)) {
                $bySession[$meta.SsoSession] = New-Object System.Collections.Generic.List[string]
            }
            [void]$bySession[$meta.SsoSession].Add($name)
        }
        else {
            $noSession += $name
        }
    }

    foreach ($session in @($bySession.Keys)) {
        $first = $bySession[$session][0]
        Write-Info ("-> aws sso login --profile {0}  (session: {1})" -f $first, $session)
        & aws sso login --profile $first
        if ($LASTEXITCODE -ne 0) {
            Write-ErrLine ("Fallo login para {0}" -f $first)
            continue
        }
        $covered = $bySession[$session] -join ", "
        Write-Ok ("OK session '{0}' (cubre: {1})" -f $session, $covered)

        foreach ($name in @($bySession[$session])) {
            $s = Get-ProfileAuthStatus -Name $name
            if ($s.Status -eq "ok") {
                Write-Ok ("  [ok] {0}  account={1}" -f $name, $s.Account)
            }
            else {
                Write-WarnLine ("  [{0}] {1} - puede requerir login propio" -f $s.Status, $name)
                & aws sso login --profile $name
            }
        }
    }

    foreach ($name in $noSession) {
        Write-Info ("-> aws sso login --profile {0}" -f $name)
        & aws sso login --profile $name
        if ($LASTEXITCODE -eq 0) {
            Write-Ok ("OK {0}" -f $name)
        }
        else {
            Write-ErrLine ("Fallo {0}" -f $name)
        }
    }
}

function Invoke-Use {
    $name = $null
    if ($ProfileName) { $name = $ProfileName }
    elseif ($Profiles) { $name = $Profiles[0] }

    if (-not $name) {
        throw "Uso: .\scripts\aws-sso.ps1 use NOMBRE_PERFIL"
    }

    $known = @(Get-AwsConfigProfiles | ForEach-Object { $_.Name })
    if ($known -notcontains $name) {
        Write-WarnLine ("Perfil '{0}' no aparece como SSO en config; se setea igual." -f $name)
    }

    $env:AWS_PROFILE = $name
    Write-Ok ("AWS_PROFILE={0} (solo esta sesion de PowerShell)" -f $name)

    if (-not $script:IsDotSourced) {
        Write-Host ""
        Write-WarnLine "Si corriste el script sin dot-source, el cambio no queda en tu shell."
        Write-Host "Para persistir en la sesion actual, ejecuta:" -ForegroundColor DarkGray
        Write-Host ("  `$env:AWS_PROFILE = '{0}'" -f $name) -ForegroundColor White
        Write-Host "o:" -ForegroundColor DarkGray
        Write-Host ("  . .\scripts\aws-sso.ps1 use {0}" -f $name) -ForegroundColor White
    }

    $s = Get-ProfileAuthStatus -Name $name
    if ($s.Status -eq "ok") {
        Write-Ok ("Sesion valida: {0}" -f $s.Arn)
    }
    else {
        Write-WarnLine ("Perfil no autenticado ({0}). Corre: .\scripts\aws-sso.ps1 login -Profiles {1}" -f $s.Status, $name)
    }
}

function Test-SessionManagerPlugin {
    if (Get-Command session-manager-plugin -ErrorAction SilentlyContinue) {
        return $true
    }
    $defaultPath = "C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe"
    return (Test-Path -Path $defaultPath)
}

function Test-LocalPortFree {
    param(
        [Parameter(Mandatory)][int]$Port,
        [switch]$Quiet
    )

    $conns = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $conns) { return $true }

    if (-not $Quiet) {
        $procNames = $conns |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object {
                $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
                if ($p) { "{0} (PID {1})" -f $p.ProcessName, $p.Id } else { "PID $_" }
            }
        Write-ErrLine ("El puerto local {0} ya esta en uso: {1}" -f $Port, ($procNames -join ", "))
    }
    return $false
}

function Resolve-LocalPort {
    param(
        [Parameter(Mandatory)][int]$RequestedPort,
        [int]$MaxAttempts = 20
    )

    if (Test-LocalPortFree -Port $RequestedPort -Quiet) {
        return $RequestedPort
    }

    Write-WarnLine ("Puerto {0} ocupado, buscando uno libre..." -f $RequestedPort)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $candidate = $RequestedPort + $i
        if ($candidate -gt 65535) { break }
        if (Test-LocalPortFree -Port $candidate -Quiet) {
            Write-Ok ("Puerto {0} ocupado -> usando {1}." -f $RequestedPort, $candidate)
            return $candidate
        }
    }

    Write-ErrLine ("No se encontro un puerto libre cerca de {0}." -f $RequestedPort)
    while ($true) {
        $manual = Read-Host "Indica un puerto local libre a usar (o 'q' para cancelar)"
        if ($manual -eq 'q') { throw "Cancelado por el usuario: no se eligio puerto." }

        $portNum = 0
        if (-not [int]::TryParse($manual, [ref]$portNum) -or $portNum -le 0 -or $portNum -gt 65535) {
            Write-ErrLine "Puerto invalido, indica un numero entre 1 y 65535."
            continue
        }
        if (Test-LocalPortFree -Port $portNum -Quiet) {
            return $portNum
        }
        Write-ErrLine ("Puerto {0} tambien esta ocupado." -f $portNum)
    }
}

function Invoke-DbTunnel {
    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }
    if (-not $AwsProfile -or [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $AwsProfile = Select-AwsProfile
    }
    Set-DevTargetsFromConfig -EnvName $Environment

    if (-not $DbEngine -or [string]::IsNullOrWhiteSpace($DbEngine)) {
        $DbEngine = Select-DbEngine
    }

    if (-not $DevTargets.ContainsKey($DbEngine)) {
        throw ("DbEngine '{0}' desconocido. Disponibles: {1}. Corre 'discover' si esperabas verlo aca." -f $DbEngine, (($DevTargets.Keys | Sort-Object) -join ", "))
    }

    if (-not (Test-SessionManagerPlugin)) {
        Write-ErrLine "Falta Session Manager Plugin (necesario para el tunnel SSM)."
        Write-Host "Instalacion: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
        Write-Host "Luego reinicia la terminal y vuelve a intentar."
        exit 1
    }

    $auth = Get-ProfileAuthStatus -Name $AwsProfile
    if ($auth.Status -ne "ok") {
        Write-WarnLine ("Perfil '{0}' no autenticado. Iniciando login..." -f $AwsProfile)
        & aws sso login --profile $AwsProfile
        if ($LASTEXITCODE -ne 0) {
            throw ("No se pudo autenticar {0}" -f $AwsProfile)
        }
    }

    $LocalPort = Resolve-LocalPort -RequestedPort $LocalPort

    $target = $DevTargets[$DbEngine]

    # PowerShell strips quotes from ConvertTo-Json when calling native exes.
    # Write JSON to a temp file and pass file:// so AWS CLI gets valid JSON.
    $paramsJson = @"
{"host":["$($target.Host)"],"portNumber":["$($target.Port)"],"localPortNumber":["$LocalPort"]}
"@.Trim()
    $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("aws-sso-tunnel-{0}.json" -f [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($paramsFile, $paramsJson)

    Write-Info ("Tunnel {0} ({1}) via bastion {2}" -f $Environment.ToUpper(), $DbEngine, $BastionId)
    Write-Host ("  {0}" -f $target.Note)
    Write-Host ("  Remoto : {0}:{1}" -f $target.Host, $target.Port)
    Write-Host ("  Local  : localhost:{0}" -f $LocalPort)
    Write-Host ("  Catalog: {0}" -f $target.Catalog)
    Write-Host ("  Profile: {0}" -f $AwsProfile)
    Write-WarnLine "Deja esta ventana abierta. Conecta tu cliente a localhost:$LocalPort"
    Write-Host "Credenciales: Secrets Manager / equipo (no incluidas en este script)." -ForegroundColor DarkGray
    Write-Host ""

    try {
        & aws ssm start-session `
            --profile $AwsProfile `
            --region us-east-1 `
            --target $BastionId `
            --document-name AWS-StartPortForwardingSessionToRemoteHost `
            --parameters ("file://{0}" -f $paramsFile)
    }
    finally {
        Remove-Item -LiteralPath $paramsFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Count
    )

    while ($true) {
        $sel = Read-Host $Prompt
        if ($sel -eq 'q') { return $null }

        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Count) {
            return ($n - 1)
        }
        Write-ErrLine "Opcion invalida."
    }
}

function Invoke-Menu {
    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }
    else {
        $availableEnvs = Get-AvailableEnvironments
        if ($availableEnvs.Count -gt 0 -and $availableEnvs -notcontains $Environment) {
            Write-WarnLine ("Ambiente '{0}' no existe. Selecciono otro ambiente." -f $Environment)
            $Environment = Select-Environment
            $script:Environment = $Environment
        }
    }

    Set-DevTargetsFromConfig -EnvName $Environment
    Write-Info ("Ambiente: {0}" -f $Environment)

    $profiles = Get-AwsConfigProfiles
    if ($profiles.Count -eq 0) {
        Write-WarnLine "No se encontraron perfiles SSO en $AwsConfigPath"
        return
    }

    Write-Info "Perfiles disponibles:"
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        Write-Host ("  [{0}] {1}  (cuenta {2}, rol {3})" -f ($i + 1), $p.Name, $p.SsoAccountId, $p.SsoRoleName)
    }

    $profileIndex = Read-MenuChoice -Prompt "Elegi un perfil (numero, o 'q' para salir)" -Count $profiles.Count
    if ($null -eq $profileIndex) { return }
    $chosenProfile = $profiles[$profileIndex].Name

    $engines = @($DevTargets.Keys | Sort-Object)
    Write-Info "Motor de base de datos:"
    for ($i = 0; $i -lt $engines.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $engines[$i], $DevTargets[$engines[$i]].Note)
    }

    $engineIndex = Read-MenuChoice -Prompt "Elegi un motor (numero, o 'q' para salir)" -Count $engines.Count
    if ($null -eq $engineIndex) { return }
    $chosenEngine = $engines[$engineIndex]

    $suggestedPort = $DevTargets[$chosenEngine].Port
    $portInput = Read-Host ("Puerto local [{0}] (Enter para aceptar, o escribi otro)" -f $suggestedPort)
    $requestedPort = $suggestedPort
    if ($portInput -and $portInput.Trim()) {
        $parsedPort = 0
        if ([int]::TryParse($portInput.Trim(), [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -le 65535) {
            $requestedPort = $parsedPort
        }
        else {
            Write-WarnLine ("Puerto invalido '{0}', uso el sugerido {1}." -f $portInput, $suggestedPort)
        }
    }
    $portToUse = Resolve-LocalPort -RequestedPort $requestedPort

    $scriptPath = $PSCommandPath
    $argList = @(
        "-NoExit", "-File", $scriptPath,
        "db-tunnel",
        "-AwsProfile", $chosenProfile,
        "-DbEngine", $chosenEngine,
        "-LocalPort", $portToUse
    )

    Write-Ok ("Abriendo tunnel en una ventana nueva: perfil={0} engine={1} localPort={2}" -f $chosenProfile, $chosenEngine, $portToUse)
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList | Out-Null

    Write-Host ""
    Write-Info "Volve a correr 'menu' para abrir otro tunnel en paralelo (el puerto se resuelve solo si el sugerido ya esta en uso)."
}

function Wait-SsmCommandResult {
    param(
        [Parameter(Mandatory)][string]$CommandId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$Region = "us-east-1",
        [int]$MaxAttempts = 6
    )

    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        Start-Sleep -Seconds 2
        $r = Invoke-Aws ssm get-command-invocation --profile $AwsProfile --region $Region --command-id $CommandId --instance-id $InstanceId --output json
        if ($r.ExitCode -ne 0) { continue }
        $result = $r.Output | ConvertFrom-Json
        if ($result.Status -notin @("Pending", "InProgress")) { return $result }
    }
    return $null
}

function Test-BastionToHost {
    param(
        [Parameter(Mandatory)][string]$BastionInstanceId,
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [string]$Region = "us-east-1"
    )

    $check = "timeout 5 bash -c ""echo > /dev/tcp/{0}/{1}"" && echo TUNNEL_CHECK_OK || echo TUNNEL_CHECK_FAIL" -f $TargetHost, $TargetPort

    # Igual que en Invoke-DbTunnel: pasar JSON inline pierde las comillas al
    # invocar el exe nativo, y Set-Content -Encoding UTF8 agrega un BOM que
    # aws cli no tolera en --parameters file://. WriteAllText no agrega BOM.
    $escapedCheck = $check.Replace('"', '\"')
    $paramsJson = @"
{"commands":["$escapedCheck"]}
"@.Trim()
    $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("aws-sso-check-{0}.json" -f [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($paramsFile, $paramsJson)

    try {
        $send = Invoke-Aws ssm send-command --profile $AwsProfile --region $Region --instance-ids $BastionInstanceId --document-name "AWS-RunShellScript" --parameters ("file://{0}" -f $paramsFile) --query "Command.CommandId" --output text
        if ($send.ExitCode -ne 0) { return "error" }
        $cmdId = $send.Output.Trim()

        $result = Wait-SsmCommandResult -CommandId $cmdId -InstanceId $BastionInstanceId -Region $Region
        if ($null -eq $result -or $result.StandardOutputContent -notmatch "TUNNEL_CHECK_OK") { return "FAIL" }
        return "OK"
    }
    finally {
        Remove-Item -LiteralPath $paramsFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Discover {
    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }
    if (-not $AwsProfile -or [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $AwsProfile = Select-AwsProfile
    }

    Write-Info ("Buscando instancias SSM Online (perfil {0}, ambiente {1})..." -f $AwsProfile, $Environment)
    $region = "us-east-1"

    $onlineResp = Invoke-Aws ssm describe-instance-information --profile $AwsProfile --region $region --output json
    if ($onlineResp.ExitCode -ne 0) { throw ("No se pudo listar instancias SSM: {0}" -f $onlineResp.Output) }
    $online = $onlineResp.Output | ConvertFrom-Json
    $onlineIds = @($online.InstanceInformationList | Where-Object { $_.PingStatus -eq "Online" } | Select-Object -ExpandProperty InstanceId)

    if ($onlineIds.Count -eq 0) {
        Write-WarnLine "No hay instancias SSM Online en este perfil/region."
        return
    }

    $instancesResp = Invoke-Aws ec2 describe-instances --profile $AwsProfile --region $region --instance-ids @onlineIds `
        --query "Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key=='Name']|[0].Value,VpcId:VpcId}" --output json
    if ($instancesResp.ExitCode -ne 0) { throw ("No se pudo describir instancias EC2: {0}" -f $instancesResp.Output) }
    $instancesParsed = $instancesResp.Output | ConvertFrom-Json
    $instances = @($instancesParsed)

    Write-Info "Bastions candidatos (SSM Online):"
    for ($i = 0; $i -lt $instances.Count; $i++) {
        $b = $instances[$i]
        Write-Host ("  [{0}] {1}  {2}  vpc={3}" -f ($i + 1), $b.Id, $b.Name, $b.VpcId)
    }

    $bastionIndex = Read-MenuChoice -Prompt "Elegi el bastion a usar para el tunnel (numero, o 'q' para cancelar)" -Count $instances.Count
    if ($null -eq $bastionIndex) { return }
    $bastion = $instances[$bastionIndex]

    Write-Info "Buscando bases de datos RDS..."
    $clustersResp = Invoke-Aws rds describe-db-clusters --profile $AwsProfile --region $region `
        --query "DBClusters[].{Id:DBClusterIdentifier,Engine:Engine,Endpoint:Endpoint,Port:Port,Status:Status}" --output json
    if ($clustersResp.ExitCode -ne 0) { throw ("No se pudo describir DB clusters: {0}" -f $clustersResp.Output) }
    $clustersParsed = $clustersResp.Output | ConvertFrom-Json
    $clusters = @($clustersParsed)

    $dbInstancesResp = Invoke-Aws rds describe-db-instances --profile $AwsProfile --region $region `
        --query "DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Endpoint:Endpoint.Address,Port:Endpoint.Port,Status:DBInstanceStatus,ClusterId:DBClusterIdentifier}" --output json
    if ($dbInstancesResp.ExitCode -ne 0) { throw ("No se pudo describir DB instances: {0}" -f $dbInstancesResp.Output) }
    $dbInstancesParsed = $dbInstancesResp.Output | ConvertFrom-Json
    $dbInstances = @($dbInstancesParsed)

    $candidates = @()
    foreach ($c in $clusters) {
        $candidates += [pscustomobject]@{ Id = $c.Id; Engine = $c.Engine; Endpoint = $c.Endpoint; Port = $c.Port; Status = $c.Status }
    }
    foreach ($i in $dbInstances) {
        if ($i.ClusterId) { continue }
        $candidates += [pscustomobject]@{ Id = $i.Id; Engine = $i.Engine; Endpoint = $i.Endpoint; Port = $i.Port; Status = $i.Status }
    }

    if ($candidates.Count -eq 0) {
        Write-WarnLine "No se encontraron bases de datos RDS en este perfil/region."
        return
    }

    Write-Info ("Probando conectividad TCP desde {0} hacia cada base..." -f $bastion.Id)
    $rows = foreach ($t in $candidates) {
        if ($t.Status -ne "available") {
            [pscustomobject]@{ Id = $t.Id; Engine = $t.Engine; Endpoint = $t.Endpoint; Port = $t.Port; Reachable = ("skip ({0})" -f $t.Status) }
            continue
        }
        $reachable = Test-BastionToHost -BastionInstanceId $bastion.Id -TargetHost $t.Endpoint -TargetPort $t.Port -Region $region
        [pscustomobject]@{ Id = $t.Id; Engine = $t.Engine; Endpoint = $t.Endpoint; Port = $t.Port; Reachable = $reachable }
    }
    $rows | Format-Table -AutoSize -Wrap

    $engineMap = @{
        "aurora-postgresql" = "postgres"
        "postgres"          = "postgres"
        "sqlserver-se"      = "sqlserver"
        "sqlserver-ee"      = "sqlserver"
        "sqlserver-ex"      = "sqlserver"
        "sqlserver-web"     = "sqlserver"
    }

    $targetsOut = [ordered]@{}
    foreach ($r in ($rows | Where-Object { $_.Reachable -eq "OK" })) {
        $key = $engineMap[$r.Engine]
        if (-not $key) { $key = $r.Engine }
        $targetsOut[$key] = [ordered]@{
            Host    = $r.Endpoint
            Port    = $r.Port
            Catalog = $r.Id
            Note    = ("Auto-descubierto ({0}, {1})" -f $r.Id, $r.Engine)
        }
    }

    if ($targetsOut.Count -eq 0) {
        Write-WarnLine "Ninguna base resulto alcanzable desde el bastion elegido; no se guardo nada."
        return
    }

    $newEnv = [ordered]@{ BastionId = $bastion.Id; Targets = $targetsOut }

    $existing = $null
    if ($discovered) {
        $existing = $discovered
    }
    else {
        $existing = [ordered]@{}
    }

    if (-not $existing.Environments) {
        $existing.Environments = [ordered]@{}
    }
    $existing.Environments[$Environment] = $newEnv

    $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $TargetsFile -Encoding UTF8

    Write-Ok ("Guardado en {0}" -f $TargetsFile)
    Write-Host "db-tunnel y menu van a usar estos accesos automaticamente de ahora en mas." -ForegroundColor DarkGray
}

function Save-TargetsConfig {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][hashtable]$EnvConfig
    )

    $existing = if ($discovered) { $discovered } else { [ordered]@{} }
    if (-not $existing.Environments) { $existing.Environments = [ordered]@{} }
    $existing.Environments[$EnvName] = $EnvConfig
    $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $TargetsFile -Encoding UTF8
    $script:discovered = $existing
}

function Invoke-Targets {
    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }

    if (-not (Test-Path -Path $TargetsFile)) {
        $discovered = [ordered]@{}
    }
    else {
        try {
            $discovered = Get-Content -Raw -Path $TargetsFile | ConvertFrom-Json
        }
        catch {
            Write-WarnLine ("No se pudo leer {0}: {1}" -f $TargetsFile, $_.Exception.Message)
            return
        }
    }

    $env = $Environment
    $envNames = @()
    if ($discovered -and $discovered.Environments) {
        $envNames = @($discovered.Environments.PSObject.Properties.Name)
    }

    if (-not $envNames -contains $env) {
        if ($envNames.Count -gt 0) {
            Write-WarnLine ("Ambiente '{0}' no encontrado en {1}." -f $env, $TargetsFile)
        }
        else {
            Write-Info "No se encontro ningun ambiente en {0}. Creando ambiente '{1}'." -f $TargetsFile, $env
        }
        $create = Read-HostOrDefault -Prompt ("Querés crear el ambiente '{0}'? (s/n)" -f $env) -Default "s"
        if ($create -notmatch '^(s|si|y|yes)$') {
            Write-WarnLine "Operacion cancelada."
            return
        }
        $envNames += $env
        if (-not $discovered.Environments) { $discovered.Environments = [ordered]@{} }
        $discovered.Environments[$env] = [ordered]@{ BastionId = ""; Targets = [ordered]@{} }
    }

    $envConfig = $discovered.Environments.$env
    Write-Info ("Ambiente: {0}" -f $env)
    Write-Host ("  BastionId: {0}" -f $envConfig.BastionId)

    if ($envConfig.Targets) {
        Write-Info "Targets actuales:"
        foreach ($key in $envConfig.Targets.PSObject.Properties.Name) {
            $t = $envConfig.Targets.$key
            Write-Host ("  {0}: {1}:{2} ({3})" -f $key, $t.Host, $t.Port, $t.Note)
        }
    }
    else {
        Write-WarnLine "No hay targets configurados en este ambiente."
    }

    $ans = Read-HostOrDefault -Prompt ("Querés agregar un target nuevo a {0}? (s/n)" -f $env) -Default "s"
    if ($ans -notmatch '^(s|si|y|yes)$') {
        Write-Info "No se agrego ningun target."
        return
    }

    $targetName = Read-Host "Nombre de target (ej. postgres, sqlserver, postgres-prod)"
    if ([string]::IsNullOrWhiteSpace($targetName)) {
        Write-ErrLine "Nombre de target invalido."
        return
    }
    $targetName = $targetName.Trim()

    $host = Read-Host "Host del target"
    $port = Read-HostOrDefault -Prompt "Puerto (5432/1433)" -Default "5432"
    if (-not [int]::TryParse($port, [ref]$null)) {
        Write-ErrLine "Puerto invalido."
        return
    }
    $catalog = Read-HostOrDefault -Prompt "Catalog / nombre de base" -Default ""
    $note = Read-HostOrDefault -Prompt "Nota opcional" -Default ""

    $envConfig.Targets[$targetName] = [ordered]@{
        Host    = $host
        Port    = [int]$port
        Catalog = $catalog
        Note    = $note
    }

    if (-not $envConfig.BastionId) {
        $envConfig.BastionId = Read-HostOrDefault -Prompt "BastionId para este ambiente" -Default ""
    }

    Save-TargetsConfig -EnvName $env -EnvConfig $envConfig
    Write-Ok ("Target '{0}' agregado a ambiente '{1}'." -f $targetName, $env)
}

function Wait-LocalPortListening {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 25
    )

    $deadline = [DateTime]::Now.AddSeconds($TimeoutSeconds)
    while ([DateTime]::Now -lt $deadline) {
        if (-not (Test-LocalPortFree -Port $Port -Quiet)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Show-SqlConsoleHelp {
    Write-Host @"
Comandos:
  tables               - listar tablas de la base actual
  describe <tabla>     - columnas de una tabla
  count <tabla>        - cantidad de filas de una tabla
  databases            - listar bases del servidor
  <SELECT / WITH ...>  - cualquier query de lectura
  help                 - este mensaje
  exit                 - salir (cierra el tunel)
"@
}

function Get-SafeTableIdentifier {
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][string]$TableName
    )
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP 1 QUOTENAME(s.name) + '.' + QUOTENAME(t.name) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = @name"
    [void]$cmd.Parameters.AddWithValue("@name", $TableName)
    $result = $cmd.ExecuteScalar()
    if ($result -is [string]) { return $result }
    return $null
}

function Invoke-ReadOnlyQuery {
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][string]$Sql
    )
    try {
        $cmd = $Conn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 30
        $reader = $cmd.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)
        if ($table.Rows.Count -eq 0) {
            Write-Host "(sin resultados)"
        }
        else {
            $table | Format-Table -AutoSize
        }
    }
    catch {
        Write-ErrLine $_.Exception.Message
    }
}

function Invoke-SqlConsole {
    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }
    Set-DevTargetsFromConfig -EnvName $Environment

    if (-not $DevTargets.ContainsKey("sqlserver")) {
        Write-WarnLine ("El ambiente '{0}' no tiene un target 'sqlserver' configurado." -f $Environment)
        $create = Read-HostOrDefault -Prompt "Querés crear/editar los targets de este ambiente ahora? (s/n)" -Default "s"
        if ($create -match '^(s|si|y|yes)$') {
            Invoke-Targets
            Set-DevTargetsFromConfig -EnvName $Environment
        }
        if (-not $DevTargets.ContainsKey("sqlserver")) {
            throw "No hay target 'sqlserver' configurado."
        }
    }
    if (-not (Test-SessionManagerPlugin)) {
        Write-ErrLine "Falta Session Manager Plugin (necesario para el tunnel SSM)."
        exit 1
    }

    $chosenProfile = $AwsProfile
    if (-not $PSBoundParameters.ContainsKey('AwsProfile') -or -not $chosenProfile -or [string]::IsNullOrWhiteSpace($chosenProfile)) {
        $chosenProfile = Select-AwsProfile
    }
    Set-PersistedProfile -ProfileName $chosenProfile

    Write-Info ("Perfil: {0}" -f $chosenProfile)
    $auth = Get-ProfileAuthStatus -Name $chosenProfile
    if ($auth.Status -ne "ok") {
        Write-WarnLine ("Perfil '{0}' no autenticado. Iniciando login..." -f $chosenProfile)
        & aws sso login --profile $chosenProfile
        if ($LASTEXITCODE -ne 0) { throw ("No se pudo autenticar {0}" -f $chosenProfile) }
    }

    $target = $DevTargets["sqlserver"]
    $requestedPort = if ($PSBoundParameters.ContainsKey('LocalPort')) { $LocalPort } else { $target.Port }
    $port = Resolve-LocalPort -RequestedPort $requestedPort

    $scriptPath = $PSCommandPath
    Write-Info ("Abriendo tunnel SSM en segundo plano hacia SQL Server (localhost:{0})..." -f $port)
    $tunnelProc = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile", "-File", $scriptPath,
        "db-tunnel", "-Environment", $Environment, "-AwsProfile", $chosenProfile, "-DbEngine", "sqlserver", "-LocalPort", $port
    )

    $conn = $null
    try {
        # El tunnel ya esta levantando en segundo plano (Start-Process de arriba).
        # Pedimos las credenciales en paralelo a eso para no perder tiempo, y
        # recien despues chequeamos que el puerto local ya este escuchando.
        $sqlUser = Read-Host "Usuario SQL Server"
        $securePw = Read-Host "Password" -AsSecureString
        $sqlPw = [System.Net.NetworkCredential]::new("", $securePw).Password

        Write-Info "Verificando que el tunnel este disponible..."
        if (-not (Wait-LocalPortListening -Port $port)) {
            throw "El tunnel no llego a levantar el puerto local a tiempo."
        }
        Write-Ok ("Tunnel listo en localhost:{0}." -f $port)

        Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
        $baseCs = "Server=127.0.0.1,{0};User Id={1};Password={2};TrustServerCertificate=True;Connection Timeout=10" `
            -f $port, $sqlUser, $sqlPw
        $conn = New-Object System.Data.SqlClient.SqlConnection

        try {
            $conn.ConnectionString = "$baseCs;Database=$($target.Catalog)"
            $conn.Open()
        }
        catch {
            # discover no puede saber el nombre real de la base (la API de RDS solo
            # expone el identificador de instancia/cluster) - conecta a master y deja
            # elegir de la lista real de bases del servidor.
            Write-WarnLine ("No se pudo abrir la base '{0}': {1}" -f $target.Catalog, $_.Exception.Message)
            Write-Info "Conectando a 'master' para listar las bases reales..."
            $conn.ConnectionString = "$baseCs;Database=master"
            $conn.Open()

            $listCmd = $conn.CreateCommand()
            $listCmd.CommandText = "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"
            $listReader = $listCmd.ExecuteReader()
            $dbNames = @()
            while ($listReader.Read()) { $dbNames += $listReader.GetString(0) }
            $listReader.Close()

            if ($dbNames.Count -gt 0) {
                Write-Info "Bases disponibles en el servidor:"
                for ($i = 0; $i -lt $dbNames.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $dbNames[$i]) }
                $dbIndex = Read-MenuChoice -Prompt "Elegi una base (numero, o 'q' para quedarte en master)" -Count $dbNames.Count
                if ($null -ne $dbIndex) { $conn.ChangeDatabase($dbNames[$dbIndex]) }
            }
        }

        Write-Ok ("Conectado a {0} / base: {1} (solo lectura)." -f $target.Host, $conn.Database)
        Show-SqlConsoleHelp

        $forbidden = 'INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|EXEC(UTE)?|MERGE|CREATE|GRANT|REVOKE|sp_'

        while ($true) {
            $sql = Read-Host "SQL"
            if ([string]::IsNullOrWhiteSpace($sql)) { continue }
            $trimmed = $sql.Trim()

            if ($trimmed -in @("exit", "quit", "q")) { break }
            if ($trimmed -eq "help") { Show-SqlConsoleHelp; continue }

            if ($trimmed -eq "tables") {
                Invoke-ReadOnlyQuery -Conn $conn -Sql "SELECT s.name AS schema_name, t.name AS table_name FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id ORDER BY s.name, t.name"
                continue
            }
            if ($trimmed -eq "databases") {
                Invoke-ReadOnlyQuery -Conn $conn -Sql "SELECT name, state_desc FROM sys.databases ORDER BY name"
                continue
            }
            if ($trimmed -match '^(describe|count)\s+(\S+)$') {
                $action = $Matches[1]
                $tableArg = $Matches[2]
                $safeIdent = Get-SafeTableIdentifier -Conn $conn -TableName $tableArg
                if (-not $safeIdent) {
                    Write-ErrLine ("No se encontro la tabla '{0}' en la base actual." -f $tableArg)
                    continue
                }
                if ($action -eq "count") {
                    Invoke-ReadOnlyQuery -Conn $conn -Sql ("SELECT COUNT(*) AS row_count FROM {0}" -f $safeIdent)
                }
                else {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @t ORDER BY ORDINAL_POSITION"
                    [void]$cmd.Parameters.AddWithValue("@t", $tableArg)
                    try {
                        $reader = $cmd.ExecuteReader()
                        $table = New-Object System.Data.DataTable
                        $table.Load($reader)
                        $table | Format-Table -AutoSize
                    }
                    catch {
                        Write-ErrLine $_.Exception.Message
                    }
                }
                continue
            }

            if ($trimmed -notmatch '^\s*(SELECT|WITH)\b') {
                Write-ErrLine "No reconocido. Escribi 'help' para ver los comandos disponibles."
                continue
            }
            if ($trimmed -match $forbidden) {
                Write-ErrLine "Query bloqueada: contiene una palabra clave no permitida en modo solo lectura."
                continue
            }

            Invoke-ReadOnlyQuery -Conn $conn -Sql $trimmed
        }
    }
    finally {
        if ($conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) {
            $conn.Close()
        }
        Write-Info "Cerrando tunnel..."
        if ($tunnelProc -and -not $tunnelProc.HasExited) {
            & taskkill /PID $tunnelProc.Id /T /F 2>&1 | Out-Null
        }
    }
}

function Read-HostOrDefault {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = "")
    $val = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function Get-MigrateCliProfilesPath {
    Join-Path $PSScriptRoot "migrate-cli\.profiles.json"
}

function Get-MigrateCliProfiles {
    $path = Get-MigrateCliProfilesPath
    $result = [ordered]@{}
    if (-not (Test-Path -Path $path)) { return $result }
    try {
        $raw = Get-Content -Raw -Path $path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $obj = $raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $result[$p.Name] = $p.Value }
    }
    catch {
        Write-WarnLine ("No se pudo leer {0}: {1}" -f $path, $_.Exception.Message)
    }
    return $result
}

function Save-MigrateCliProfile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Profile
    )
    $path = Get-MigrateCliProfilesPath
    $existing = Get-MigrateCliProfiles
    $merged = [ordered]@{}
    foreach ($key in $existing.Keys) { $merged[$key] = $existing[$key] }
    $merged[$Name] = $Profile
    [System.IO.File]::WriteAllText($path, ($merged | ConvertTo-Json -Depth 5))
}

function Invoke-MigrateSetup {
    $migrateDir = Split-Path (Get-MigrateCliProfilesPath) -Parent
    if (-not (Test-Path -Path $migrateDir)) {
        throw ("No se encontro migrate-cli en {0}" -f $migrateDir)
    }

    if (-not $Environment -or [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = Select-Environment
        $script:Environment = $Environment
    }
    Set-DevTargetsFromConfig -EnvName $Environment

    if (-not $AwsProfile -or [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $AwsProfile = Select-AwsProfile
    }

    Write-Info "=== Origen (se conecta via tunnel SSM a una base de las descubiertas) ==="
    $engines = @($DevTargets.Keys | Sort-Object)
    for ($i = 0; $i -lt $engines.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $engines[$i], $DevTargets[$engines[$i]].Note)
    }
    $engIndex = Read-MenuChoice -Prompt "Elegi el motor de origen (numero, o 'q' para cancelar)" -Count $engines.Count
    if ($null -eq $engIndex) { return }
    $srcEngine = $engines[$engIndex]
    $target = $DevTargets[$srcEngine]

    $auth = Get-ProfileAuthStatus -Name $AwsProfile
    if ($auth.Status -ne "ok") {
        Write-WarnLine ("Perfil '{0}' no autenticado. Iniciando login..." -f $AwsProfile)
        & aws sso login --profile $AwsProfile
        if ($LASTEXITCODE -ne 0) { throw ("No se pudo autenticar {0}" -f $AwsProfile) }
    }

    $requestedPort = if ($PSBoundParameters.ContainsKey('LocalPort')) { $LocalPort } else { $target.Port }
    $port = Resolve-LocalPort -RequestedPort $requestedPort

    $scriptPath = $PSCommandPath
    Write-Info ("Abriendo tunnel SSM en segundo plano ({0}, localhost:{1})..." -f $srcEngine, $port)
    $tunnelProc = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile", "-File", $scriptPath,
        "db-tunnel", "-Environment", $Environment, "-AwsProfile", $AwsProfile, "-DbEngine", $srcEngine, "-LocalPort", $port
    )
    Write-Host ("Este tunnel NO se cierra al terminar (PID {0}) - migrate-cli lo necesita corriendo. Cerralo con: Stop-Process -Id {0} -Force" -f $tunnelProc.Id) -ForegroundColor DarkGray

    # Credenciales en paralelo a que el tunnel termine de levantar.
    $srcUser = Read-Host "Usuario origen"
    $secureSrcPw = Read-Host "Password origen" -AsSecureString
    $srcPw = [System.Net.NetworkCredential]::new("", $secureSrcPw).Password

    Write-Info "Verificando que el tunnel este disponible..."
    if (-not (Wait-LocalPortListening -Port $port)) {
        throw "El tunnel no llego a levantar el puerto local a tiempo."
    }
    Write-Ok ("Tunnel listo en localhost:{0}." -f $port)

    $srcDb = Read-HostOrDefault -Prompt "Base de datos origen" -Default $target.Catalog
    $srcProfileName = Read-HostOrDefault -Prompt "Nombre para el perfil de ORIGEN en migrate-cli" -Default ("aws-{0}" -f $srcEngine)

    $srcProfile = [ordered]@{
        server   = ("localhost,{0}" -f $port)
        db       = $srcDb
        auth     = "sql"
        user     = $srcUser
        password = $srcPw
        engine   = $srcEngine
    }
    if ($srcEngine -eq "postgres") {
        # RDS/Aurora Postgres exige SSL; sin esto migrate-cli falla con
        # "no pg_hba.conf entry ... no encryption" aunque las credenciales esten bien.
        $srcProfile.ssl = $true
    }
    Save-MigrateCliProfile -Name $srcProfileName -Profile $srcProfile
    Write-Ok ("Perfil de origen '{0}' guardado en {1}" -f $srcProfileName, (Get-MigrateCliProfilesPath))

    Write-Host ""
    Write-Info "=== Destino ==="
    $existingProfiles = Get-MigrateCliProfiles
    $destKeys = @($existingProfiles.Keys | Sort-Object)

    if ($destKeys.Count -gt 0) {
        Write-Info "Perfiles ya guardados en migrate-cli:"
        for ($i = 0; $i -lt $destKeys.Count; $i++) {
            $dp = $existingProfiles[$destKeys[$i]]
            Write-Host ("  [{0}] {1}  ({2}, {3} / {4})" -f ($i + 1), $destKeys[$i], $dp.engine, $dp.server, $dp.db)
        }
    }
    $newOptionIndex = $destKeys.Count + 1
    Write-Host ("  [{0}] Crear un perfil de destino nuevo" -f $newOptionIndex)

    $dstChoice = Read-MenuChoice -Prompt "Elegi destino (numero, o 'q' para saltear este paso)" -Count $newOptionIndex
    $dstProfileName = $null

    if ($null -ne $dstChoice) {
        if ($dstChoice -eq $destKeys.Count) {
            $dstEngineSel = Read-HostOrDefault -Prompt "Motor destino (sqlserver/postgres)" -Default "sqlserver"
            $dstServer = Read-Host "Server destino (host, o host,puerto, o host\instancia)"
            $dstDb = Read-Host "Base de datos destino"
            $dstAuthSel = "sql"
            if ($dstEngineSel -eq "sqlserver") {
                $dstAuthSel = Read-HostOrDefault -Prompt "Auth destino (sql/windows)" -Default "sql"
            }
            $dstProfile = [ordered]@{ server = $dstServer; db = $dstDb; auth = $dstAuthSel; engine = $dstEngineSel }
            if ($dstAuthSel -eq "sql") {
                $dstProfile.user = Read-Host "Usuario destino"
                $secureDstPw = Read-Host "Password destino" -AsSecureString
                $dstProfile.password = [System.Net.NetworkCredential]::new("", $secureDstPw).Password
            }
            if ($dstEngineSel -eq "postgres") {
                $dstSslAns = Read-HostOrDefault -Prompt "Requiere SSL el destino? (RDS/Aurora = s, Postgres local = n)" -Default "n"
                $dstProfile.ssl = ($dstSslAns -match '^(s|si|y|yes)$')
            }
            $dstProfileName = Read-HostOrDefault -Prompt "Nombre para el perfil de DESTINO en migrate-cli" -Default "destino"
            Save-MigrateCliProfile -Name $dstProfileName -Profile $dstProfile
            Write-Ok ("Perfil de destino '{0}' guardado en {1}" -f $dstProfileName, (Get-MigrateCliProfilesPath))
        }
        else {
            $dstProfileName = $destKeys[$dstChoice]
            Write-Ok ("Usando perfil de destino existente: {0}" -f $dstProfileName)
        }
    }

    Write-Host ""
    Write-Ok "Listo. Comando de ejemplo para migrate-cli:"
    $dstArg = if ($dstProfileName) { $dstProfileName } else { "TU_DESTINO" }
    Write-Host ("  cd migrate-cli" ) -ForegroundColor White
    Write-Host ("  node migrate.js --src-profile {0} --dst-profile {1} --query ""SELECT * FROM dbo.TABLA"" --table ""dbo.TABLA""" -f $srcProfileName, $dstArg) -ForegroundColor White
    Write-Host ("  (o --all --src-profile {0} --dst-profile {1} para migrar toda la base)" -f $srcProfileName, $dstArg) -ForegroundColor DarkGray
    Write-WarnLine ("El tunnel SSM queda abierto en segundo plano (PID {0}) para que migrate-cli se conecte mientras trabajas. Cerralo cuando termines: Stop-Process -Id {0} -Force" -f $tunnelProc.Id)
}

Test-AwsCli

switch ($Command) {
    "list"        { Invoke-List }
    "status"      { Invoke-Status }
    "login"       { Invoke-Login }
    "use"         { Invoke-Use }
    "db-tunnel"   { Invoke-DbTunnel }
    "menu"        { Invoke-Menu }
    "discover"      { Invoke-Discover }
    "targets"     { Invoke-Targets }
    "sql-console"   { Invoke-SqlConsole }
    "migrate-setup" { Invoke-MigrateSetup }
    default         { Show-Help }
}
