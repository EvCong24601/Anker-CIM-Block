# Optional, explicitly invoked bootstrap for a project-local Windows simulator.
# Does not run installers, modify registry, or change global PATH.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $projectRoot '.tools\iverilog'
$archiveRoot = Join-Path $toolRoot 'archives'
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null

# Versions and SHA256 values from https://packages.msys2.org/ on 2026-10-13.
$packages = @(
    @('iverilog-1~13.0-2', 'fd4d7d7cb60cda1eb437f5476673503d92964cf47ce6c11b460eb3bd05c43582'),
    @('bzip2-1.0.8-4', 'f03a2174034ddd2d96cecd34f617c5f8e2ef86c812b8d2bb3b8875257f2c8bfa'),
    @('readline-8.3.003-1', 'de2423c2e10fcd88272a0ab2f833f6a082cfe613d4c17c2f548cc50a5d2190c4'),
    @('zlib-1.3.2-2', '841401182976d2f9e17e5c0ebaac51f2a8014140ea53d67625e91c8fb3c85ea0'),
    @('termcap-1.3.1-8', 'c7891143e252568d8d46df72b3aefea932f4166771e17f22317218d7dd2af23c'),
    @('libgcc-16.2.0-5', '5b7efca9a27ce7504a931d92bac39a8009d8347dade0d905d0588aecdf68cb4b'),
    @('libstdc++-16.2.0-5', '9025eb0c238f1c6093bb7561d9be64523159a8cac212b9c221853ac88c0d341a'),
    @('libwinpthread-14.0.0.r426.g4564ee4b5-1', 'f8de8153bbc0e47ba244a423c12c426fa1d9f56395117ecaa34c6ad6ebed6ca3'),
    @('tzdata-2026e-1', 'f1809089f8ed5cec858ae8584289172896eb921be1e78ba583555f74e9015428')
)
foreach ($package in $packages) {
    $archiveName = 'mingw-w64-ucrt-x86_64-' + $package[0] + '-any.pkg.tar.zst'
    $archivePath = Join-Path $archiveRoot $archiveName
    if (-not (Test-Path -LiteralPath $archivePath)) {
        Write-Output ('Downloading ' + $archiveName)
        $downloadUrl = 'https://repo.msys2.org/mingw/ucrt64/' + [Uri]::EscapeDataString($archiveName)
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -TimeoutSec 60
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $package[1]) { throw ('SHA256 mismatch: ' + $archiveName) }
    $archiveEntries = & tar -tf $archivePath
    if ($LASTEXITCODE -ne 0) { throw ('Cannot inspect archive: ' + $archiveName) }
    foreach ($archiveEntry in $archiveEntries) {
        if ($archiveEntry.StartsWith('ucrt64/')) {
            if ($archiveEntry -match '(^|/)\.\.(/|$)' -or $archiveEntry -match ':|\\') {
                throw ('Unsafe archive path: ' + $archiveEntry)
            }
        }
    }
    & tar -xf $archivePath -C $toolRoot ucrt64
    if ($LASTEXITCODE -ne 0) { throw ('Extraction failed: ' + $archiveName) }
}
$binaryRoot = Join-Path $toolRoot 'ucrt64\bin'
& (Join-Path $binaryRoot 'iverilog.exe') -V
if ($LASTEXITCODE -ne 0) { throw 'Icarus version check failed' }
Write-Output ('Portable simulator ready: ' + $binaryRoot)
