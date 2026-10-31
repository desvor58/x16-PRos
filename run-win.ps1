# ==================================================================
# x16-PRos -- The x16-PRos run script for Windows
# Copyright (C) 2025 PRoX2011
#
# Requirements:
#   * QEMU for Windows (qemu-system-x86_64 in PATH, or in a standard
#     install location).  MSYS2: pacman -S mingw-w64-x86_64-qemu
#   * Disk images produced by build-win.ps1 (disk_img/*.img)
# ==================================================================

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Print-Msg {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

function Find-Qemu {
    $cmd = Get-Command 'qemu-system-x86_64' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }
    $candidates = @(
        'C:\utils\msys64\mingw64\bin\qemu-system-x86_64.exe',
        'C:\msys64\mingw64\bin\qemu-system-x86_64.exe',
        'C:\Program Files\qemu\qemu-system-x86_64.exe',
        'C:\Program Files (x86)\qemu\qemu-system-x86_64.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

$NoAudio = $false
foreach ($arg in $args) {
    $name = $arg.TrimStart('-').ToLowerInvariant()
    switch ($name) {
        'no-audio' { $NoAudio = $true }
        'h'        { Write-Host 'Usage: .\run-win.ps1 [-no-audio]'; exit 0 }
        'help'     { Write-Host 'Usage: .\run-win.ps1 [-no-audio]'; exit 0 }
        default {
            Print-Msg "[ FAILED ] Unknown argument: $arg" 'Red'
            exit 1
        }
    }
}

$Qemu = Find-Qemu
if (-not $Qemu) {
    Print-Msg '[ FAILED ] qemu-system-x86_64 was not found.' 'Red'
    Print-Msg 'Install QEMU (winget install SoftwareFreedomConservancy.QEMU) or add it to PATH.' 'Red'
    exit 1
}

foreach ($image in @('disk_img/x16pros.img', 'disk_img/FLOPPY2.img', 'disk_img/HDD.img')) {
    if (-not (Test-Path -LiteralPath $image)) {
        Print-Msg "[ FAILED ] Missing disk image: $image" 'Red'
        Print-Msg 'Run .\build-win.ps1 first.' 'Red'
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path 'lpt' | Out-Null

# Windows QEMU builds use dsound/sdl instead of PulseAudio.  Prefer dsound
# when available and fall back to no audio otherwise.
$AudioDriver = 'none'
if (-not $NoAudio) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $audioHelp = (& $Qemu -audiodev help 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($audioHelp -match '(?m)^\s*dsound\s*$') {
        $AudioDriver = 'dsound'
    }
    elseif ($audioHelp -match '(?m)^\s*sdl\s*$') {
        $AudioDriver = 'sdl'
    }
}

$QemuArgs = @(
    '-display', 'gtk',
    '-fda', 'disk_img/x16pros.img',
    '-machine', 'pcspk-audiodev=snd0',
    '-device', 'adlib,audiodev=snd0',
    '-audiodev', "$AudioDriver,id=snd0",
    '-drive', 'format=raw,file=disk_img/FLOPPY2.img,if=floppy,index=1',
    '-drive', 'format=raw,file=disk_img/HDD.img,if=ide,index=0,media=disk',
    '-boot', 'order=a',
    '-parallel', 'file:lpt/output.txt'
)

Print-Msg ''
if ($AudioDriver -eq 'none') {
    Print-Msg 'Starting emulator (audio disabled)...' 'Green'
}
else {
    Print-Msg "Starting emulator (audio: $AudioDriver)..." 'Green'
}

# QEMU may write warnings to stderr; keep them visible without aborting.
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $Qemu @QemuArgs
}
finally {
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previous
}

exit $exitCode
