[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $HardwareArchitecture = "{{__HARDWARE_ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"
[String] $PythonExecName = "{{__PYTHON_EXEC_NAME__}}"

function Get-RegistryVersionFilter {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    $archFilter = if ($Architecture -eq 'x86') { "32-bit" } else { "64-bit" }
    "Python $MajorVersion.$MinorVersion.*($archFilter)"
}

function Remove-RegistryEntries {
    param(
        [Parameter(Mandatory)][String] $Architecture,
        [Parameter(Mandatory)][Int32] $MajorVersion,
        [Parameter(Mandatory)][Int32] $MinorVersion
    )

    $versionFilter = Get-RegistryVersionFilter -Architecture $HardwareArchitecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
    if (Test-Path -Path Registry::$regPath) {
        $regKeys = Get-ChildItem -Path Registry::$regPath -Recurse | Where-Object Property -Ccontains DisplayName
        foreach ($key in $regKeys) {
            if ($key.getValue("DisplayName") -match $versionFilter) {
                Remove-Item -Path $key.PSParentPath -Recurse -Force -Verbose
            }
        }
    }

    $regPath = "HKEY_CLASSES_ROOT\Installer\Products"
    if (Test-Path -Path Registry::$regPath) {
        Get-ChildItem -Path Registry::$regPath | Where-Object { $_.GetValue("ProductName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }

    $uninstallRegistrySections = @(
        "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x64
        "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall", # all users, x64
        "HKEY_CURRENT_USER\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",  # current user, x86
        "HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"  # all users, x86
    )

    $uninstallRegistrySections | Where-Object { Test-Path -Path Registry::$_ } | ForEach-Object {
        Get-ChildItem -Path Registry::$_ | Where-Object { $_.getValue("DisplayName") -match $versionFilter } | ForEach-Object {
            Remove-Item Registry::$_ -Recurse -Force -Verbose
        }
    }
}

function Get-ExecParams {
    param(
        [Parameter(Mandatory)][Boolean] $IsMSI,
        [Parameter(Mandatory)][Boolean] $IsFreeThreaded,
        [Parameter(Mandatory)][String] $PythonArchPath
    )

    if ($IsMSI) {
        return @("TARGETDIR=$PythonArchPath", 'ALLUSERS=1')
    }

    $args = @("DefaultAllUsersTargetDir=$PythonArchPath", 'InstallAllUsers=1')

    if ($IsFreeThreaded) {
        $args += 'Include_freethreaded=1'
    }

    return $args
}

$ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    # GitHub images don't have `AGENT_TOOLSDIRECTORY` variable
    $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
}
$PythonToolcachePath = Join-Path -Path $ToolcacheRoot -ChildPath "Python"
$PythonVersionPath = Join-Path -Path $PythonToolcachePath -ChildPath $Version
$PythonArchPath = Join-Path -Path $PythonVersionPath -ChildPath $Architecture

$IsMSI = $PythonExecName -match "msi"
$IsFreeThreaded = $Architecture -match "-freethreaded"

$MajorVersion = $Version.Split('.')[0]
$MinorVersion = $Version.Split('.')[1]

Write-Host "Check if Python hostedtoolcache folder exist..."
if (-Not (Test-Path $PythonToolcachePath)) {
    Write-Host "Create Python toolcache folder"
    New-Item -ItemType Directory -Path $PythonToolcachePath | Out-Null
}

Write-Host "Check if current Python version is installed..."
# Search for all architecture variants sharing the same hardware architecture
# (e.g. both arm64 and arm64-freethreaded) to avoid Windows Installer conflicts
$InstalledVersions = Get-Item "$PythonToolcachePath\$MajorVersion.$MinorVersion.*\$HardwareArchitecture*"
Write-Host $InstalledVersions

if ($null -ne $InstalledVersions) {
    Write-Host "Python$MajorVersion.$MinorVersion ($HardwareArchitecture*) was found in $PythonToolcachePath..."

    foreach ($InstalledVersion in $InstalledVersions) {
        if (Test-Path -Path $InstalledVersion) {
            Write-Host "Uninstalling $InstalledVersion..."
            $InstallerExe = Get-Item "$InstalledVersion\python-$MajorVersion.$MinorVersion.*-$HardwareArchitecture.exe"
            if ($InstallerExe) {
                $proc = Start-Process -FilePath $InstallerExe.FullName `
                          -ArgumentList ('/uninstall', '/quiet') `
                          -Wait -PassThru
                if ($proc.ExitCode -ne 0) {
                    Write-Host "Warning: Uninstaller exited with code $($proc.ExitCode) for $InstalledVersion"
                }
            } else {
                Write-Host "Warning: No installer exe found in $InstalledVersion, skipping uninstall"
            }
            Remove-Item -Path $InstalledVersion -Recurse -Force
            $installedArch = $InstalledVersion.Name
            if (Test-Path -Path "$($InstalledVersion.Parent.FullName)/${installedArch}.complete") {
                Remove-Item -Path "$($InstalledVersion.Parent.FullName)/${installedArch}.complete" -Force -Verbose
            }
        }
    }
} else {
    Write-Host "No Python$MajorVersion.$MinorVersion.* ($HardwareArchitecture*) found"
}

Write-Host "Remove registry entries for Python ${MajorVersion}.${MinorVersion}(${Architecture})..."
Remove-RegistryEntries -Architecture $Architecture -MajorVersion $MajorVersion -MinorVersion $MinorVersion

Write-Host "Create Python $Version folder in $PythonToolcachePath"
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Write-Host "Copy Python binaries to $PythonArchPath"
Copy-Item -Path ./$PythonExecName -Destination $PythonArchPath | Out-Null

Write-Host "Install Python $Version in $PythonToolcachePath..."
$ExecParams = Get-ExecParams -IsMSI $IsMSI -IsFreeThreaded $IsFreeThreaded -PythonArchPath $PythonArchPath

$proc = Start-Process -FilePath (Join-Path $PythonArchPath $PythonExecName) `
  -ArgumentList ($ExecParams + '/quiet') `
  -Wait -PassThru

if ($proc.ExitCode -ne 0) { throw "Installer failed with exit code $($proc.ExitCode)" }

if ($IsFreeThreaded) {
    # Delete python.exe and create a symlink to free-threaded exe
    Remove-Item -Path "$PythonArchPath\python.exe" -Force
    New-Item -Path "$PythonArchPath\python.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python${MajorVersion}.${MinorVersion}t.exe"
}

Write-Host "Create `python3` symlink"
New-Item -Path "$PythonArchPath\python3.exe" -ItemType SymbolicLink -Value "$PythonArchPath\python.exe"

Write-Host "Install and upgrade Pip"
$Env:PIP_ROOT_USER_ACTION = "ignore"
$PythonExePath = Join-Path -Path $PythonArchPath -ChildPath "python.exe"
& $PythonExePath -m ensurepip
if ($LASTEXITCODE -ne 0) { throw "Error happened during ensurepip" }
& $PythonExePath -m pip install --upgrade --force-reinstall pip --no-warn-script-location
if ($LASTEXITCODE -ne 0) { throw "Error happened during pip installation / upgrade" }

Write-Host "Create complete file"
New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" | Out-Null