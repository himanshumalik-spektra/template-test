Param (
    [Parameter(Mandatory = $true)]
    [string]
    $AzureUserName,
    [string]
    $AzurePassword,
    [string]
    $AzureTenantID,
    [string]
    $AzureSubscriptionID,
    [string]
    $ODLID,
    [string]
    $DeploymentID,
    [string]
    $vmAdminUsername,
    [string]
    $adminPassword,
    [string]
    $trainerUserName,
    [string]
    $trainerUserPassword
)

# Clinical Trial Pre-Screening Crew (GLYCO-ADD): JumpVM setup.
# The Azure resources come from the ARM template; this script only prepares the learner's machine:
# VS Code, Git, Python 3.12 + uv, Azure CLI (+ Bicep), PowerShell 7.

Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

# Import Common Functions
$path = pwd
$path = $path.Path
$commonscriptpath = "$path" + "\cloudlabs-common\cloudlabs-windows-functions.ps1"
. $commonscriptpath

# Run imported functions from cloudlabs-windows-functions.ps1
WindowsServerCommon
choco install vscode.install --force -y
CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID

Enable-CloudLabsEmbeddedShadow $vmAdminUsername $trainerUserName $trainerUserPassword

Function updateVMShadowFile
{
    # Replace vmAdminUsernameValue with VM Admin UserName in script content
    $drivepath = "C:\Users\Public\Documents"
    (Get-Content -Path "$drivepath\Shadow.ps1") | ForEach-Object { $_ -Replace "vmAdminUsernameValue", "$vmAdminUsername" } | Set-Content -Path "$drivepath\Shadow.ps1"
    net user $trainerUserName $trainerUserPassword
}
updateVMShadowFile

Function RunModernVmValidator
{
    $svcName = "Spektra CloudLabs VM Agent"
    $binPath = "C:\CloudLabs\Validator\VMAgent\Spektra.CloudLabs.VMAgent.exe"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null

    # --- Download / extract the agent FIRST so it's always present ---
    New-Item -ItemType Directory -Path C:\CloudLabs\Validator -Force | Out-Null
    Write-Host "Downloading VM Agent..."
    Invoke-WebRequest 'https://experienceazure.blob.core.windows.net/software/vm-validator/VMAgent.zip' -OutFile 'C:\CloudLabs\Validator\VMAgent.zip'
    Expand-Archive -LiteralPath 'C:\CloudLabs\Validator\VMAgent.zip' -DestinationPath 'C:\CloudLabs\Validator' -Force

    if (Test-Path $binPath) {
        Write-Host "VM Agent extracted successfully at $binPath"
    } else {
        Write-Warning "VM Agent binary NOT found at $binPath after extraction."
    }

    # --- .NET Core 3.1 Hosting Bundle (needed by the VM Agent) ---
    Write-Host "Installing .NET Core 3.1 Windows Hosting Bundle via Chocolatey..."
    choco install dotnetcore-windowshosting --version=3.1.32 -y --no-progress

    $runtimes = & "C:\Program Files\dotnet\dotnet.exe" --list-runtimes 2>$null
    if ($runtimes -notmatch "Microsoft\.NETCore\.App 3\.1") {
        Write-Host "Hosting bundle not detected, trying dotnetcore-runtime package..."
        choco install dotnetcore-runtime --version=3.1.32 -y --no-progress
    }

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

    # --- Make idempotent: remove any pre-existing service ---
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        Write-Host "Existing service found - removing it first."
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        sc.exe delete "$svcName" | Out-Null
        Start-Sleep -Seconds 3
    }

    sc.exe create "$svcName" binPath= "`"$binPath`"" start= auto | Out-Null
    Start-Sleep -Seconds 3

    try {
        Start-Service -Name $svcName -ErrorAction Stop
        Write-Host "Service '$svcName' started successfully."
    } catch {
        Write-Warning "Service failed to start: $($_.Exception.Message)"
    }
}
RunModernVmValidator

# -------------------------------------------------------------------
# GIT FOR WINDOWS
# -------------------------------------------------------------------
Function Install-Git {
    $gitInstaller = "C:\Temp\git.exe"
    New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null
    try {
        Write-Host "Downloading Git for Windows..."
        (New-Object System.Net.WebClient).DownloadFile("https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/Git-2.56.0.4-64-bit.exe", $gitInstaller)
        Write-Host "Installing Git for Windows..."
        Start-Process -FilePath $gitInstaller -Wait -ArgumentList "/VERYSILENT /NORESTART"
    } catch {
        Write-Warning "Git install failed: $($_.Exception.Message)"
    }
}
Install-Git

# -------------------------------------------------------------------
# PYTHON 3.12 + uv (the lab's scripts run as "uv run python scripts/...")
# -------------------------------------------------------------------
Write-Host "Installing Python 3.12..."
choco install python312 -y --no-progress

try {
    Write-Host "Installing uv..."
    & "C:\Python312\python.exe" -m pip install --upgrade pip
    & "C:\Python312\python.exe" -m pip install uv
} catch {
    Write-Warning "uv install failed: $($_.Exception.Message)"
}

# -------------------------------------------------------------------
# AZURE CLI (+ Bicep) and POWERSHELL 7
# Challenge 7: az acr build, az deployment group create (Bicep), entra_setup.ps1, deploy_images.ps1
# -------------------------------------------------------------------
try { choco install azure-cli -y --no-progress } catch { Write-Warning "Azure CLI install failed: $($_.Exception.Message)" }
try { choco install powershell-core -y --no-progress } catch { Write-Warning "PowerShell 7 install failed: $($_.Exception.Message)" }

# Bicep goes into the learner's profile on first 'az bicep' use; pre-install it machine-wide too
try {
    New-Item -ItemType Directory -Force -Path "C:\Program Files\Bicep" | Out-Null
    (New-Object System.Net.WebClient).DownloadFile("https://github.com/Azure/bicep/releases/latest/download/bicep-win-x64.exe", "C:\Program Files\Bicep\bicep.exe")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine)
    if ($machinePath -notlike "*C:\Program Files\Bicep*") {
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;C:\Program Files\Bicep", [System.EnvironmentVariableTarget]::Machine)
    }
} catch {
    Write-Warning "Bicep install failed: $($_.Exception.Message)"
}

# -------------------------------------------------------------------
# VS CODE EXTENSIONS (Python, Bicep)
# -------------------------------------------------------------------
$code = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
if (Test-Path $code) {
    foreach ($ext in @("ms-python.python", "ms-azuretools.vscode-bicep")) {
        try { & $code --install-extension $ext --force } catch { Write-Warning "VS Code extension $ext failed: $($_.Exception.Message)" }
    }
}

# -------------------------------------------------------------------
# LAB FOLDER
# -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path "C:\LabFiles" | Out-Null
[System.IO.File]::WriteAllText("C:\LabFiles\deployment-id.txt", $DeploymentID)

Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1

sleep 30

Stop-Transcript
Disable-ScheduledTask -TaskName "runuserdata"
Stop-ScheduledTask -TaskName "runuserdata"
Restart-Computer -Force