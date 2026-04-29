#requires -Version 5.1
<#
Monopoly IKEv2 VPN Tool v2.2
Install / Remove / Diagnose Windows built-in IKEv2 EAP VPN profile.

Run from GitHub:
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/wannarocku/MonopolyStuff/main/windows/ikev2_mono_tool.ps1 | iex

Important:
- Installation/removal require elevated PowerShell.
- CA certificate is downloaded from:
  https://raw.githubusercontent.com/wannarocku/MonopolyStuff/main/ca/ca.cer
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

try { Add-Type -AssemblyName System.Security } catch {}
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch {}

# =========================
# Configuration
# =========================
$Script:Config = [ordered]@{
    VpnName          = 'ikev2_mono'
    VpnServer        = 'privet1.monopoly.su'
    DnsSuffix        = 'monopoly.su'
    LoginSuffix      = '@monopoly.su'
    TunnelType       = 'Ikev2'
    EncryptionLevel  = 'Required'
    SplitTunneling   = $true
    AllUser          = $true
    CaCertUrl        = 'https://raw.githubusercontent.com/wannarocku/MonopolyStuff/main/ca/ca.cer'
}

$Script:AllUserPbk = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$Script:UserPbk    = Join-Path $env:APPDATA     'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$Script:Results = New-Object System.Collections.Generic.List[object]
$Script:FixQueue = New-Object System.Collections.Generic.List[object]
$Script:AutoFixApplied = $false
$Script:CaFixNeeded = $false
$Script:LastReportPath = $null

# =========================
# Helpers
# =========================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-Result {
    param(
        [ValidateSet('OK','WARN','FAIL','INFO')][string]$Status,
        [string]$Check,
        [string]$Message,
        [string]$Details = ''
    )
    $obj = [pscustomobject]@{
        Time    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Status  = $Status
        Check   = $Check
        Message = $Message
        Details = $Details
    }
    $Script:Results.Add($obj) | Out-Null

    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host ("[{0}] {1}: {2}" -f $Status, $Check, $Message) -ForegroundColor $color
    if ($Details) { Write-Host ("      {0}" -f $Details) -ForegroundColor DarkGray }
}

function Clear-Results { $Script:Results.Clear(); $Script:FixQueue.Clear(); $Script:AutoFixApplied = $false; $Script:CaFixNeeded = $false }

function As-Array {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Add-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Title) -ForegroundColor Magenta
}

function Show-Summary {
    $fail = @($Script:Results | Where-Object Status -eq 'FAIL').Count
    $warn = @($Script:Results | Where-Object Status -eq 'WARN').Count

    if ($Script:AutoFixApplied) {
        Add-Result WARN 'Summary' 'Найдены проблемы, автоисправление выполнено' 'Запустите диагностику ещё раз для подтверждения результата.'
        return
    }

    if ($fail -gt 0) {
        Add-Result FAIL 'Summary' ("Проверка завершена: FAIL={0}, WARN={1}" -f $fail,$warn) 'Сначала устраните FAIL. WARN часто не блокирует подключение.'
    } elseif ($warn -gt 0) {
        Add-Result WARN 'Summary' ("Критичных проблем не найдено, но есть WARN={0}" -f $warn) 'Проверьте предупреждения.'
    } else {
        Add-Result OK 'Summary' 'Критичных проблем не найдено' ''
    }
}

