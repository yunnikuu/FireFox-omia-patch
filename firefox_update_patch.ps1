$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Firefox is installed under Program Files on this computer. Keep the check in
# the BAT as well as here so the script is safe to start by hand.
if (-not (Test-IsAdministrator)) {
    Write-Host '正在请求管理员权限...'
    $elevatedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $elevatedArgs | Out-Null
    exit 0
}

Write-Host '========================================'
Write-Host 'Firefox 更新并修补 omni.ja'
Write-Host '========================================'
Write-Host ''

function Get-FirefoxInstall {
    $candidateDirs = @()
    $process = Get-Process -Name firefox -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($process) {
        $candidateDirs += Split-Path -Parent $process.Path
    }
    $candidateDirs += @(
        (Join-Path $env:ProgramFiles 'Mozilla Firefox'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox'),
        (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Mozilla Firefox')
    )

    foreach ($dir in ($candidateDirs | Where-Object { $_ } | Select-Object -Unique)) {
        $exe = Join-Path $dir 'firefox.exe'
        $omni = Join-Path $dir 'omni.ja'
        $updater = Join-Path $dir 'updater.exe'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and
            (Test-Path -LiteralPath $omni -PathType Leaf) -and
            (Test-Path -LiteralPath $updater -PathType Leaf)) {
            return [pscustomobject]@{
                Directory = (Get-Item -LiteralPath $dir).FullName
                Exe = (Get-Item -LiteralPath $exe).FullName
                Omni = (Get-Item -LiteralPath $omni).FullName
                Updater = (Get-Item -LiteralPath $updater).FullName
            }
        }
    }

    return $null
}

function Get-DownloadedUpdate {
    param([string]$InstallDirectory)

    $patterns = @(
        (Join-Path $env:ProgramData 'Mozilla-*\updates\*\updates\0'),
        (Join-Path $env:LOCALAPPDATA 'Mozilla\updates\*\updates\0'),
        (Join-Path $env:APPDATA 'Mozilla\updates\*\updates\0'),
        (Join-Path $InstallDirectory 'updates\0')
    )

    $candidates = foreach ($pattern in $patterns) {
        Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue
    }

    # Do not select an old failed update from updates.xml. Only a downloaded
    # update whose status says it is waiting to be installed is actionable.
    foreach ($candidate in ($candidates | Sort-Object LastWriteTime -Descending)) {
        $statusFile = Join-Path $candidate.FullName 'update.status'
        $marFile = Join-Path $candidate.FullName 'update.mar'
        if (-not (Test-Path -LiteralPath $marFile -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) { continue }
        $status = (Get-Content -LiteralPath $statusFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($status -notin @('pending', 'pending-service', 'applying')) { continue }

        $updateRoot = Split-Path -Parent (Split-Path -Parent $candidate.FullName)
        return [pscustomobject]@{
            Directory = $candidate.FullName
            StatusFile = $statusFile
            Status = $status
            UpdateRoot = $updateRoot
            ActiveXml = Join-Path $updateRoot 'active-update.xml'
            Metadata = Join-Path $updateRoot 'updates.xml'
            LastWriteTime = $candidate.LastWriteTime
        }
    }
    return $null
}

function Stop-Firefox {
    param([string]$FirefoxPath)

    $processes = @(Get-Process -Name firefox -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ($_.Path -ieq $FirefoxPath) } catch { $false }
    })
    if ($processes.Count -eq 0) {
        Write-Host 'Firefox 当前没有运行。'
        return
    }

    Write-Host ('检测到 Firefox 正在运行（' + $processes.Count + ' 个进程），正在强制关闭...')
    $processes | Stop-Process -Force
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $left = @(Get-Process -Name firefox -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -ieq $FirefoxPath) } catch { $false }
        })
        if ($left.Count -eq 0) { return }
    }
    throw 'Firefox 在 15 秒内没有退出。'
}

function Get-OmniState {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if ($text.Contains('MOZ_REQUIRE_SIGNING:false')) { return 'patched' }
    if ($text.Contains('MOZ_REQUIRE_SIGNING: true')) { return 'original' }
    return 'unknown'
}

function Restore-OriginalOmni {
    param([pscustomobject]$Install)

    $state = Get-OmniState -Path $Install.Omni
    if ($state -eq 'original') {
        Write-Host '当前 omni.ja 已是官方原始文件，无需恢复。'
        return
    }
    if ($state -ne 'patched') {
        throw '无法识别当前 omni.ja 的状态；为避免破坏安装，已停止更新。'
    }

    $backup = $Install.Omni + '.old'
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        throw ('检测到 omni.ja 已修补，但找不到官方备份：' + $backup)
    }
    if ((Get-OmniState -Path $backup) -ne 'original') {
        throw ('备份文件不是未修补的官方 omni.ja，已停止更新：' + $backup)
    }

    Write-Host '检测到 omni.ja 已被修补；先恢复官方文件，避免 Firefox 更新器 CRC 校验失败。'
    $temp = $Install.Omni + '.restore-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $backup -Destination $temp -Force
        Move-Item -LiteralPath $temp -Destination $Install.Omni -Force
        if ((Get-OmniState -Path $Install.Omni) -ne 'original') {
            throw '恢复后的 omni.ja 校验失败。'
        }
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host '官方 omni.ja 已恢复。'
}

