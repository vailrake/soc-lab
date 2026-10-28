<#
.SYNOPSIS
    Creates the Windows 11 VM for the Home SOC Lab in VirtualBox and installs Windows unattended.

.DESCRIPTION
    - EFI firmware, TPM 2.0 and Secure Boot (Windows 11 requirements)
    - Local account only (no Microsoft account), Guest Additions installed
    - NAT networking for installation; switch to the isolated "soc-lab" internal
      network before running any attack/login experiments (see README).

    The user password is written in plain text to the VM's unattended files by
    VirtualBox, so use a lab-only password you don't use anywhere else.

.EXAMPLE
    .\New-Win11LabVM.ps1 -IsoPath D:\ISOs\Win11_25H2_English_x64.iso
#>
[CmdletBinding()]
param(
    [string]$IsoPath = (Get-ChildItem 'D:\ISOs\Win*11*.iso' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName,
    [string]$VMName = 'win11-soc',
    [string]$BaseFolder = 'D:\VIRTUAL MACHINES',
    [int]$MemoryMB = 8192,
    [int]$Cpus = 4,
    [int]$DiskGB = 80,
    [string]$UserName = 'analyst',
    [securestring]$Password,
    [string]$Edition = 'Windows 11 Pro',
    [int]$ImageIndex = 0,
    [string]$TimeZone = 'Central European Standard Time'
)

$ErrorActionPreference = 'Stop'
$vbox = Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe'

function Invoke-VBox {
    & $vbox @args
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

if (-not $IsoPath -or -not (Test-Path $IsoPath)) { throw "Windows 11 ISO not found. Pass -IsoPath." }
if ((& $vbox list vms) -match "^`"$VMName`" ") { throw "A VM named '$VMName' already exists." }
if (-not $Password) { $Password = Read-Host "Lab password for '$UserName'" -AsSecureString }

# Pick the requested edition from the ISO unless an index was given explicitly.
if ($ImageIndex -eq 0) {
    $detect = & $vbox unattended detect --iso="$IsoPath" 2>&1 | Out-String
    $match = [regex]::Matches($detect, '(?m)^\s*Image #?(\d+)\s*=\s*(.+?)\s*$') |
             Where-Object { $_.Groups[2].Value -match "^$([regex]::Escape($Edition))\s*(\(|$)" } |
             Select-Object -First 1
    if (-not $match) { throw "Edition '$Edition' not found in ISO. Detect output:`n$detect" }
    $ImageIndex = [int]$match.Groups[1].Value
}
Write-Host "Using '$Edition' (image index $ImageIndex) from $IsoPath"

# VM with Windows 11 requirements: EFI + Secure Boot + TPM 2.0.
Invoke-VBox createvm --name $VMName --ostype Windows11_64 --basefolder $BaseFolder --register
Invoke-VBox modifyvm $VMName --memory $MemoryMB --cpus $Cpus --vram 128 `
    --firmware efi --tpm-type 2.0 --graphicscontroller vboxsvga `
    --nic1 nat --clipboard-mode hosttoguest --drag-and-drop disabled --audio-enabled off
Invoke-VBox modifynvram $VMName inituefivarstore
Invoke-VBox modifynvram $VMName enrollmssignatures
Invoke-VBox modifynvram $VMName enrollorclpk
Invoke-VBox modifynvram $VMName secureboot --enable

# Disk and controller; unattended install attaches the ISOs itself.
$disk = Join-Path $BaseFolder "$VMName\$VMName.vdi"
Invoke-VBox createmedium disk --filename $disk --size ($DiskGB * 1024) --variant Standard
Invoke-VBox storagectl $VMName --name SATA --add sata --controller IntelAhci --portcount 2
Invoke-VBox storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $disk

# Pass the password through a temp file so it never appears on a command line.
$pwFile = New-TemporaryFile
try {
    [IO.File]::WriteAllText($pwFile, [Net.NetworkCredential]::new('', $Password).Password)
    Invoke-VBox unattended install $VMName --iso="$IsoPath" --image-index=$ImageIndex `
        --user=$UserName --user-password-file="$pwFile" --full-user-name="SOC Analyst" `
        --hostname="$VMName.lab.local" --locale=en_US --country=US --time-zone="$TimeZone" `
        --install-additions --start-vm=gui
} finally {
    Remove-Item $pwFile -Force
}

Write-Host "Installation started. Windows will reboot a few times (~15-30 min); don't press keys in the VM."
