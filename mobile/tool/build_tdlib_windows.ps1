# Builds TDLib (JSON interface, tdjson.dll) for Windows x64 and copies it, with the OpenSSL and zlib
# DLLs it links against, into windows/tdlib. windows/CMakeLists.txt bundles them next to sado.exe.
# The TDLib commit must match the td_api schema of the `tdlib_ex` Dart package (see build_tdlib_android.sh).
#
# Requirements: git, Visual Studio with the "Desktop development with C++" workload (MSVC, Windows SDK, CMake).
# Usage: powershell -ExecutionPolicy Bypass -File tool/build_tdlib_windows.ps1 [work_dir]
# work_dir must not contain spaces (vcpkg and the TDLib build break on them).
param([string]$WorkDir = 'C:\tdlib-build')
$ErrorActionPreference = 'Stop'

$TdlibCommit = 'c15d3f5a5'   # "Update version to 1.8.68." - matches tdlib_ex 0.44.0
$AppDir = Split-Path $PSScriptRoot
$OutDir = Join-Path $AppDir 'windows\tdlib'

function Invoke-Checked([scriptblock]$Command) {
  & $Command
  if ($LASTEXITCODE) { throw "failed (exit $LASTEXITCODE): $Command" }
}

$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * `
  -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
if (-not $vs) { throw 'Visual Studio with "C++ CMake tools for Windows" is not installed' }
$env:PATH = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;$env:PATH"

New-Item -ItemType Directory -Force $WorkDir | Out-Null
Set-Location $WorkDir

if (-not (Test-Path vcpkg)) { Invoke-Checked { git clone --quiet https://github.com/microsoft/vcpkg.git } }
if (-not (Test-Path vcpkg\vcpkg.exe)) { Invoke-Checked { & .\vcpkg\bootstrap-vcpkg.bat -disableMetrics } }
Write-Host '==> Installing gperf, OpenSSL, zlib (vcpkg)'
Invoke-Checked { & .\vcpkg\vcpkg.exe install gperf:x64-windows openssl:x64-windows zlib:x64-windows }

if (-not (Test-Path td)) { Invoke-Checked { git clone --quiet https://github.com/tdlib/td.git } }
Invoke-Checked { git -C td fetch --quiet origin }
Invoke-Checked { git -C td checkout --quiet $TdlibCommit }

Write-Host '==> Building TDLib'
Invoke-Checked { cmake -S td -B td\build -A x64 "-DCMAKE_TOOLCHAIN_FILE=$WorkDir\vcpkg\scripts\buildsystems\vcpkg.cmake" }
# TDLib's generated sources need several GB of RAM per compiler process: keep parallelism low.
Invoke-Checked { cmake --build td\build --target tdjson --config Release -- /m:2 }

Write-Host "==> Installing libraries into $OutDir"
New-Item -ItemType Directory -Force $OutDir | Out-Null
# vcpkg's applocal step already put tdjson.dll's dependencies (OpenSSL, zlib) next to it.
Copy-Item td\build\Release\*.dll $OutDir
Get-ChildItem $OutDir
Write-Host 'Done.'
