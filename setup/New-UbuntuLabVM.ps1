<#
.SYNOPSIS
    Creates the Ubuntu Desktop VM for the Home SOC Lab in VirtualBox and installs Ubuntu unattended.

.DESCRIPTION
    - EFI firmware, VMSVGA graphics, Guest Additions installed
    - NAT networking for installation (Guest Additions needs packages from the
      internet); switch to the isolated "soc-lab" internal network before running
      any lab experiments.

    VirtualBox 7.2 has no Ubuntu 26.04 OS type yet, so Ubuntu25_64 (the closest,
    and what VirtualBox detects from the 26.04 ISO) is used.

    The user password is written in plain text to the VM's unattended files by
    VirtualBox, so use a lab-only password you don't use anywhere else.

.EXAMPLE
    .\New-UbuntuLabVM.ps1 -IsoPath D:\ISOs\ubuntu-26.04.1-desktop-amd64.iso
#>
[CmdletBinding()]
param(
    [string]$IsoPath = (Get-ChildItem 'D:\ISOs\ubuntu-*-desktop-amd64.iso' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName,
    [string]$VMName = 'ubuntu-soc',
    [string]$OSType = 'Ubuntu25_64',
    [string]$BaseFolder = 'D:\VIRTUAL MACHINES',
    [int]$MemoryMB = 4096,
    [int]$Cpus = 2,
    [int]$DiskGB = 40,
    [string]$UserName = 'analyst',
    [securestring]$Password,
    [string]$TimeZone = 'Europe/Warsaw'
)

$ErrorActionPreference = 'Stop'
$vbox = Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe'

function Invoke-VBox {
    & $vbox @args
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

if (-not $IsoPath -or -not (Test-Path $IsoPath)) { throw "Ubuntu desktop ISO not found. Pass -IsoPath." }
if ((& $vbox list vms) -match "^`"$VMName`" ") { throw "A VM named '$VMName' already exists." }
if (-not $Password) { $Password = Read-Host "Lab password for '$UserName'" -AsSecureString }
Write-Host "Using $IsoPath"

Invoke-VBox createvm --name $VMName --ostype $OSType --basefolder $BaseFolder --register
Invoke-VBox modifyvm $VMName --memory $MemoryMB --cpus $Cpus --vram 128 `
    --firmware efi --graphicscontroller vmsvga `
    --nic1 nat --clipboard-mode hosttoguest --drag-and-drop disabled --audio-enabled off

# Disk and controller; unattended install attaches the ISOs itself.
$disk = Join-Path $BaseFolder "$VMName\$VMName.vdi"
Invoke-VBox createmedium disk --filename $disk --size ($DiskGB * 1024) --variant Standard
Invoke-VBox storagectl $VMName --name SATA --add sata --controller IntelAhci --portcount 2
Invoke-VBox storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $disk

# Pass the password through a temp file so it never appears on a command line,
# and drop VBoxManage's echo of it from the output.
$pwFile = New-TemporaryFile
try {
    [IO.File]::WriteAllText($pwFile, [Net.NetworkCredential]::new('', $Password).Password)
    $ErrorActionPreference = 'Continue'   # VBoxManage logs info lines to stderr
    & $vbox unattended install $VMName --iso="$IsoPath" `
        --user=$UserName --user-password-file="$pwFile" --full-user-name="SOC Analyst" `
        --hostname="$VMName.lab.local" --locale=en_US --country=US --time-zone="$TimeZone" `
        --install-additions --start-vm=gui 2>&1 |
        ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'password\s*=' }
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage unattended install failed with exit code $LASTEXITCODE" }
} finally {
    $ErrorActionPreference = 'Stop'
    Remove-Item $pwFile -Force
}

Write-Host "Installation started. Ubuntu will reboot once or twice (~15-25 min); don't press keys in the VM."
