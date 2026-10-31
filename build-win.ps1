# ==================================================================
# x16-PRos -- The x16-PRos build script for Windows
# Copyright (C) 2025 PRoX2011
#
# Requirements:
#   * NASM in PATH (or in C:\utils\mingw64\bin)
#   * A POSIX shell with dosfstools + mtools for the FAT images.
#     Easiest on Windows is WSL:
#         wsl --install -d Ubuntu
#         sudo apt update && sudo apt install -y dosfstools mtools
#     Alternatively use MSYS2:
#         pacman -S dosfstools mingw-w64-x86_64-mtools
# ==================================================================

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ------------------------------------------------------------------
# Command line flags (same names as build-linux.sh)
# ------------------------------------------------------------------
$FlagQuiet = $false
$FlagNoMusic = $false
$FlagNoTxt = $false
$FlagForceBootRecomp = $false
$FlagForceKernelRecomp = $false
$FlagForceProgramsRecomp = $false
$FlagNoLogoDisplay = $false
$FlagNoSetup = $false
$FlagNoLog = $false
$FlagNoListDrivers = $false
$FlagNoAutoexec = $false
$FlagDtm = $false

function Print-Usage {
    Write-Host @"
Usage: .\build-win.ps1 [options]

  -quiet                  Do not print progress messages
  -no-music               Do not copy music files
  -no-txt                 Do not copy text/doc files
  -force-boot-recomp      Rebuild BOOT.BIN
  -force-kernel-recomp    Rebuild KERNEL.BIN
  -force-programs-recomp  Rebuild all programs
  -no-logo-display        Build kernel without the boot logo
  -no-setup               Build kernel/programs without SETUP
  -no-log                 Build kernel without logging
  -no-list-drivers        Build kernel without driver listing
  -no-autoexec            Build kernel without AUTOEXEC
  -dtm                    Dev Testing Mode (no log/setup/logo)
  -h, --help              Show this help
"@
}

foreach ($arg in $args) {
    $name = $arg.TrimStart('-').ToLowerInvariant()
    switch ($name) {
        'quiet'                 { $FlagQuiet = $true }
        'no-music'              { $FlagNoMusic = $true }
        'no-txt'                { $FlagNoTxt = $true }
        'force-boot-recomp'     { $FlagForceBootRecomp = $true }
        'force-kernel-recomp'   { $FlagForceKernelRecomp = $true }
        'force-programs-recomp' { $FlagForceProgramsRecomp = $true }
        'no-logo-display'       { $FlagNoLogoDisplay = $true }
        'no-setup'              { $FlagNoSetup = $true }
        'no-log'                { $FlagNoLog = $true }
        'no-list-drivers'       { $FlagNoListDrivers = $true }
        'no-autoexec'           { $FlagNoAutoexec = $true }
        'dtm'                   {
            $FlagDtm = $true
            $FlagNoLog = $true
            $FlagNoSetup = $true
            $FlagNoLogoDisplay = $true
        }
        'h'                     { Print-Usage; exit 0 }
        'help'                  { Print-Usage; exit 0 }
        default {
            Write-Host "[ FAILED ] Unknown argument: $arg" -ForegroundColor Red
            exit 1
        }
    }
}

$MaxKernelLoaderBytes = 57344   # 0xE000 - kernel image must end before disk_buffer
$KernelSizeWarnBytes = 55296    # 0xD800 - warn 2 KiB before the ceiling

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
function Print-Info {
    param([string]$Message)
    if (-not $script:FlagQuiet) {
        Write-Host "[ INFO ] $Message" -ForegroundColor Cyan
    }
}

function Print-Ok {
    param([string]$Message)
    if (-not $script:FlagQuiet) {
        Write-Host "[  OK  ] $Message" -ForegroundColor Green
    }
}

function Print-Failed {
    param([string]$Message)
    Write-Host "[ FAILED ] $Message" -ForegroundColor Red
    exit 1
}

function Print-SplitLine {
    param([string]$Message)
    if (-not $script:FlagQuiet) {
        Write-Host ""
        Write-Host "========== $Message ==========" -ForegroundColor Green
    }
}

function Get-FileSize {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Item -LiteralPath $Path).Length
    }
    return 0
}

function Test-SourceNewer {
    param([string]$Source, [string]$Output)
    if (-not (Test-Path -LiteralPath $Output)) {
        return $true
    }
    $srcTime = (Get-Item -LiteralPath $Source).LastWriteTimeUtc
    $outTime = (Get-Item -LiteralPath $Output).LastWriteTimeUtc
    return ($srcTime -gt $outTime)
}

