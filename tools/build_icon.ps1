## Compiles icon.ico into icon.res so it can be linked into the executable.
##
## Nim's `--win32icon` cannot be used here: it is rejected in `config.nims` (only
## a subset of options is allowed there) and the nimble file has no way to pass it
## through, so `nimble build` would produce an iconless exe. `icon.res` is linked
## with `--passL` instead, which config.nims does accept.
##
## Normally invoked by the `before build` hook in catellitev2f.nimble; run it by
## hand only when debugging a link failure.
param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ico  = Join-Path $root 'icon.ico'
$rc   = Join-Path $root 'icon.rc'
$res  = Join-Path $root 'icon.res'

if (-not (Test-Path $ico)) { throw "icon.ico not found at $ico" }

# Nothing to do when the object is already current. Exe's own timestamp is not a
# reliable input here, so the comparison is ico vs res only.
if (-not $Force -and (Test-Path $res)) {
  if ((Get-Item $ico).LastWriteTime -le (Get-Item $res).LastWriteTime) {
    Write-Host "icon.res is up to date"
    exit 0
  }
}

$windres = Get-Command windres -ErrorAction SilentlyContinue
if (-not $windres) {
  # Not fatal: a stale icon.res still links, it is just out of date. Saying so
  # plainly beats failing the build over a cosmetic asset.
  Write-Warning "windres not found on PATH; leaving the existing icon.res in place"
  if (Test-Path $res) { exit 0 }
  throw "windres is required to build icon.res and is not on PATH"
}

Write-Host "compiling icon.rc -> icon.res"
& $windres.Source -i $rc -o $res -O coff
if ($LASTEXITCODE -ne 0) { throw "windres failed with exit code $LASTEXITCODE" }
Write-Host ("icon.res: {0} bytes" -f (Get-Item $res).Length)