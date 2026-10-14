<#
    WeFlow wcdb_api.dll date-limit patch

    Removes the two hard-coded expiry gates inside wcdb_api.dll that make every
    database call fail with -101 / -1000 / -1005 / -1006 after the built-in
    deadline (2026-09-30 23:59:59 for WeFlow 5.0.0).

    No path is hard-coded anywhere. The WeFlow installation is located by
    -AppDir, then $env:WEFLOW_DIR, then by walking up from this script, then by
    the uninstall entry in the registry, then by the usual install folders.

    Modes
        (default)        apply the patch
        -Check           report status only, never write
        -Restore         put the saved original DLL back
        -AppDir <dir>    use this WeFlow installation (the folder with WeFlow.exe)

    Examples
        powershell -ExecutionPolicy Bypass -File patch_wcdb.ps1
        powershell -ExecutionPolicy Bypass -File patch_wcdb.ps1 -Check
        powershell -ExecutionPolicy Bypass -File patch_wcdb.ps1 -Restore

    Exit codes
        0  success
        2  WeFlow installation or wcdb_api.dll not found
        3  WeFlow is running, the DLL is locked
        4  only one of the two gates matched, refusing to write
        5  verification after write failed
        6  no write permission (try running as administrator)
#>
[CmdletBinding()]
param(
    [string]$AppDir,
    [switch]$Restore,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$script:WeFlowExe = 'WeFlow.exe'

function Find-AppDir {
    param([string]$Hint)

    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint -PathType Container)) { return $null }
        return (Resolve-Path -LiteralPath $Hint).Path
    }

    if ($env:WEFLOW_DIR -and (Test-Path -LiteralPath (Join-Path $env:WEFLOW_DIR $script:WeFlowExe))) {
        return (Resolve-Path -LiteralPath $env:WEFLOW_DIR).Path
    }

    # 1. this script may live inside (or next to) the installation
    $candidates = New-Object System.Collections.Generic.List[string]
    $dir = Get-Item -LiteralPath $PSScriptRoot
    for ($i = 0; $i -lt 4 -and $dir; $i++) {
        $candidates.Add($dir.FullName)
        $dir = $dir.Parent
    }

    # 2. the uninstall entry written by the installer
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        $entries = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'WeFlow*' }
        foreach ($entry in $entries) {
            if ($entry.InstallLocation) { $candidates.Add($entry.InstallLocation) }
            if ($entry.UninstallString) {
                $exe = $entry.UninstallString -replace '^"', '' -replace '".*$', '' -replace '\s+/\S+$', ''
                if ($exe) { $candidates.Add((Split-Path -Parent $exe)) }
            }
        }
    }

    # 3. the usual per-user and per-machine locations
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates.Add((Join-Path $base 'Programs\WeFlow')); $candidates.Add((Join-Path $base 'WeFlow')) }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c $script:WeFlowExe))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Find-All {
    param([byte[]]$Hay, [byte[]]$Needle)

    $hits = New-Object System.Collections.Generic.List[int]
    $n = $Needle.Length
    $limit = $Hay.Length - $n
    for ($i = 0; $i -le $limit; $i++) {
        if ($Hay[$i] -ne $Needle[0]) { continue }
        $ok = $true
        for ($j = 1; $j -lt $n; $j++) {
            if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { $hits.Add($i) }
    }
    return $hits
}

# Gate 1, inside InitProtection: call <import>(FF 15 rel32) ; 48 3D <imm32 epoch> ; 7E 0A
function Patch-A {
    param([byte[]]$Data)

    $found = @()
    foreach ($i in (Find-All -Hay $Data -Needle ([byte[]](0x48, 0x3D)))) {
        if ($i -lt 6) { continue }
        if ($Data[$i - 6] -ne 0xFF -or $Data[$i - 5] -ne 0x15) { continue }
        $imm = [BitConverter]::ToUInt32($Data, $i + 2)
        if ($imm -lt 1400000000 -or $imm -gt 2200000000) { continue }
        if ($Data[$i + 6] -eq 0x7E -or $Data[$i + 6] -eq 0xEB) {
            $found += [pscustomobject]@{ Off = $i; Imm = $imm }
        }
    }
    if ($found.Count -ne 1) {
        return @{ Status = 'nomatch'; Off = -1; Info = "InitProtection gate: $($found.Count) matches" }
    }
    $hit = $found[0]
    if ($Data[$hit.Off + 6] -eq 0xEB) {
        return @{ Status = 'already'; Off = $hit.Off; Info = 'InitProtection gate already patched' }
    }
    if ($script:CheckOnly) {
        return @{ Status = 'needed'; Off = $hit.Off; Info = 'InitProtection gate present, not patched' }
    }
    $Data[$hit.Off + 6] = 0xEB
    $when = [DateTimeOffset]::FromUnixTimeSeconds($hit.Imm).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + 'Z'
    return @{ Status = 'patched'; Off = $hit.Off; Info = "InitProtection gate removed (hard-coded expiry was $when)" }
}

# Gate 2, inside wcdb_init: call <import>(FF 15 rel32) ; 48 3B C3 ; 0F 8E <rel32>
function Patch-B {
    param([byte[]]$Data)

    $found = @()
    foreach ($i in (Find-All -Hay $Data -Needle ([byte[]](0x48, 0x3B, 0xC3)))) {
        if ($i -lt 6) { continue }
        if ($Data[$i - 6] -ne 0xFF -or $Data[$i - 5] -ne 0x15) { continue }
        $unpatched = ($Data[$i + 3] -eq 0x0F -and $Data[$i + 4] -eq 0x8E)
        $patched = ($Data[$i + 3] -eq 0xE9)
        if ($unpatched -or $patched) { $found += $i }
    }
    if ($found.Count -ne 1) {
        return @{ Status = 'nomatch'; Off = -1; Info = "wcdb_init gate: $($found.Count) matches" }
    }
    $off = $found[0]
    if ($Data[$off + 3] -eq 0xE9) {
        return @{ Status = 'already'; Off = $off; Info = 'wcdb_init gate already patched' }
    }
    if ($script:CheckOnly) {
        return @{ Status = 'needed'; Off = $off; Info = 'wcdb_init gate present, not patched' }
    }
    $rel = [BitConverter]::ToInt32($Data, $off + 5)
    $new = [byte[]](0xE9) + [BitConverter]::GetBytes([int32]($rel + 1)) + [byte[]](0x90)
    [Array]::Copy($new, 0, $Data, $off + 3, 6)
    return @{ Status = 'patched'; Off = $off; Info = 'wcdb_init gate removed' }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
}

$script:CheckOnly = $Check.IsPresent

$resolved = Find-AppDir -Hint $AppDir
if (-not $resolved) {
    Write-Host 'ERROR: WeFlow installation not found.' -ForegroundColor Red
    Write-Host '       Point at it explicitly with -AppDir "<folder containing WeFlow.exe>".'
    exit 2
}
$AppDir = $resolved

if (-not $script:CheckOnly -and (Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($script:WeFlowExe)) -ErrorAction SilentlyContinue)) {
    Write-Host 'ERROR: WeFlow is running. Close it first, the DLL file is locked.' -ForegroundColor Red
    exit 3
}