function Find-Tool {
    param([string]$Name, [string[]]$ExtraPaths)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }
    foreach ($path in $ExtraPaths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function ConvertTo-WslPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function ConvertTo-MsysPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/$drive$rest"
}

function Quote-Bash {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function To-PosixRelative {
    param([string]$Path)
    return $Path.Replace('\', '/')
}

# Native tools (NASM, WSL, bash) may write warnings to stderr even when they
# succeed.  $ErrorActionPreference = 'Stop' would turn those into terminating
# errors, so native calls are wrapped here and checked via $NativeExitCode.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments
    }
    finally {
        $script:NativeExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previous
    }
}

function Add-DiskLine {
    param([string]$Line)
    $script:DiskLines.Add($Line) | Out-Null
}

function Add-DiskEcho {
    param([string]$Message)
    if (-not $script:FlagQuiet) {
        Add-DiskLine ("echo " + (Quote-Bash $Message))
    }
}

function Add-DiskCopy {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Label,
        [string]$Image = 'disk_img/x16pros.img',
        [switch]$Recursive
    )
    $opts = @()
    if ($Recursive) {
        $opts += '-s'
    }
    $opts += '-o'
    $src = To-PosixRelative $Source
    Add-DiskEcho "[ INFO ] Copying $Label..."
    Add-DiskLine ("mcopy " + ($opts -join ' ') + " -i $Image " + (Quote-Bash $src) + " " + (Quote-Bash $Destination))
    Add-DiskEcho "[  OK  ] $Label copied"
}

function Add-DiskMkdir {
    param([string]$Path, [string]$Label)
    Add-DiskEcho "[ INFO ] Creating $Label..."
    Add-DiskLine ("mmd -i disk_img/x16pros.img " + (Quote-Bash $Path))
    Add-DiskEcho "[  OK  ] $Label created"
}

# ------------------------------------------------------------------
# Locate tools
# ------------------------------------------------------------------
$Nasm = Find-Tool 'nasm' @(
    'C:\utils\mingw64\bin\nasm.exe',
    'C:\utils\msys64\mingw64\bin\nasm.exe',
    'C:\utils\msys64\usr\bin\nasm.exe',
    'C:\Program Files\NASM\nasm.exe'
)
if (-not $Nasm) {
    Print-Failed "NASM was not found. Install it (winget install NASM.NASM) or add nasm.exe to PATH."
}

$script:DiskRunner = $null
$script:DiskRunnerKind = $null

$wslCmd = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
if ($wslCmd -and $wslCmd.Source) {
    $wslCheck = 'command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 && command -v mmd >/dev/null 2>&1 && command -v mdir >/dev/null 2>&1 && command -v dd >/dev/null 2>&1'
    Invoke-Native $wslCmd.Source @('-e', 'bash', '-lc', $wslCheck) 2>$null
    if ($script:NativeExitCode -eq 0) {
        $script:DiskRunner = $wslCmd.Source
        $script:DiskRunnerKind = 'wsl'
    }
}

if (-not $script:DiskRunner) {
    $bashCandidates = @()
    $bashCmd = Get-Command 'bash.exe' -ErrorAction SilentlyContinue
    if ($bashCmd -and $bashCmd.Source -and ($bashCmd.Source -notmatch '\\Windows\\System32\\')) {
        $bashCandidates += $bashCmd.Source
    }
    $bashCandidates += @(
        'C:\utils\msys64\usr\bin\bash.exe',
        'C:\msys64\usr\bin\bash.exe',
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe'
    )
    foreach ($candidate in ($bashCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $bashCheck = 'export PATH=/usr/bin:/mingw64/bin:$PATH; command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 && command -v mmd >/dev/null 2>&1 && command -v mdir >/dev/null 2>&1 && command -v dd >/dev/null 2>&1'
        Invoke-Native $candidate @('-lc', $bashCheck) 2>$null
        if ($script:NativeExitCode -eq 0) {
            $script:DiskRunner = $candidate
            $script:DiskRunnerKind = 'bash'
            break
        }
    }
}

if (-not $script:DiskRunner) {
    Print-Failed @"
Disk image tools were not found.

Install one of the following:

  1) WSL (recommended):
       wsl --install -d Ubuntu
       (then in Ubuntu)
       sudo apt update && sudo apt install -y dosfstools mtools

  2) MSYS2:
       pacman -S dosfstools mingw-w64-x86_64-mtools