function Export-Report {
    param([string]$Prefix = 'VPN_IKEv2_Diagnostic')
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $PWD.Path }
    $path = Join-Path $desktop "Monopoly_VPN_Diagnostic.txt"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Monopoly IKEv2 VPN diagnostic report') | Out-Null
    $lines.Add('IMPORTANT: this is the latest diagnostic report. The file is overwritten on every diagnostics run.') | Out-Null
    $lines.Add(('Generated: {0}' -f (Get-Date))) | Out-Null
    $lines.Add(('Computer: {0}' -f $env:COMPUTERNAME)) | Out-Null
    $lines.Add(('User: {0}\{1}' -f $env:USERDOMAIN,$env:USERNAME)) | Out-Null
    $lines.Add(('Server: {0}' -f $Script:Config.VpnServer)) | Out-Null
    $lines.Add(('CA URL: {0}' -f $Script:Config.CaCertUrl)) | Out-Null
    $lines.Add(('AllUser PBK: {0}' -f $Script:AllUserPbk)) | Out-Null
    $lines.Add(('User PBK: {0}' -f $Script:UserPbk)) | Out-Null
    $lines.Add('') | Out-Null

    foreach ($r in $Script:Results) {
        $lines.Add(('[{0}] [{1}] {2}: {3}' -f $r.Time,$r.Status,$r.Check,$r.Message)) | Out-Null
        if ($r.Details) { $lines.Add(('    {0}' -f $r.Details)) | Out-Null }
    }
    $lines | Set-Content -Path $path -Encoding UTF8
    $Script:LastReportPath = $path
    Write-Host "Отчёт сохранён: $path" -ForegroundColor Green
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutSeconds = 90
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $psi.StandardOutputEncoding = $oem
        $psi.StandardErrorEncoding = $oem
    } catch {}

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ ExitCode = -999; Output = "Timeout after $TimeoutSeconds sec" }
    }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = (($out + "`r`n" + $err).Trim()) }
}

function Pause-Menu { Write-Host ''; Read-Host 'Нажмите Enter для возвращения в меню' | Out-Null }

# =========================
# PBK parsing
# =========================
function Get-PbkProfiles {
    param([Parameter(Mandatory)][string]$Path)
    $items = @()
    if (-not (Test-Path $Path)) { return $items }

    $current = $null
    foreach ($line in Get-Content -Path $Path -Encoding Default) {
        if ($line -match '^\[(.+)\]\s*$') {
            if ($null -ne $current) { $items += [pscustomobject]$current }
            $current = [ordered]@{
                Name     = $matches[1]
                PbkPath  = $Path
                Settings = @{}
            }
            continue
        }
        if ($null -ne $current -and $line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2]
            $current.Settings[$key] = $value
        }
    }
    if ($null -ne $current) { $items += [pscustomobject]$current }
    return $items
}

function Get-AllPbkProfiles {
    $all = @()
    $all += Get-PbkProfiles -Path $Script:AllUserPbk
    $all += Get-PbkProfiles -Path $Script:UserPbk
    return $all
}

function Find-CorpVpnProfiles {
    $server = $Script:Config.VpnServer
    return @(Get-AllPbkProfiles | Where-Object {
        $_.Settings.ContainsKey('PhoneNumber') -and $_.Settings['PhoneNumber'] -ieq $server
    })
}

function Remove-PbkSection {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SectionName
    )
    if (-not (Test-Path $Path)) { return $false }
    $lines = Get-Content -Path $Path -Encoding Default
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $removed = $false
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]\s*$') {
            if ($matches[1] -eq $SectionName) {
                $inside = $true
                $removed = $true
                continue
            } else {
                $inside = $false
            }
        }
        if (-not $inside) { $out.Add($line) | Out-Null }
    }
    if ($removed) {
        Copy-Item -Path $Path -Destination ($Path + '.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
        $out | Set-Content -Path $Path -Encoding Default
    }
    return $removed
}