function Show-UpdaterLogs {
    param([pscustomobject]$Update)
    $logPaths = @(
        (Join-Path $Update.Directory 'last-update.log'),
        (Join-Path (Split-Path -Parent $Update.Directory) 'last-update.log'),
        (Join-Path $Update.UpdateRoot 'last-update.log'),
        (Join-Path $Update.Directory 'last-update-elevated.log'),
        (Join-Path (Split-Path -Parent $Update.Directory) 'last-update-elevated.log'),
        (Join-Path $Update.UpdateRoot 'last-update-elevated.log')
    ) | Select-Object -Unique
    foreach ($log in $logPaths) {
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            Write-Host ('--- ' + $log + '（末尾 25 行）')
            Get-Content -LiteralPath $log -Tail 25 -ErrorAction SilentlyContinue
        }
    }
}

function Apply-DownloadedUpdate {
    param(
        [pscustomobject]$Install,
        [pscustomobject]$Update
    )

    Write-Host ('准备安装已下载更新：' + $Update.Directory)
    Restore-OriginalOmni -Install $Install

    # Firefox updater's normal first invocation is important here. It can hand
    # a pending-service update to Mozilla Maintenance Service and then run the
    # second elevated phase. Calling "second" directly bypasses that flow.
    $arguments = '3 "{0}" "{1}" "{2}" first 0' -f `
        $Update.Directory, $Install.Directory, $Install.Directory
    Write-Host '正在调用 Firefox 官方更新器...'
    $process = Start-Process -FilePath $Install.Updater `
        -ArgumentList $arguments `
        -WorkingDirectory $Install.Directory `
        -Wait -PassThru

    # The first updater may return before the maintenance service finishes.
    # Wait for the status file instead of trusting only Start-Process.ExitCode.
    for ($i = 0; $i -lt 180; $i++) {
        $status = if (Test-Path -LiteralPath $Update.StatusFile -PathType Leaf) {
            (Get-Content -LiteralPath $Update.StatusFile -Raw -ErrorAction SilentlyContinue).Trim()
        } else { '' }
        if ($status -eq 'succeeded') {
            Write-Host 'Firefox 更新成功。'
            return
        }
        if ($status -match '^(failed|download-failed|failed:)' ) {
            Write-Host ('Firefox 更新状态：' + $status)
            Show-UpdaterLogs -Update $Update
            throw ('Firefox 更新失败。updater 退出码：' + $process.ExitCode)
        }
        if ($i -lt 179) { Start-Sleep -Seconds 1 }
    }

    # A successful updater normally leaves succeeded in the status file. Do
    # not patch a possibly half-updated installation if that confirmation is
    # missing, even when the process exit code happened to be zero.
    Write-Host ('Firefox 更新器退出码：' + $process.ExitCode)
    Show-UpdaterLogs -Update $Update
    throw '等待 Firefox 更新完成超时，未确认 succeeded 状态。'
}

$install = Get-FirefoxInstall
if (-not $install) {
    throw '找不到 Firefox 安装目录。'
}
Write-Host ('Firefox 安装目录：' + $install.Directory)

$update = Get-DownloadedUpdate -InstallDirectory $install.Directory
if ($update) {
    Write-Host ('发现已下载更新（状态：' + $update.Status + '）')
} else {
    Write-Host '没有发现待安装的已下载更新，将直接修补当前 omni.ja。'
}

Stop-Firefox -FirefoxPath $install.Exe

if ($update) {
    Apply-DownloadedUpdate -Install $install -Update $update
    # The update may have replaced updater.exe and omni.ja, so rediscover files.
    $install = Get-FirefoxInstall
    if (-not $install) { throw '更新后找不到 Firefox 安装。' }
}

Write-Host '正在修补 omni.ja...'
$patchScript = Join-Path $PSScriptRoot 'firefox_omnia_patch.ps1'
if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
    throw '找不到 firefox_omnia_patch.ps1。'
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $patchScript -NoLaunch
if ($LASTEXITCODE -ne 0) {
    throw ('omni.ja 修补失败，退出码：' + $LASTEXITCODE)
}

$latestInstall = Get-FirefoxInstall
if (-not $latestInstall) { throw '修补后找不到 Firefox 安装。' }
Write-Host '正在重新启动 Firefox...'
Start-Process -FilePath $latestInstall.Exe -ArgumentList 'about:support'
Write-Host '全部完成。'
exit 0