NASM is also required. QEMU is only required for run-win.ps1.
"@
}

# ------------------------------------------------------------------
# Old flags
# ------------------------------------------------------------------
$OldFlagForceKernelRecomp = -1
$OldFlagNoLogoDisplay = -1
$OldFlagNoLog = -1
$OldFlagNoListDrivers = -1
$OldFlagNoAutoexec = -1
$OldFlagNoSetup = -1

if (Test-Path -LiteralPath 'bin/flags.txt') {
    foreach ($line in Get-Content -LiteralPath 'bin/flags.txt') {
        if ($line -match '^\s*FLAG_([A-Z_]+)\s*=\s*(-?\d+)\s*$') {
            $key = $Matches[1]
            $value = [int]$Matches[2]
            switch ($key) {
                'FORCE_KERNEL_RECOMP' { $OldFlagForceKernelRecomp = $value }
                'NO_LOGO_DISPLAY'     { $OldFlagNoLogoDisplay = $value }
                'NO_LOG'              { $OldFlagNoLog = $value }
                'NO_LIST_DRIVERS'     { $OldFlagNoListDrivers = $value }
                'NO_AUTOEXEC'         { $OldFlagNoAutoexec = $value }
                'NO_SETUP'            { $OldFlagNoSetup = $value }
            }
        }
    }
}

New-Item -ItemType Directory -Force -Path 'bin' | Out-Null
New-Item -ItemType Directory -Force -Path 'disk_img' | Out-Null

Print-SplitLine "Starting x16-PRos build..."
Write-Host ""

# ------------------------------------------------------------------
# Save flags for incremental rebuilds
# ------------------------------------------------------------------
$flagsText = @(
    "FLAG_FORCE_BOOT_RECOMP=$([int]$FlagForceBootRecomp)",
    "FLAG_FORCE_KERNEL_RECOMP=$([int]$FlagForceKernelRecomp)",
    "FLAG_NO_LOGO_DISPLAY=$([int]$FlagNoLogoDisplay)",
    "FLAG_NO_LOG=$([int]$FlagNoLog)",
    "FLAG_NO_LIST_DRIVERS=$([int]$FlagNoListDrivers)",
    "FLAG_NO_AUTOEXEC=$([int]$FlagNoAutoexec)",
    "FLAG_NO_SETUP=$([int]$FlagNoSetup)"
) -join "`n"
[System.IO.File]::WriteAllText(
    (Join-Path $ScriptDir 'bin/flags.txt'),
    $flagsText + "`n",
    (New-Object System.Text.UTF8Encoding($false))
)

# ------------------------------------------------------------------
# Compile bootloader
# ------------------------------------------------------------------
$bootSrc = 'src/bootloader/boot.asm'
$bootOut = 'bin/BOOT.BIN'
if ($FlagForceBootRecomp -or (Test-SourceNewer $bootSrc $bootOut)) {
    Print-Info "Compiling bootloader (boot.asm => bin/BOOT.BIN)..."
    Invoke-Native $Nasm @('-f', 'bin', $bootSrc, '-o', $bootOut)
    if ($script:NativeExitCode -ne 0) {
        Print-Failed "Bootloader compilation failed"
    }
    Print-Ok "Bootloader compiled successfully"
}

# ------------------------------------------------------------------
# Compile kernel
# ------------------------------------------------------------------
$kernelSrc = 'src/kernel/kernel.asm'
$kernelOut = 'bin/KERNEL.BIN'
$kernelFlagsChanged = (
    ($([int]$FlagNoLogoDisplay) -ne $OldFlagNoLogoDisplay) -or
    ($([int]$FlagNoLog) -ne $OldFlagNoLog) -or
    ($([int]$FlagNoListDrivers) -ne $OldFlagNoListDrivers) -or
    ($([int]$FlagNoAutoexec) -ne $OldFlagNoAutoexec)
)