# =========================
# CA certificate from GitHub
# =========================
function Get-CaCertPath {
    $dir = Join-Path $env:TEMP 'MonopolyVpnTool'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $path = Join-Path $dir 'ca.cer'

    try {
        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }

        Invoke-WebRequest `
            -Uri $Script:Config.CaCertUrl `
            -OutFile $path `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $path)) {
            Add-Result FAIL 'CA certificate' 'CA не был скачан' $Script:Config.CaCertUrl
            return $null
        }

        $fileInfo = Get-Item $path -ErrorAction Stop
        if ($fileInfo.Length -lt 500) {
            Add-Result FAIL 'CA certificate' 'Скачанный CA выглядит подозрительно маленьким' ("Path=$path; Size=$($fileInfo.Length) bytes")
            return $null
        }

        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
            if (-not $cert.Thumbprint) {
                Add-Result FAIL 'CA certificate' 'Скачанный файл не похож на корректный сертификат' $path
                return $null
            }
        } catch {
            Add-Result FAIL 'CA certificate' 'Скачанный файл не удалось открыть как сертификат' ("URL=$($Script:Config.CaCertUrl); Error=$($_.Exception.Message)")
            return $null
        }

        Add-Result OK 'CA download' 'CA скачан с GitHub' ("$($Script:Config.CaCertUrl); Thumbprint=$($cert.Thumbprint)")
        return $path
    } catch {
        Add-Result FAIL 'CA certificate' 'Не удалось скачать CA с GitHub' ("URL=$($Script:Config.CaCertUrl); Error=$($_.Exception.Message)")
        return $null
    }
}

function Install-CaCertificate {
    if (-not (Test-IsAdmin)) {
        Add-Result FAIL 'CA certificate' 'Для установки CA нужен запуск PowerShell от администратора' ''
        return $false
    }

    $path = Get-CaCertPath
    if (-not $path) { return $false }

    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
        $thumb = $cert.Thumbprint
        $existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $thumb }

        if ($existing) {
            Add-Result OK 'CA certificate' 'CA уже установлен в LocalMachine\Root' ("Subject: $($cert.Subject); Thumbprint: $thumb")
        } else {
            Import-Certificate -FilePath $path -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
            Add-Result OK 'CA certificate' 'CA импортирован в LocalMachine\Root' ("Subject: $($cert.Subject); Thumbprint: $thumb")
        }
        return $true
    } catch {
        Add-Result FAIL 'CA certificate' 'Не удалось установить CA' $_.Exception.Message
        return $false
    }
}

function Test-CaCertificate {
    $path = Get-CaCertPath
    if (-not $path) { return }

    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
        $thumb = $cert.Thumbprint
        $existing = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object { $_.Thumbprint -eq $thumb }

        if ($existing) {
            Add-Result OK 'CA certificate' 'Нужный CA найден в LocalMachine\Root' ("Subject: $($cert.Subject); Thumbprint: $thumb")
        } else {
            $Script:CaFixNeeded = $true
            Add-Result FAIL 'CA certificate' 'Нужный CA не найден в LocalMachine\Root' ("Subject: $($cert.Subject); Thumbprint expected: $thumb")
        }
    } catch {
        Add-Result WARN 'CA certificate' 'Не удалось проверить CA' $_.Exception.Message
    }
}

# =========================
# VPN install/remove
# =========================
function Install-CorpVpn {
    Clear-Results
    Add-Section 'Установка VPN'
    Add-Result INFO 'Install' 'Начинаю установку VPN' ("Name=$($Script:Config.VpnName); Server=$($Script:Config.VpnServer)")

    if (-not (Test-IsAdmin)) {
        Add-Result FAIL 'Admin rights' 'Установку нужно запускать из PowerShell от администратора' 'Для irm | iex откройте PowerShell as Administrator и повторите команду.'
        Show-Summary
        return
    }

    [void](Install-CaCertificate)

    $existing = @(Find-CorpVpnProfiles)
    if ($existing.Count -gt 0) {
        Add-Result WARN 'Existing profile' ("VPN для $($Script:Config.VpnServer) уже существует: $($existing.Count)") (($existing | ForEach-Object { "$($_.Name) [$($_.PbkPath)]" }) -join '; ')
        Write-Host ''
        Write-Host 'Найден уже установленный VPN-профиль для этого сервера.' -ForegroundColor Yellow
        Write-Host '1. Удалить найденный профиль и установить заново'
        Write-Host '2. Не удалять, только выполнить диагностику'
        Write-Host '0. Отмена'
        $existingChoice = Read-Host 'Выберите действие'
        if ($existingChoice -eq '1') {
            foreach ($p in $existing) { Remove-CorpVpnProfileObject -Profile $p }
        } elseif ($existingChoice -eq '2') {
            Add-Result INFO 'Install' 'Установка пропущена: профиль уже существует, выполняю диагностику' ''
            Run-Diagnostics -NoClear -NoExport
                return
        } else {
            Add-Result WARN 'Install' 'Установка отменена пользователем' ''
            Show-Summary
                return
        }
    }

    try {
        $params = @{
            Name                 = $Script:Config.VpnName
            ServerAddress        = $Script:Config.VpnServer
            TunnelType           = $Script:Config.TunnelType
            EncryptionLevel      = $Script:Config.EncryptionLevel
            SplitTunneling       = $Script:Config.SplitTunneling
            AuthenticationMethod = 'Eap'
            RememberCredential   = $true
            Force                = $true
        }
        if ($Script:Config.AllUser) { $params['AllUserConnection'] = $true }
        Add-VpnConnection @params
        Add-Result OK 'Add-VpnConnection' 'VPN профиль создан' $Script:Config.VpnName
    } catch {
        Add-Result FAIL 'Add-VpnConnection' 'Не удалось создать VPN профиль' $_.Exception.Message
        Show-Summary
        return
    }

    try {
        if ($Script:Config.AllUser) {
            Set-VpnConnection -Name $Script:Config.VpnName -AllUserConnection -DnsSuffix $Script:Config.DnsSuffix -Force
        } else {
            Set-VpnConnection -Name $Script:Config.VpnName -DnsSuffix $Script:Config.DnsSuffix -Force
        }
        Add-Result OK 'DNS suffix' "DNS suffix установлен: $($Script:Config.DnsSuffix)" ''
    } catch {
        Add-Result WARN 'DNS suffix' 'Не удалось установить DNS suffix через Set-VpnConnection' $_.Exception.Message
    }

    Add-Result INFO 'Credentials' 'При первом подключении введите логин в формате user@monopoly.su' 'Пароль будет сохранён Windows, если включено RememberCredential.'
    Run-Diagnostics -NoClear -NoExport

    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Yellow
    Write-Host ' ВАЖНО: после установки VPN рекомендуется ПЕРЕЗАГРУЗИТЬ компьютер.' -ForegroundColor Yellow
    Write-Host ' После перезагрузки подключитесь к VPN и введите логин в формате user@monopoly.su.' -ForegroundColor Yellow
    Write-Host '=====================================================================' -ForegroundColor Yellow
    Write-Host ''

    Add-Result WARN 'Reboot required' 'После установки VPN рекомендуется перезагрузить ПК' 'Это помогает Windows корректно применить VPN/EAP/IPsec настройки и службы.'
}

function Remove-CorpVpnProfileObject {
    param([Parameter(Mandatory)]$Profile)
    $name = $Profile.Name
    $isAllUser = ($Profile.PbkPath -ieq $Script:AllUserPbk)

    try {
        if ($isAllUser) {
            Remove-VpnConnection -Name $name -AllUserConnection -Force -ErrorAction Stop
        } else {
            Remove-VpnConnection -Name $name -Force -ErrorAction Stop
        }
        Add-Result OK 'Remove-VpnConnection' "Профиль удалён: $name" $Profile.PbkPath
    } catch {
        Add-Result WARN 'Remove-VpnConnection' "Не удалось удалить профиль через Remove-VpnConnection: $name" $_.Exception.Message
        try {
            if (Remove-PbkSection -Path $Profile.PbkPath -SectionName $name) {
                Add-Result OK 'PBK cleanup' "Секция удалена из rasphone.pbk: $name" 'Перед изменением создан .bak файл рядом с rasphone.pbk'
            } else {
                Add-Result FAIL 'PBK cleanup' "Секция не найдена для удаления: $name" $Profile.PbkPath
            }
        } catch {
            Add-Result FAIL 'PBK cleanup' "Не удалось удалить секцию из rasphone.pbk: $name" $_.Exception.Message
        }
    }
}

function Remove-CorpVpn {
    Clear-Results
    Add-Result INFO 'Remove' 'Ищу VPN профили по серверу, а не по имени' $Script:Config.VpnServer
    if (-not (Test-IsAdmin)) {
        Add-Result FAIL 'Admin rights' 'Удаление лучше запускать из PowerShell от администратора' 'AllUserConnection профиль находится в ProgramData.'
        Show-Summary
        return
    }
    $profiles = @(Find-CorpVpnProfiles)
    if ($profiles.Count -eq 0) {
        Add-Result WARN 'Remove' 'Профили для корпоративного VPN не найдены' $Script:Config.VpnServer
        Show-Summary
        return
    }

    Write-Host 'Будут удалены профили:' -ForegroundColor Yellow
    $profiles | ForEach-Object { Write-Host (" - {0} [{1}]" -f $_.Name,$_.PbkPath) -ForegroundColor Yellow }
    $answer = Read-Host 'Продолжить удаление? [Y/N]'
    if ($answer -notmatch '^(Y|y|Д|д)$') {
        Add-Result WARN 'Remove' 'Удаление отменено пользователем' ''
        Show-Summary
        return
    }
    foreach ($p in $profiles) { Remove-CorpVpnProfileObject -Profile $p }
    Show-Summary
}

# =========================
# Diagnostics
# =========================
function Test-PbkValue {
    param(
        [hashtable]$Settings,
        [string]$Key,
        [string]$Expected,
        [ValidateSet('FAIL','WARN')][string]$Severity = 'FAIL',
        [string]$ProfileName = '',
        [string]$PbkPath = ''
    )
    if (-not $Settings.ContainsKey($Key)) {
        Add-Result $Severity "PBK:$Key" "Параметр отсутствует, ожидается '$Expected'" ''
        if ($Severity -eq 'FAIL') {
            $Script:FixQueue.Add([pscustomobject]@{ ProfileName=$ProfileName; PbkPath=$PbkPath; Key=$Key; Expected=$Expected; Actual='<missing>' }) | Out-Null
        }
        return
    }
    $actual = [string]$Settings[$Key]
    if ($actual -eq $Expected) {
        Add-Result OK "PBK:$Key" "$Key = $actual" ''
    } else {
        Add-Result $Severity "PBK:$Key" "$Key = '$actual', ожидалось '$Expected'" ''
        if ($Severity -eq 'FAIL') {
            $Script:FixQueue.Add([pscustomobject]@{ ProfileName=$ProfileName; PbkPath=$PbkPath; Key=$Key; Expected=$Expected; Actual=$actual }) | Out-Null
        }
    }
}

function Repair-PbkProfile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)]$Fixes
    )

    if (-not (Test-Path $Path)) {
        Add-Result FAIL 'Auto-fix' 'Не найден rasphone.pbk для исправления' $Path
        return $false
    }
    if ($Path -ieq $Script:AllUserPbk -and -not (Test-IsAdmin)) {
        Add-Result FAIL 'Auto-fix' 'Для исправления AllUser VPN нужен запуск PowerShell от администратора' $Path
        return $false
    }

    try {
        $backup = $Path + '.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item -Path $Path -Destination $backup -Force
        Add-Result OK 'Auto-fix backup' 'Создана резервная копия rasphone.pbk' $backup

        $lines = Get-Content -Path $Path -Encoding Default
        $out = New-Object System.Collections.Generic.List[string]
        $inside = $false
        $seenKeys = @{}
        $fixedCount = 0

        foreach ($line in $lines) {
            if ($line -match '^\[(.+)\]\s*$') {
                if ($inside) {
                    foreach ($fix in $Fixes) {
                        if (-not $seenKeys.ContainsKey($fix.Key)) {
                            $out.Add(("{0}={1}" -f $fix.Key, $fix.Expected)) | Out-Null
                            $fixedCount++
                            Add-Result OK 'Auto-fix' ("Добавлен параметр {0}={1}" -f $fix.Key,$fix.Expected) ''
                        }
                    }
                }
                $inside = ($matches[1] -eq $SectionName)
                if ($inside) { $seenKeys = @{} }
                $out.Add($line) | Out-Null
                continue
            }

            if ($inside -and $line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $fix = @($Fixes | Where-Object { $_.Key -eq $key }) | Select-Object -First 1
                if ($fix) {
                    $newLine = "{0}={1}" -f $key, $fix.Expected
                    $out.Add($newLine) | Out-Null
                    if ($line -ne $newLine) {
                        $fixedCount++
                        Add-Result OK 'Auto-fix' ("Исправлено {0}: '{1}' -> '{2}'" -f $key,$fix.Actual,$fix.Expected) ''
                    }
                    $seenKeys[$key] = $true
                    continue
                }
            }
            $out.Add($line) | Out-Null
        }

        if ($inside) {
            foreach ($fix in $Fixes) {
                if (-not $seenKeys.ContainsKey($fix.Key)) {
                    $out.Add(("{0}={1}" -f $fix.Key, $fix.Expected)) | Out-Null
                    $fixedCount++
                    Add-Result OK 'Auto-fix' ("Добавлен параметр {0}={1}" -f $fix.Key,$fix.Expected) ''
                }
            }
        }

        $out | Set-Content -Path $Path -Encoding Default
        Add-Result OK 'Auto-fix' "Профиль '$SectionName' исправлен" "Изменено параметров: $fixedCount"
        return $true
    } catch {
        Add-Result FAIL 'Auto-fix' 'Не удалось исправить rasphone.pbk' $_.Exception.Message
        return $false
    }
}

function Invoke-AutoFixIfNeeded {
    $hasPbkFixes = ($Script:FixQueue.Count -gt 0)
    $hasCaFix = [bool]$Script:CaFixNeeded

    if (-not $hasPbkFixes -and -not $hasCaFix) { return }

    Add-Section 'Автоисправление'

    if ($hasPbkFixes) {
        Write-Host 'Обнаружены исправимые несоответствия в VPN-профиле:' -ForegroundColor Yellow
        $Script:FixQueue | ForEach-Object {
            Write-Host (" - {0}: сейчас '{1}', нужно '{2}'" -f $_.Key,$_.Actual,$_.Expected) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    if ($hasCaFix) {
        Write-Host 'Обнаружена исправимая проблема с CA-сертификатом:' -ForegroundColor Yellow
        Write-Host ' - нужный CA отсутствует в LocalMachine\Root' -ForegroundColor Yellow
        Write-Host ''
    }

    $answer = Read-Host 'Попробовать автоматически исправить найденные проблемы? [Y/N]'
    if ($answer -notmatch '^(Y|y|Д|д)$') {
        Add-Result WARN 'Auto-fix' 'Автоисправление пропущено пользователем' ''
        return
    }

    if ($hasCaFix) {
        if (-not (Test-IsAdmin)) {
            Add-Result FAIL 'Auto-fix CA' 'Для установки CA нужен запуск PowerShell от администратора' ''
        } else {
            $caOk = Install-CaCertificate
            if ($caOk) { $Script:AutoFixApplied = $true }
        }
    }

    if ($hasPbkFixes) {
        $groups = $Script:FixQueue | Group-Object PbkPath, ProfileName
        foreach ($g in $groups) {
            $first = $g.Group | Select-Object -First 1
            $repairOk = Repair-PbkProfile -Path $first.PbkPath -SectionName $first.ProfileName -Fixes $g.Group
            if ($repairOk) { $Script:AutoFixApplied = $true }
        }
    }

    Write-Host ''
    Write-Host 'Автоисправление выполнено. Запустите диагностику ещё раз для подтверждения результата.' -ForegroundColor Yellow
    Write-Host 'Если VPN был открыт в настройках Windows, закройте окно настроек и откройте заново.' -ForegroundColor Yellow
}

function Test-DnsAndNetwork {
    $server = $Script:Config.VpnServer
    try {
        $records = Resolve-DnsName -Name $server -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 5
        if ($records) {
            Add-Result OK 'DNS' ("$server -> $($records.IPAddress -join ', ')") ''
        } else {
            Add-Result FAIL 'DNS' "Имя $server не вернуло IP адрес" ''
            return
        }
    } catch {
        Add-Result FAIL 'DNS' "Не удалось разрешить имя $server" $_.Exception.Message
        return
    }

    try {
        if (Test-Connection -ComputerName $server -Count 2 -Quiet -ErrorAction SilentlyContinue) {
            Add-Result OK 'ICMP ping' "Ответ от $server получен" ''
        } else {
            Add-Result WARN 'ICMP ping' 'ICMP не отвечает' 'Это может быть нормой: VPN сервер или провайдер может блокировать ping.'
        }
    } catch {
        Add-Result WARN 'ICMP ping' 'Ошибка проверки ICMP' $_.Exception.Message
    }

    foreach ($port in 500,4500) {
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Connect($server, $port)
            $bytes = [Text.Encoding]::ASCII.GetBytes('ikev2-probe')
            [void]$udp.Send($bytes, $bytes.Length)
            $udp.Close()
            Add-Result OK "UDP $port" "UDP-пакет на ${server}:$port отправлен" 'Важно: UDP send не подтверждает доставку до сервера. OK означает только, что локальная отправка не заблокирована.'
        } catch {
            Add-Result FAIL "UDP $port" "Не удалось отправить UDP-пакет на ${server}:$port" $_.Exception.Message
        }
    }
}

function Test-Services {
    $services = @(
        @{ Name='PolicyAgent'; Display='IPsec Policy Agent' },
        @{ Name='IKEEXT'; Display='IKE and AuthIP IPsec Keying Modules' }
    )
    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc.Name -ErrorAction Stop
            if ($s.Status -eq 'Running') {
                Add-Result OK $svc.Display "Служба запущена ($($s.Status))" ''
            } else {
                try {
                    Start-Service -Name $svc.Name -ErrorAction Stop
                    Start-Sleep -Milliseconds 700
                    $s2 = Get-Service -Name $svc.Name -ErrorAction Stop
                    if ($s2.Status -eq 'Running') {
                        Add-Result OK $svc.Display "Служба была остановлена, но успешно запущена ($($s2.Status))" 'Скрипт автоматически запустил службу.'
                    } else {
                        Add-Result FAIL $svc.Display "Служба не запущена ($($s2.Status))" 'Для IKEv2/IPsec эта служба нужна.'
                    }
                } catch {
                    Add-Result FAIL $svc.Display "Служба не запущена ($($s.Status)); автоматический запуск не удался" $_.Exception.Message
                }
            }
        } catch {
            Add-Result FAIL $svc.Display 'Служба не найдена или недоступна' $_.Exception.Message
        }
    }
}

function Read-RasClientLog {
    try {
        $log = Get-WinEvent -ListLog 'Microsoft-Windows-RasClient/Operational' -ErrorAction SilentlyContinue
        if (-not $log) {
            Add-Result INFO 'RasClient log' 'Журнал RasClient/Operational отсутствует или ещё не создан' 'Обычно появляется после попыток VPN-подключения.'
            return
        }
        $events = Get-WinEvent -LogName 'Microsoft-Windows-RasClient/Operational' -MaxEvents 8 -ErrorAction Stop |
            Select-Object TimeCreated,Id,ProviderName,Message
        if ($events) {
            $summary = ($events | ForEach-Object { "{0} ID={1}: {2}" -f $_.TimeCreated,$_.Id, ($_.Message -replace "`r?`n", ' ') }) -join "`n"
            Add-Result INFO 'RasClient log' 'Последние события RasClient собраны' $summary
        } else {
            Add-Result INFO 'RasClient log' 'Журнал RasClient доступен, но событий нет' ''
        }
    } catch {
        Add-Result WARN 'RasClient log' 'Не удалось прочитать RasClient/Operational' $_.Exception.Message
    }
}

