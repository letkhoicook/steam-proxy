<# :
@echo off
rem One-step install/uninstall for steam-proxy. Double-click for a menu, or run:
rem   setup.bat install     start at login + Windows proxy setting + start now
rem   setup.bat uninstall   stop proxy, remove login shortcut and proxy setting
rem The rest of this file is PowerShell; cmd only runs this first block.
setlocal
set "SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath $env:SELF -Raw))) %*"
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
#>
param([string]$Action)
$ErrorActionPreference = 'Stop'

$Port   = 8881
$Dir    = Split-Path -Parent $env:SELF
$Script = Join-Path $Dir 'steam_proxy.py'
$PacUrl = "http://127.0.0.1:$Port/proxy.pac"
$Lnk    = Join-Path ([Environment]::GetFolderPath('Startup')) 'steam-proxy.lnk'
$InetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# Changes the Windows proxy through WinINet so the Settings app, browsers and Steam all see it
# right away (writing the registry value alone isn't always picked up).
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinInetProxy {
    [StructLayout(LayoutKind.Sequential)] struct Opt { public int Option; public IntPtr Value; }
    [StructLayout(LayoutKind.Sequential)] struct OptList { public int Size; public IntPtr Connection; public int Count; public int Error; public IntPtr Options; }
    [DllImport("wininet.dll", EntryPoint = "InternetSetOptionW", SetLastError = true)]
    static extern bool InternetSetOption(IntPtr h, int option, IntPtr buf, int len);

    // flags: 1 = direct, 2 = manual proxy, 4 = setup script (PAC), 8 = auto-detect
    public static void Set(int flags, string pacUrl) {
        int sz = Marshal.SizeOf(typeof(Opt));
        IntPtr opts = Marshal.AllocCoTaskMem(sz * 2);
        IntPtr url = Marshal.StringToCoTaskMemUni(pacUrl);
        IntPtr list = IntPtr.Zero;
        try {
            Marshal.StructureToPtr(new Opt { Option = 1, Value = (IntPtr)flags }, opts, false);
            Marshal.StructureToPtr(new Opt { Option = 4, Value = url }, opts + sz, false);
            var l = new OptList { Size = Marshal.SizeOf(typeof(OptList)), Count = 2, Options = opts };
            list = Marshal.AllocCoTaskMem(l.Size);
            Marshal.StructureToPtr(l, list, false);
            if (!InternetSetOption(IntPtr.Zero, 75, list, l.Size))  // PER_CONNECTION_OPTION
                throw new System.ComponentModel.Win32Exception();
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0);     // SETTINGS_CHANGED
            InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);     // REFRESH
        } finally {
            Marshal.FreeCoTaskMem(opts); Marshal.FreeCoTaskMem(url);
            if (list != IntPtr.Zero) Marshal.FreeCoTaskMem(list);
        }
    }
}
'@

function Get-ProxyFlags {
    # byte 8 of DefaultConnectionSettings holds the current flags
    $blob = (Get-ItemProperty "$InetKey\Connections" -ErrorAction SilentlyContinue).DefaultConnectionSettings
    if ($blob -and $blob.Length -gt 8) { [int]$blob[8] } else { 1 }
}

function Get-CurrentPac { (Get-ItemProperty $InetKey -ErrorAction SilentlyContinue).AutoConfigURL }

function Find-Pythonw {
    $exe = Get-Command pythonw.exe -All -ErrorAction SilentlyContinue |
        Where-Object Source -notmatch 'WindowsApps' | Select-Object -First 1 -ExpandProperty Source
    if (-not $exe) {
        $py = Get-Command python.exe -All -ErrorAction SilentlyContinue |
            Where-Object Source -notmatch 'WindowsApps' | Select-Object -First 1 -ExpandProperty Source
        if ($py) { $exe = Join-Path (Split-Path $py) 'pythonw.exe' }
    }
    if (-not $exe -or -not (Test-Path $exe)) {
        throw 'Python 3.8+ was not found. Install it from https://www.python.org/downloads/ (tick "Add python.exe to PATH") and run setup again.'
    }
    $exe
}

function Stop-Proxy {
    $pids = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p"
        if ($proc.CommandLine -match 'steam_proxy\.py') {
            Stop-Process -Id $p -Force
            Write-Host "  Stopped running proxy (PID $p)."
        } else {
            throw "Port $Port is used by another program ($($proc.Name), PID $p). Close it and try again."
        }
    }
}

function Install {
    if (-not (Test-Path $Script)) { throw "steam_proxy.py not found next to setup.bat ($Dir)." }
    $current = Get-CurrentPac
    if ($current -and $current -ne $PacUrl) {
        throw "Windows already uses another setup script ($current), maybe from your company. Not overwriting it; use open-steam.bat instead."
    }
    $pyw = Find-Pythonw
    Write-Host "Installing steam-proxy (Python: $pyw)"

    Stop-Proxy

    $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($Lnk)
    $sh.TargetPath = $pyw
    $sh.Arguments = "-I `"$Script`""
    $sh.WorkingDirectory = $Dir
    $sh.Description = 'Local proxy for the Steam store'
    $sh.Save()
    Write-Host '  Added login shortcut (starts automatically after every sign-in).'

    Start-Process -FilePath $pyw -ArgumentList '-I', "`"$Script`"" -WorkingDirectory $Dir -WindowStyle Hidden
    $ok = $false
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
        Start-Sleep -Milliseconds 250
        try { $ok = (Invoke-WebRequest $PacUrl -UseBasicParsing -TimeoutSec 2).RawContent -match 'FindProxyForURL' } catch {}
    }
    if (-not $ok) { throw "The proxy did not start. Run: python `"$Script`" to see the error." }
    Write-Host "  Proxy running on 127.0.0.1:$Port."

    [WinInetProxy]::Set(((Get-ProxyFlags) -bor 4 -bor 1), $PacUrl)
    Write-Host "  Windows proxy setup script set to $PacUrl"
    Write-Host ''
    Write-Host 'Done. Restart Steam / your browser and open the Steam store.' -ForegroundColor Green
}

function Uninstall {
    Write-Host 'Uninstalling steam-proxy'
    if ((Get-CurrentPac) -eq $PacUrl) {
        [WinInetProxy]::Set((((Get-ProxyFlags) -band (-bnot 4)) -bor 1), '')
        Write-Host '  Removed Windows proxy setup script.'
    }
    if (Test-Path $Lnk) { Remove-Item $Lnk -Force; Write-Host '  Removed login shortcut.' }
    Stop-Proxy
    Write-Host ''
    Write-Host 'Done. Your files in this folder were left as they are; delete the folder to remove everything.' -ForegroundColor Green
}

try {
    if (-not $Action) {
        Write-Host 'steam-proxy setup'
        Write-Host '  1. Install'
        Write-Host '  2. Uninstall'
        $Action = @{ '1' = 'install'; '2' = 'uninstall' }[(Read-Host 'Choose 1 or 2').Trim()]
    }
    switch ($Action) {
        'install'   { Install }
        'uninstall' { Uninstall }
        default     { throw 'Usage: setup.bat [install|uninstall]' }
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