if ($FlagForceKernelRecomp -or (Test-SourceNewer $kernelSrc $kernelOut) -or $kernelFlagsChanged) {
    $kernelExtra = @()
    if ($FlagNoLogoDisplay) { $kernelExtra += @('-d', 'NO_LOGO_DISPLAY') }
    if ($FlagNoLog)         { $kernelExtra += @('-d', 'NO_LOG') }
    if ($FlagNoListDrivers) { $kernelExtra += @('-d', 'NO_LIST_DRIVES') }
    if ($FlagNoAutoexec)    { $kernelExtra += @('-d', 'NO_AUTOEXEC') }

    $baselineKernelSize = Get-FileSize $kernelOut
    Print-Info "Compiling kernel (kernel.asm => bin/KERNEL.BIN)..."
    Invoke-Native $Nasm (@('-f', 'bin', $kernelSrc, '-o', $kernelOut) + $kernelExtra)
    if ($script:NativeExitCode -ne 0) {
        Print-Failed "Kernel compilation failed"
    }
    Print-Ok "Kernel compiled successfully"

    $currentKernelSize = Get-FileSize $kernelOut
    if ($baselineKernelSize -gt 0) {
        $delta = $currentKernelSize - $baselineKernelSize
        $sign = '+'
        if ($delta -lt 0) { $sign = '' }
        Print-Info "Kernel size delta: $sign$delta bytes (baseline $baselineKernelSize)"
    }
    Print-Info "Current kernel size: $currentKernelSize bytes (~$([math]::Ceiling($currentKernelSize / 1024)) KiB)"
}

# ------------------------------------------------------------------
# Kernel size guard
# ------------------------------------------------------------------
$kernelSize = Get-FileSize $kernelOut
if ($kernelSize -le 0) {
    Print-Failed "Kernel image missing: bin/KERNEL.BIN"
}
Print-Info "Loader window limit: $MaxKernelLoaderBytes bytes"
if ($kernelSize -gt $KernelSizeWarnBytes) {
    Print-Info "Kernel size warning: $kernelSize bytes is close to loader limit"
}
if ($kernelSize -gt $MaxKernelLoaderBytes) {
    Print-Failed "Kernel too large for bootloader window ($kernelSize > $MaxKernelLoaderBytes)"
}

# ------------------------------------------------------------------
# Disk image assembly script
#
# The FAT tools (mkfs.fat/mcopy/mmd/mdir) are POSIX programs.  We
# collect all disk operations and run them once through WSL or an
# MSYS2/Git Bash shell.  Compilation itself is done by native NASM.
# ------------------------------------------------------------------
$script:DiskLines = New-Object System.Collections.Generic.List[string]

Add-DiskLine 'MKFS_VFAT=mkfs.vfat'
Add-DiskLine 'command -v "$MKFS_VFAT" >/dev/null 2>&1 || MKFS_VFAT=mkfs.fat'

# Main floppy
Add-DiskEcho "[ INFO ] Creating disk image (disk_img/x16pros.img)..."
Add-DiskLine 'dd if=/dev/zero of=disk_img/x16pros.img bs=512 count=2880 conv=notrunc status=none'
Add-DiskEcho "[  OK  ] Disk image created successfully"
Add-DiskEcho "[ INFO ] Formatting disk image..."
Add-DiskLine '"$MKFS_VFAT" disk_img/x16pros.img -n ''x16-PROS'' >/dev/null'
Add-DiskEcho "[  OK  ] Disk image formatted successfully"

# Second floppy
Add-DiskLine 'dd if=/dev/zero of=disk_img/FLOPPY2.img bs=512 count=2880 conv=notrunc status=none'
Add-DiskLine '"$MKFS_VFAT" disk_img/FLOPPY2.img -n ''x16-PROS'' >/dev/null'
Add-DiskEcho "[  OK  ] FLOPPY2.img created successfully"

# Hard disk
Print-SplitLine "Creating HDD image..."
Add-DiskEcho "[ INFO ] Creating 10 MiB HDD image..."
Add-DiskLine 'dd if=/dev/zero of=disk_img/HDD.img bs=1M count=10 status=none'
Add-DiskLine 'mkfs.fat -F 12 -s 8 -r 192 -a -n ''x16-PROS'' disk_img/HDD.img >/dev/null'
Add-DiskEcho "[  OK  ] HDD image created successfully"