function Read-IkeHints {
    $logs = @('Microsoft-Windows-IKE/Operational','Microsoft-Windows-WFP/Operational')
    foreach ($name in $logs) {
        try {
            $log = Get-WinEvent -ListLog $name -ErrorAction SilentlyContinue
            if (-not $log) { continue }
            $events = Get-WinEvent -LogName $name -MaxEvents 8 -ErrorAction Stop | Select-Object TimeCreated,Id,ProviderName,Message
            if ($events) {
                $text = ($events | ForEach-Object { "{0} ID={1}: {2}" -f $_.TimeCreated,$_.Id, ($_.Message -replace "`r?`n", ' ') }) -join "`n"
                $hasEstablished = $events | Where-Object { $_.Message -match 'established|Established|установ' }
                if ($hasEstablished) {
                    Add-Result OK 'IKE/IPsec log' 'В журналах есть признаки успешного IPsec/IKE обмена' $text
                } else {
                    Add-Result INFO 'IKE/IPsec log' "Последние события $name собраны" $text
                }
                return
            }
        } catch {}
    }
    Add-Result INFO 'IKE/IPsec log' 'IKE/WFP Operational log пустой или недоступен' ''
}

function Run-Diagnostics {
    param([switch]$NoClear, [switch]$NoExport)
    if (-not $NoClear) { Clear-Results }
    Add-Section 'Диагностика'
    Add-Result INFO 'Start' 'Диагностика VPN по серверу подключения, а не по имени профиля' $Script:Config.VpnServer

    $profiles = @(Find-CorpVpnProfiles)
    if ($profiles.Count -eq 0) {
        Add-Result FAIL 'VPN profile' 'VPN профиль для корпоративного сервера не найден' "Искал PhoneNumber=$($Script:Config.VpnServer) в $($Script:AllUserPbk) и $($Script:UserPbk)"
    } elseif ($profiles.Count -gt 1) {
        Add-Result WARN 'VPN profile' "Найдено несколько VPN профилей для $($Script:Config.VpnServer)" (($profiles | ForEach-Object { "$($_.Name) [$($_.PbkPath)]" }) -join '; ')
    } else {
        Add-Result OK 'VPN profile' "Найден профиль: $($profiles[0].Name)" $profiles[0].PbkPath
    }

    if ($profiles.Count -gt 0) {
        Add-Section 'Проверка профиля rasphone.pbk'
        foreach ($profile in $profiles) {
            $s = $profile.Settings
            Add-Result INFO 'Profile details' "Проверяю профиль: $($profile.Name)" $profile.PbkPath
            Test-PbkValue $s 'PhoneNumber' $Script:Config.VpnServer -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'VpnStrategy' '7' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'DataEncryption' '256' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'CustomAuthKey' '26' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'AuthRestrictions' '128' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'IpDnsSuffix' $Script:Config.DnsSuffix -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'IpPrioritizeRemote' '0' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'PreferredDevice' 'WAN Miniport (IKEv2)' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'PreferredPort' 'VPN2-0' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'Port' 'VPN2-0' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'Device' 'vpn' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'CacheCredentials' '1' 'WARN' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'UseRasCredentials' '1' 'WARN' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'IpNameAssign' '1' 'WARN' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Test-PbkValue $s 'Ipv6NameAssign' '1' 'WARN' -ProfileName $profile.Name -PbkPath $profile.PbkPath
            Add-Result INFO 'Login' 'Логин не проверяется автоматически' 'При первом подключении пользователь должен ввести логин в формате user@monopoly.su. Windows хранит credentials отдельно от rasphone.pbk.'
        }
    }

    Add-Section 'CA сертификат'
    Test-CaCertificate
    Add-Section 'DNS и сеть'
    Test-DnsAndNetwork
    Add-Section 'Службы Windows'
    Test-Services
    Add-Section 'Журналы Windows'
    Read-RasClientLog
    Read-IkeHints
    Invoke-AutoFixIfNeeded
    Add-Section 'Итог'
    Show-Summary

    if (-not $NoExport) {
        $hasFail = @($Script:Results | Where-Object Status -eq 'FAIL').Count -gt 0

        if ($hasFail) {
            Export-Report -Prefix 'VPN_IKEv2_Diagnostic'
            Write-Host ''
            Write-Host 'Диагностический отчёт создан на рабочем столе текущего пользователя.' -ForegroundColor Yellow
            Write-Host 'Передайте файл Monopoly_VPN_Diagnostic.txt в техническую поддержку.' -ForegroundColor Yellow
        } else {
            Write-Host ''
            Write-Host 'Отчёт не создан: критичных ошибок FAIL не обнаружено.' -ForegroundColor Green
            Write-Host 'Если VPN всё равно не подключается, сделайте скриншот ошибки подключения Windows.' -ForegroundColor Green
        }
    }
}

