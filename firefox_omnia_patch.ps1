$ErrorActionPreference = 'Stop'

Write-Host '========================================'
Write-Host 'Firefox omni.ja patch'
Write-Host '========================================'
Write-Host ''

$patchScript = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'omia_patch.py' -File | Select-Object -First 1
if (-not $patchScript) {
    Write-Host 'ERROR: No omia patch script was found on the Desktop.'
    exit 1
}

Write-Host 'Searching for Firefox omni.ja...'
$knownPaths = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox\omni.ja'),
    (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\omni.ja'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\omni.ja'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Mozilla Firefox\omni.ja'),
    (Join-Path $env:APPDATA 'Mozilla Firefox\omni.ja')
) | Where-Object { $_ }

$target = $null
$firefoxExe = $null
foreach ($candidate in $knownPaths) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $candidateExe = Join-Path (Split-Path -Path $candidate -Parent) 'firefox.exe'
        if (Test-Path -LiteralPath $candidateExe -PathType Leaf) {
            $target = Get-Item -LiteralPath $candidate
            $firefoxExe = Get-Item -LiteralPath $candidateExe
            break
        }
    }
}

if (-not $target) {
    $searchRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object {
        $_ -and (Test-Path -LiteralPath $_ -PathType Container)
    } | Select-Object -Unique

    foreach ($root in $searchRoots) {
        $items = Get-ChildItem -LiteralPath $root -Filter 'omni.ja' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -match '(?i)firefox'
        }
        foreach ($item in $items) {
            $candidateExe = Join-Path $item.DirectoryName 'firefox.exe'
            if (Test-Path -LiteralPath $candidateExe -PathType Leaf) {
                $target = $item
                $firefoxExe = Get-Item -LiteralPath $candidateExe
                break
            }
        }
        if ($target) { break }
    }
}

if (-not $target) {
    Write-Host 'Common locations did not contain the file. Searching folders with Firefox in their name...'
    $driveRoots = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($drive in $driveRoots) {
        $firefoxFolders = Get-ChildItem -LiteralPath $drive.Root -Directory -Recurse -Filter '*firefox*' -ErrorAction SilentlyContinue
        foreach ($folder in $firefoxFolders) {
            $candidate = Join-Path $folder.FullName 'omni.ja'
            $candidateExe = Join-Path $folder.FullName 'firefox.exe'
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-Path -LiteralPath $candidateExe -PathType Leaf)) {
                $target = Get-Item -LiteralPath $candidate
                $firefoxExe = Get-Item -LiteralPath $candidateExe
                break
            }
        }
        if ($target) { break }
    }
}

if (-not $target) {
    Write-Host 'ERROR: Could not find omni.ja in a Firefox installation.'
    Write-Host 'Checked common Program Files, user application folders, and Firefox-named folders.'
    exit 1
}

Write-Host ('Found target: ' + $target.FullName)
Write-Host ('Found Firefox: ' + $firefoxExe.FullName)
Write-Host ''

$bytes = [IO.File]::ReadAllBytes($target.FullName)
$text = [Text.Encoding]::ASCII.GetString($bytes)
if ($text.Contains('MOZ_REQUIRE_SIGNING:false')) {
    Write-Host 'No changes were made. The file is already patched.'
    Write-Host 'Opening Firefox and about:support...'
    Start-Process -FilePath $firefoxExe.FullName -ArgumentList 'about:support'
    exit 0
}
if (-not $text.Contains('MOZ_REQUIRE_SIGNING: true')) {
    Write-Host 'ERROR: Target text was not found. No change made.'
    exit 1
}

$backup = $target.FullName + '.old'
if (Test-Path -LiteralPath $backup -PathType Leaf) {
    $previous = $backup + '.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Copy-Item -LiteralPath $backup -Destination $previous -ErrorAction Stop
    Write-Host ('Previous backup preserved as: ' + $previous)
}

Write-Host 'Running the patch script...'
& python.exe $patchScript.FullName $target.FullName
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ERROR: The patch script failed.'
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host ('Patch completed successfully. Backup: ' + $backup)
Write-Host 'Opening Firefox and about:support...'
Start-Process -FilePath $firefoxExe.FullName -ArgumentList 'about:support'
exit 0