if (Test-Path -LiteralPath 'assets/hdd_img') {
    $hddItems = @(Get-ChildItem -LiteralPath 'assets/hdd_img' -Force -ErrorAction SilentlyContinue)
    if ($hddItems.Count -gt 0) {
        Add-DiskEcho "[ INFO ] Copying files to HDD image..."
        foreach ($item in $hddItems) {
            $rel = To-PosixRelative $item.FullName.Substring($ScriptDir.Length).TrimStart('\', '/')
            Add-DiskCopy $rel '::/' $item.Name -Image 'disk_img/HDD.img' -Recursive
        }
    }
}

# Bootloader and kernel
Add-DiskEcho "[ INFO ] Writing bootloader to disk..."
Add-DiskLine 'dd status=none if=bin/BOOT.BIN of=disk_img/x16pros.img conv=notrunc'
Add-DiskEcho "[  OK  ] Bootloader written successfully"

Add-DiskCopy 'bin/KERNEL.BIN' '::/' 'KERNEL.BIN'

# Directories
Add-DiskMkdir '::/BIN.DIR' 'BIN directory'
Add-DiskMkdir '::/COM.DIR' 'COM directory'
Add-DiskMkdir '::/EXE.DIR' 'EXE directory'
Add-DiskMkdir '::/PLE.DIR' 'PLE directory'
Add-DiskMkdir '::/PLE.DIR/GUI.DIR' 'PLE/GUI directory'
Add-DiskMkdir '::/BMP.DIR' 'BMP directory'
Add-DiskMkdir '::/CONF.DIR' 'CONF directory'
Add-DiskMkdir '::/CONF.DIR/GUI.DIR' 'CONF/GUI directory'
Add-DiskMkdir '::/DOCS.DIR' 'DOCS directory'
Add-DiskMkdir '::/MUSIC.DIR' 'MUSIC directory'
Add-DiskMkdir '::/FONTS.DIR' 'FONTS directory'
Add-DiskMkdir '::/THEMES.DIR' 'THEMES directory'
Add-DiskMkdir '::/ASM.DIR' 'ASM directory'

# Fonts
$fontFiles = @('DEFAULT.FNT', 'BOLD.FNT', 'THIN.FNT', 'ITALIC.FNT', 'DOTS.FNT')
foreach ($font in $fontFiles) {
    Add-DiskCopy "assets/fonts/$font" '::/FONTS.DIR/' $font
}

# Themes
Print-SplitLine "Copying themes..."
$themeFiles = @(Get-ChildItem -LiteralPath 'assets/themes' -Filter '*.THM' -File -ErrorAction SilentlyContinue)
foreach ($theme in $themeFiles) {
    Add-DiskCopy ("assets/themes/" + $theme.Name) '::/THEMES.DIR/' $theme.Name
}

Write-Host ""

# Config files
$configFiles = @(
    @{ Src = 'src/kernel/configs/USER.CFG';       Dest = '::/CONF.DIR/'; Label = 'USER.CFG' },
    @{ Src = 'src/kernel/configs/FIRST_B.CFG';    Dest = '::/CONF.DIR/'; Label = 'FIRST_B.CFG' },
    @{ Src = 'src/kernel/configs/PASSWORD.CFG';   Dest = '::/CONF.DIR/'; Label = 'PASSWORD.CFG' },
    @{ Src = 'src/kernel/configs/TIMEZONE.CFG';   Dest = '::/CONF.DIR/'; Label = 'TIMEZONE.CFG' },
    @{ Src = 'src/kernel/configs/PROMPT.CFG';     Dest = '::/CONF.DIR/'; Label = 'PROMPT.CFG' },
    @{ Src = 'src/kernel/configs/THEME.CFG';      Dest = '::/CONF.DIR/'; Label = 'THEME.CFG' },
    @{ Src = 'src/kernel/configs/FONT.CFG';       Dest = '::/CONF.DIR/'; Label = 'FONT.CFG' },
    @{ Src = 'src/kernel/configs/XMS.CFG';        Dest = '::/CONF.DIR/'; Label = 'XMS.CFG' },
    @{ Src = 'src/kernel/configs/gui/IC_ROUND.CFG'; Dest = '::/CONF.DIR/GUI.DIR/'; Label = 'IC_ROUND.CFG' },
    @{ Src = 'src/kernel/configs/gui/NAME_GAP.CFG'; Dest = '::/CONF.DIR/GUI.DIR/'; Label = 'NAME_GAP.CFG' },
    @{ Src = 'src/kernel/configs/SYSTEM.CFG';     Dest = '::/';          Label = 'SYSTEM.CFG' }
)
foreach ($cfg in $configFiles) {
    Add-DiskCopy $cfg.Src $cfg.Dest $cfg.Label
}

# ------------------------------------------------------------------
# Compile and copy programs
# ------------------------------------------------------------------
function Build-ProgramSet {
    param(
        [array]$Programs,
        [string[]]$ExtraArgs,
        [bool]$Force,
        [switch]$RootPrograms
    )

    foreach ($prog in $Programs) {
        $outPath = "bin/$($prog.Out)"
        $needBuild = $Force -or (Test-SourceNewer $prog.Src $outPath)
        if ($RootPrograms -and ($([int]$FlagNoSetup) -ne $OldFlagNoSetup)) {
            $needBuild = $true
        }

        if ($needBuild) {
            Print-Info "Compiling $($prog.Src) => $outPath..."
            Invoke-Native $Nasm (@('-f', 'bin', $prog.Src, '-o', $outPath) + $ExtraArgs)
            if ($script:NativeExitCode -ne 0) {
                Print-Failed "Compilation of $($prog.Src) failed"
            }
            Print-Ok "$($prog.Out) compiled successfully"
        }

        Add-DiskCopy $outPath $prog.Dest $prog.Out
    }
}

$rootExtra = @()
if ($FlagNoSetup) {
    $rootExtra += @('-d', 'NO_SETUP')
}

$programsRoot = @(
    @{ Src = 'programs/autoexec.asm';   Out = 'AUTOEXEC.BIN'; Dest = '::/' },
    @{ Src = 'programs/setup/setup.asm'; Out = 'SETUP.BIN';    Dest = '::/' }
)
Print-SplitLine "Compiling and copying programs..."
Build-ProgramSet -Programs $programsRoot -ExtraArgs $rootExtra -Force:$FlagForceProgramsRecomp -RootPrograms

$programsBin = @(
    @{ Src = 'programs/help.asm';      Out = 'HELP.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/grep.asm';      Out = 'GREP.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/ps.asm';        Out = 'PS.BIN';        Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/kill.asm';      Out = 'KILL.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/head.asm';      Out = 'HEAD.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/tail.asm';      Out = 'TAIL.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/cpu.asm';       Out = 'CPU.BIN';       Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/dlist.asm';     Out = 'DLIST.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/theme.asm';     Out = 'THEME.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/fetch.asm';     Out = 'FETCH.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/imfplay.asm';   Out = 'IMFPLAY.BIN';   Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/wavplay.asm';   Out = 'WAVPLAY.BIN';   Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/credits.asm';   Out = 'CREDITS.BIN';   Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/hello.asm';     Out = 'HELLO.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/write.asm';     Out = 'WRITER.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/barchart.asm';  Out = 'BCHART.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/brainf.asm';    Out = 'BRAINF.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/calc.asm';      Out = 'CALC.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/memory.asm';    Out = 'MEMORY.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/mine.asm';      Out = 'MINE.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/piano.asm';     Out = 'PIANO.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/snake.asm';     Out = 'SNAKE.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/space.asm';     Out = 'SPACE.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/procentc.asm';  Out = 'PROCENTC.BIN';  Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/paint.asm';     Out = 'PAINT.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/pong.asm';      Out = 'PONG.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/hexedit.asm';   Out = 'HEXEDIT.BIN';   Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/clock.asm';     Out = 'CLOCK.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/mandel.asm';    Out = 'MANDEL.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/tetris.asm';    Out = 'TETRIS.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/tetris-df.asm'; Out = 'TETRIS2.BIN';   Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/chars.asm';     Out = 'CHARS.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/eye.asm';       Out = 'EYE.BIN';       Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/ed.asm';        Out = 'ED.BIN';        Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/fdisk.asm';     Out = 'FDISK.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/launch.asm';    Out = 'LAUNCH.BIN';    Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/font.asm';      Out = 'FONT.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/tree.asm';      Out = 'TREE.BIN';      Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/print.asm';     Out = 'PRINT.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/calendar.asm';  Out = 'CALENDAR.BIN';  Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/settings.asm';  Out = 'SETTINGS.BIN';  Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/prasm.asm';     Out = 'PRASM.BIN';     Dest = '::/BIN.DIR/' },
    @{ Src = 'programs/bigc.asm';      Out = 'BIGC.BIN';      Dest = '::/BIN.DIR/' }
)
Build-ProgramSet -Programs $programsBin -ExtraArgs @() -Force:$FlagForceProgramsRecomp

$programsCom = @(
    @{ Src = 'programs/COM/hello.asm';   Out = 'HELLO.COM';   Dest = '::/COM.DIR/' },
    @{ Src = 'programs/COM/fractal.asm'; Out = 'FRACTAl.COM'; Dest = '::/COM.DIR/' },
    @{ Src = 'programs/COM/clock.asm';   Out = 'CLOCK.COM';   Dest = '::/COM.DIR/' }
)
Build-ProgramSet -Programs $programsCom -ExtraArgs @() -Force:$FlagForceProgramsRecomp

$programsExe = @(
    @{ Src = 'programs/EXE/hello.asm'; Out = 'HELLO.EXE'; Dest = '::/EXE.DIR/' }
)
Build-ProgramSet -Programs $programsExe -ExtraArgs @('-I', 'programs/EXE/') -Force:$FlagForceProgramsRecomp

$programsPle = @(
    @{ Src = 'programs/PLE/src/hello.asm';      Out = 'HELLO.PLE'; Dest = '::/PLE.DIR/' },
    @{ Src = 'programs/PLE/src/clock.asm';      Out = 'CLOCK.PLE'; Dest = '::/PLE.DIR/' },
    @{ Src = 'programs/PLE/src/gui/gui.asm';    Out = 'GUI.PLE';   Dest = '::/PLE.DIR/' },
    @{ Src = 'programs/PLE/src/xms.asm';        Out = 'XMS.PLE';   Dest = '::/PLE.DIR/' }
)
Build-ProgramSet -Programs $programsPle -ExtraArgs @('-I', 'programs/PLE/', '-I', 'programs/lib/', '-I', 'programs/PLE/src/gui/') -Force:$FlagForceProgramsRecomp

$programsPleGui = @(
    @{ Src = 'programs/PLE/src/windowed/eyes.asm';     Out = 'EYES.PLE';     Dest = '::/PLE.DIR/GUI.DIR/' },
    @{ Src = 'programs/PLE/src/windowed/clock.asm';    Out = 'CLOCK.PLE';    Dest = '::/PLE.DIR/GUI.DIR/' },
    @{ Src = 'programs/PLE/src/windowed/hello.asm';    Out = 'HELLO.PLE';    Dest = '::/PLE.DIR/GUI.DIR/' },
    @{ Src = 'programs/PLE/src/windowed/calc.asm';     Out = 'CALC.PLE';     Dest = '::/PLE.DIR/GUI.DIR/' },
    @{ Src = 'programs/PLE/src/windowed/settings.asm'; Out = 'SETTINGS.PLE'; Dest = '::/PLE.DIR/GUI.DIR/' },
    @{ Src = 'programs/PLE/src/windowed/notepad.asm';  Out = 'NOTEPAD.PLE';  Dest = '::/PLE.DIR/GUI.DIR/' }
)
Build-ProgramSet -Programs $programsPleGui -ExtraArgs @('-I', 'programs/PLE/', '-I', 'programs/lib/') -Force:$FlagForceProgramsRecomp

# ------------------------------------------------------------------
# ASM sources usable with prasm
# ------------------------------------------------------------------
Print-SplitLine "Copying ASM files..."
$asmFiles = @('HELLO.ASM', 'TIME.ASM', 'DATE.ASM')
foreach ($asm in $asmFiles) {
    Add-DiskCopy "assets/ASM/$asm" '::/ASM.DIR/' $asm
}

# ------------------------------------------------------------------
# Text and documentation
# ------------------------------------------------------------------
if (-not $FlagNoTxt) {
    Print-SplitLine "Copying text files..."
    Add-DiskCopy 'LICENSE.TXT' '::/' 'LICENSE.TXT'
    Add-DiskCopy 'project_philosophy.txt' '::/PROJECT.TXT' 'PROJECT.TXT'

    $docNames = @(
        'README.TXT', 'CONFIGS.TXT', 'FILESYS.TXT', 'LIMITS.TXT',
        'PROGRAMS.TXT', 'QUICKST.TXT', 'COMMANDS.TXT', 'EDMAN.TXT', 'PRASM.TXT'
    )

    Add-DiskMkdir '::/DOCS.DIR/EN.DIR' 'DOCS.DIR/EN.DIR directory'
    Add-DiskMkdir '::/DOCS.DIR/RU.DIR' 'DOCS.DIR/RU.DIR directory'

    foreach ($name in $docNames) {
        Add-DiskCopy "src/txt/$name" '::/DOCS.DIR/EN.DIR/' "$name (EN)"
    }
    foreach ($name in $docNames) {
        Add-DiskCopy "src/txt/RU/$name" '::/DOCS.DIR/RU.DIR/' "$name (RU)"
    }
}

# ------------------------------------------------------------------
# Images
# ------------------------------------------------------------------
Print-SplitLine "Copying image files..."
$imageFiles = @(
    'assets/images/logo/LOGO.BMP',
    'assets/images/PROX.BMP',
    'assets/images/PROS.BMP',
    'assets/images/PROS_W.BMP',
    'assets/images/PROS_A.BMP',
    'assets/images/TRAIN.BMP',
    'assets/images/CHILL.BMP'
)
foreach ($image in $imageFiles) {
    $leaf = Split-Path -Leaf $image
    Add-DiskCopy $image '::/BMP.DIR/' $leaf
}

# ------------------------------------------------------------------
# Music
# ------------------------------------------------------------------
if (-not $FlagNoMusic) {
    Print-SplitLine "Copying music files..."
    $musicFiles = @(
        'assets/IMF/RICK.IMF',
        'assets/IMF/SONIC.IMF',
        'assets/IMF/HOPES&D.IMF',
        'assets/IMF/RUSSIA.IMF',
        'assets/IMF/METRO_E.IMF',
        'assets/IMF/METRO_E2.IMF',
        'assets/IMF/GTA_VC.IMF',
        'assets/IMF/CYBWRLD.IMF',
        'assets/IMF/BIGSHOT.IMF',
        'assets/IMF/DF.IMF',
        'assets/IMF/TRUEHERO.IMF',
        'assets/IMF/CORE.IMF',
        'assets/WAV/1985.WAV'
    )
    foreach ($music in $musicFiles) {
        $leaf = Split-Path -Leaf $music
        Add-DiskCopy $music '::/MUSIC.DIR/' $leaf
    }
}

if (-not $FlagQuiet) {
    Add-DiskEcho ""
    Add-DiskLine 'echo "Disk contents:"'
    Add-DiskLine 'mdir -i disk_img/x16pros.img ::/'
}

# ------------------------------------------------------------------
# Run the disk assembly script
# ------------------------------------------------------------------
function Invoke-DiskBuild {
    $tempScript = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ("x16pros-disk-" + [System.Guid]::NewGuid().ToString('N') + ".sh")
    )
    $tempError = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ("x16pros-disk-" + [System.Guid]::NewGuid().ToString('N') + ".err")
    )

    $header = @(
        '#!/usr/bin/env bash',
        'set -e',
        'export LC_ALL=C',
        'export PATH=/usr/sbin:/sbin:$PATH',
        'trap ''echo "[ FAILED ] disk image step failed at line $LINENO" >&2'' ERR'
    )
    $content = ($header + $script:DiskLines) -join "`n"
    [System.IO.File]::WriteAllText($tempScript, $content + "`n", (New-Object System.Text.UTF8Encoding($false)))

    try {
        if ($script:DiskRunnerKind -eq 'wsl') {
            $wslScript = ConvertTo-WslPath $tempScript
            $wslRoot = ConvertTo-WslPath $ScriptDir
            Invoke-Native $script:DiskRunner @('-e', 'bash', '-lc', ("cd " + (Quote-Bash $wslRoot) + " && bash " + (Quote-Bash $wslScript))) 2> $tempError
            $exitCode = $script:NativeExitCode
        }
        else {
            $msysScript = ConvertTo-MsysPath $tempScript
            $msysRoot = ConvertTo-MsysPath $ScriptDir
            Invoke-Native $script:DiskRunner @('-lc', ("export PATH=/usr/bin:/mingw64/bin:`$PATH; cd " + (Quote-Bash $msysRoot) + " && bash " + (Quote-Bash $msysScript))) 2> $tempError
            $exitCode = $script:NativeExitCode
        }
    }
    catch {
        Print-Failed ("Disk image creation failed: " + $_.Exception.Message)
    }

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $tempError) {
            $errorText = Get-Content -LiteralPath $tempError -Raw -ErrorAction SilentlyContinue
            if ($errorText -and $errorText.Trim().Length -gt 0) {
                Write-Host $errorText
            }
        }
        Print-Failed "Disk image creation failed. The generated script is kept at: $tempScript"
    }

    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempError -Force -ErrorAction SilentlyContinue
}

Print-SplitLine "Assembling disk images..."
Invoke-DiskBuild

Print-SplitLine "Build completed successfully!"