# =========================
# Menu
# =========================
function Show-Header {
    Clear-Host
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ' Monopoly IKEv2 VPN Tool' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ("Server : {0}" -f $Script:Config.VpnServer)
    Write-Host ("Default profile name : {0}" -f $Script:Config.VpnName)
    Write-Host ("CA URL : {0}" -f $Script:Config.CaCertUrl)
    Write-Host ("Admin : {0}" -f ($(if (Test-IsAdmin) {'YES'} else {'NO'})))
    Write-Host ''
}

function Show-Menu {
    while ($true) {
        Show-Header
        Write-Host '1. Установить VPN / обновить профиль'
        Write-Host '2. Удалить VPN профили для privet1.monopoly.su'
        Write-Host '3. Диагностика'
        Write-Host '4. Открыть папку с диагностическим отчётом'
        Write-Host '0. Выход'
        Write-Host ''
        $choice = Read-Host 'Выберите пункт'
        switch ($choice) {
            '1' { Install-CorpVpn; Pause-Menu }
            '2' { Remove-CorpVpn; Pause-Menu }
            '3' { Run-Diagnostics; Pause-Menu }
            '4' {
                if ($Script:LastReportPath -and (Test-Path $Script:LastReportPath)) {
                    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $Script:LastReportPath)
                } else {
                    Write-Host 'Диагностический отчёт пока не создан. Он создаётся только при наличии FAIL.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '0' { return }
            default { Write-Host 'Неверный пункт меню.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

Show-Menu