Write-Host "WeFlow directory: $AppDir"
if ($script:CheckOnly) { Write-Host 'Mode: check only, nothing will be written' }
if ($Restore) { Write-Host 'Mode: restore original DLL' }

$targets = @(Get-ChildItem -LiteralPath $AppDir -Recurse -File -Filter 'wcdb_api.dll' -ErrorAction SilentlyContinue)
if ($targets.Count -eq 0) {
    Write-Host 'ERROR: no wcdb_api.dll found under the installation directory.' -ForegroundColor Red
    exit 2
}

$exitCode = 0

foreach ($file in $targets) {
    Write-Host ''
    Write-Host "== $($file.FullName)"

    if ($Restore) {
        $backup = $file.FullName + '.orig'
        if (-not (Test-Path -LiteralPath $backup)) {
            Write-Host "   skipped: no $($file.Name).orig backup next to it" -ForegroundColor DarkGray
            continue
        }
        try {
            Copy-Item -LiteralPath $backup -Destination $file.FullName -Force
            Write-Host "   restored from backup, sha256 $((Get-Hash $file.FullName))" -ForegroundColor Green
        } catch {
            Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '   hint: run as administrator if WeFlow is installed under Program Files'
            $exitCode = 6
        }
        continue
    }

    $data = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($data.Length -lt 0x100000) {
        Write-Host '   skipped: not a wcdb_api.dll build we know (too small)'
        continue
    }

    $a = Patch-A -Data $data
    $b = Patch-B -Data $data

    Write-Host "   $($a.Status): $($a.Info)"
    Write-Host "   $($b.Status): $($b.Info)"

    if ($a.Status -eq 'nomatch' -and $b.Status -eq 'nomatch') {
        Write-Host '   skipped: no expiry gate in this file (older unprotected build)' -ForegroundColor DarkGray
        continue
    }
    if ($a.Status -eq 'nomatch' -or $b.Status -eq 'nomatch') {
        Write-Host '   ERROR: only one of the two gates was found. Refusing to write.' -ForegroundColor Red
        $exitCode = 4
        continue
    }
    if ($a.Status -eq 'needed' -or $b.Status -eq 'needed') {
        Write-Host '   this file still needs the patch' -ForegroundColor Yellow
        continue
    }
    if ($a.Status -eq 'already' -and $b.Status -eq 'already') {
        Write-Host '   nothing to do' -ForegroundColor DarkGray
        continue
    }

    $before = Get-Hash $file.FullName
    $backup = $file.FullName + '.orig'
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $file.FullName -Destination $backup
        Write-Host "   backup written: $backup (sha256 $before)"
    }

    try {
        [System.IO.File]::WriteAllBytes($file.FullName, $data)
    } catch {
        Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '   hint: run as administrator if WeFlow is installed under Program Files'
        $exitCode = 6
        continue
    }

    $reread = [System.IO.File]::ReadAllBytes($file.FullName)
    $okA = ($a.Status -eq 'already') -or ($reread[$a.Off + 6] -eq 0xEB)
    $okB = ($b.Status -eq 'already') -or ($reread[$b.Off + 3] -eq 0xE9)
    if ($okA -and $okB) {
        Write-Host "   written and verified, sha256 $before -> $((Get-Hash $file.FullName))" -ForegroundColor Green
    } else {
        Write-Host '   ERROR: verification after write failed' -ForegroundColor Red
        $exitCode = 5
    }
}

Write-Host ''
if ($exitCode -ne 0) {
    Write-Host 'Finished with errors.' -ForegroundColor Red
    exit $exitCode
}
if ($script:CheckOnly) {
    Write-Host 'Check finished.'
} elseif ($Restore) {
    Write-Host 'Restore finished.' -ForegroundColor Green
} else {
    Write-Host "Done. Start WeFlow and check that the wcdb log does not contain 'InitProtection rc=-101'." -ForegroundColor Green
}
exit 0
