# Runs the Core package tests on Windows (Swift for Windows + VS Build Tools). CI stays the gate.
# usage: pwsh scripts/test-core.ps1 [extra swift test args, e.g. --filter TrackFilterTests]
$ErrorActionPreference = 'Stop'
$env:Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;" + $env:Path
# The Swift installer sets SDKROOT for new logons only; read it from the registry so older shells work too.
foreach ($scope in 'User', 'Machine') { $v = [Environment]::GetEnvironmentVariable('SDKROOT', $scope); if ($v) { $env:SDKROOT = $v } }
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -products * -latest -property installationPath
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
Set-Location (Join-Path $PSScriptRoot '..\Core')
swift test @args
exit $LASTEXITCODE
