# Install Actape from the latest stable GitHub Release.
# For a verification-only run: .\install-windows.ps1 -DownloadOnly
param([switch]$DownloadOnly)
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitOperatingSystem) {
    throw 'This installer requires Windows x64.'
}
$repo = 'rizetngan/Actape'
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'Actape-Installer' }
if ($release.draft -or $release.prerelease) { throw 'Only stable releases are supported.' }
$name = "Actape-Windows-$($release.tag_name)-win-x64.zip"
$package = @($release.assets | Where-Object { $_.name -eq $name })
$checksum = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })
if ($package.Count -ne 1 -or $checksum.Count -ne 1) { throw 'Required release assets were not found.' }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("ActapeInstall-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $zip = Join-Path $temp $name
    $sums = Join-Path $temp 'SHA256SUMS.txt'
    Invoke-WebRequest -UseBasicParsing -Uri $package[0].browser_download_url -OutFile $zip
    Invoke-WebRequest -UseBasicParsing -Uri $checksum[0].browser_download_url -OutFile $sums
    $expected = @(
        Get-Content -LiteralPath $sums | ForEach-Object {
            if ($_ -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $name) {
                $Matches[1]
            }
        }
    )
    if ($expected.Count -ne 1) { throw 'Release checksum missing or ambiguous.' }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
    if ($actual -ne $expected[0]) { throw 'SHA-256 mismatch; installation aborted.' }
    Write-Host "Verified $name (SHA-256: $actual)"

    $unpack = Join-Path $temp 'unpacked'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
    $apps = @(Get-ChildItem -LiteralPath $unpack -Filter 'Actape.exe' -Recurse -File)
    if ($apps.Count -ne 1) { throw 'Expected exactly one Actape.exe in the ZIP.' }
    if ($DownloadOnly) {
        Write-Host 'Verification complete. No files were installed.'
        return
    }
    if (Get-Process -Name 'Actape' -ErrorAction SilentlyContinue) {
        throw 'Please close Actape before upgrading and run this command again.'
    }

    $dest = Join-Path $env:LOCALAPPDATA 'Programs\Actape'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $exe = Join-Path $dest 'Actape.exe'
    if (Test-Path -LiteralPath $exe) {
        $backup = Join-Path $dest ("Actape.backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
        Copy-Item -LiteralPath $exe -Destination $backup -Force
        Write-Host "Backed up previous executable to $backup"
    }
    Copy-Item -Path (Join-Path $apps[0].Directory.FullName '*') -Destination $dest -Recurse -Force
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Actape.exe was not installed.' }

    Write-Host "Installed Actape $($release.tag_name) to $dest"
    Write-Host 'Existing macros under %APPDATA%\Actape were not modified.'
    Start-Process -FilePath $exe
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
