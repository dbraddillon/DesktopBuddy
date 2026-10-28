<#
.SYNOPSIS
  Pushes weather + home-lab health to the DesktopBuddy over USB serial, but only
  while this PC's displays are on. The device blanks itself ~75s after the pushes stop.

.DESCRIPTION
  Presence = Windows' own display state (GUID_CONSOLE_DISPLAY_STATE). Displays off,
  lid closed, or machine asleep -> nothing is sent -> device sleeps.
  Not covered: a monitor switched off at its own power button when Windows still
  thinks the display is on.

  Holds the COM port open, so `pio run -t upload` and serial monitors will fail
  while it runs. Stop it first:  Stop-ScheduledTask DesktopBuddyDash
  (tools/register-dash-task.ps1 installs it as a logon task.)

.PARAMETER Port
  COM port. Default: auto-detect the CH9102 USB-serial chip the M5StickC Plus uses.
.PARAMETER Lat / Lon
  Weather location. Default: $env:DASH_LAT / $env:DASH_LON, else a one-time IP
  lookup (ipwho.is), cached in %LOCALAPPDATA%\DesktopBuddy\location.json.
#>
[CmdletBinding()]
param(
  [string]$Port,
  [double]$Lat = [double]($env:DASH_LAT ?? 0),
  [double]$Lon = [double]($env:DASH_LON ?? 0),
  [int]$IntervalSec = 15,
  [int]$HealthEverySec = 60,
  [int]$WeatherEverySec = 600,
  [string[]]$Urls = @(
    'https://basementlab.dev', 'https://auth.basementlab.dev', 'https://status.basementlab.dev',
    'https://ops.basementlab.dev', 'https://watch.basementlab.dev', 'https://alexa-ha.basementlab.dev'
  ),
  [string]$CertHost = 'basementlab.dev',
  [int]$CertWarnDays = 21
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'DesktopBuddy'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$log = Join-Path $stateDir 'dash-sender.log'
function Log($m) {
  "$(Get-Date -Format 's') $m" | Add-Content $log
  if ((Get-Item $log).Length -gt 512KB) { Get-Content $log -Tail 200 | Set-Content "$log.tmp"; Move-Item -Force "$log.tmp" $log }
}

# --- display state: 0 off, 1 on, 2 dimmed -----------------------------------
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Windows.Forms.Primitives, System.Drawing, System.Threading.Thread -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading; using System.Windows.Forms;
public static class DisplayWatch {
  public static volatile int State = 1;
  static Guid G = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");  // GUID_CONSOLE_DISPLAY_STATE
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  struct PBS { public Guid PowerSetting; public int DataLength; public int Data; }
  [DllImport("user32.dll", SetLastError = true)]
  static extern IntPtr RegisterPowerSettingNotification(IntPtr h, ref Guid g, int flags);
  sealed class Win : NativeWindow {
    public Win() { CreateHandle(new CreateParams()); RegisterPowerSettingNotification(Handle, ref G, 0); }
    protected override void WndProc(ref Message m) {
      if (m.Msg == 0x218 && m.WParam.ToInt32() == 0x8013) {  // WM_POWERBROADCAST / PBT_POWERSETTINGCHANGE
        var s = (PBS)Marshal.PtrToStructure(m.LParam, typeof(PBS));
        if (s.PowerSetting == G) State = s.Data;
      }
      base.WndProc(ref m);
    }
  }
  public static void Start() {
    var t = new Thread(() => { new Win(); Application.Run(); });
    t.SetApartmentState(ApartmentState.STA); t.IsBackground = true; t.Start();
  }
}
'@
[DisplayWatch]::Start()

# --- location ---------------------------------------------------------------
if (-not $Lat -and -not $Lon) {
  $locFile = Join-Path $stateDir 'location.json'
  if (-not (Test-Path $locFile)) {
    $r = Invoke-RestMethod 'https://ipwho.is/' -TimeoutSec 15
    @{ lat = $r.latitude; lon = $r.longitude; place = "$($r.city), $($r.region_code)" } | ConvertTo-Json | Set-Content $locFile
  }
  $loc = Get-Content $locFile -Raw | ConvertFrom-Json
  $Lat = $loc.lat; $Lon = $loc.lon
  Log "location from IP lookup: $($loc.place) ($Lat,$Lon) -- override with DASH_LAT/DASH_LON or edit $locFile"
}

# --- weather ----------------------------------------------------------------
function Get-Cond([int]$c) {
  switch ($c) {
    0 { 'Clear' } { $_ -in 1, 2 } { 'Partly cloudy' } 3 { 'Cloudy' } { $_ -in 45, 48 } { 'Fog' }
    { $_ -in 51..57 } { 'Drizzle' } { $_ -in 61..67 } { 'Rain' } { $_ -in 71..77 -or $_ -in 85, 86 } { 'Snow' }
    { $_ -in 80..82 } { 'Showers' } { $_ -ge 95 } { 'Storm' } default { '' }
  }
}
function Get-Weather {
  $u = "https://api.open-meteo.com/v1/forecast?latitude=$Lat&longitude=$Lon&current=temperature_2m,weather_code" +
       "&daily=temperature_2m_max,temperature_2m_min&temperature_unit=fahrenheit&timezone=auto&forecast_days=1"
  $r = Invoke-RestMethod $u -TimeoutSec 15
  [ordered]@{
    temp = [int][math]::Round($r.current.temperature_2m)
    hi   = [int][math]::Round($r.daily.temperature_2m_max[0])
    lo   = [int][math]::Round($r.daily.temperature_2m_min[0])
    cond = Get-Cond ([int]$r.current.weather_code)
  }
}

# --- health -----------------------------------------------------------------
function Get-CertDaysLeft([string]$h) {
  $tcp = [Net.Sockets.TcpClient]::new()
  try {
    $tcp.Connect($h, 443)
    $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
    $ssl.AuthenticateAsClient($h)
    [int]([datetime]$ssl.RemoteCertificate.GetExpirationDateString() - (Get-Date)).TotalDays
  } finally { $tcp.Dispose() }
}
function Get-Health {
  # Anything that answers below 500 counts as up (auth walls return 401/403/302), same rule as Watchtower.
  $down = $Urls | ForEach-Object -Parallel {
    try {
      $s = (Invoke-WebRequest $_ -Method Head -TimeoutSec 8 -SkipHttpErrorCheck -MaximumRedirection 0).StatusCode
      if ($s -ge 500) { ([uri]$_).Host.Split('.')[0] }
    } catch { ([uri]$_).Host.Split('.')[0] }
  } -ThrottleLimit 8
  $cert = $null; try { $cert = Get-CertDaysLeft $CertHost } catch { Log "cert check failed: $($_.Exception.Message)" }

  if ($down) { return @{ health = 2; note = "down: $(@($down) -join ' ')" } }
  if ($null -eq $cert) { return @{ health = 1; note = 'cert check failed' } }
  if ($cert -lt $CertWarnDays) { return @{ health = 1; note = "tls cert $($cert)d left" } }
  @{ health = 0; note = "all ok  tls $($cert)d" }
}

# --- serial -----------------------------------------------------------------
function Find-Port {
  if ($Port) { return $Port }
  $d = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'CH9102.*\((COM\d+)\)' } | Select-Object -First 1
  if ($d -and $d.Name -match '\((COM\d+)\)') { return $Matches[1] }
  throw 'no CH9102 serial device found; pass -Port'
}
$ser = $null
function Close-Serial { if ($ser) { try { $ser.Close() } catch {}; $ser.Dispose(); $script:ser = $null } }
function Send-Line([string]$json) {
  if (-not $ser -or -not $ser.IsOpen) {
    $p = Find-Port
    $s = [IO.Ports.SerialPort]::new($p, 115200)
    $s.DtrEnable = $false; $s.RtsEnable = $false   # CH9102 DTR/RTS are wired to EN/IO0; asserting them resets the stick
    $s.Open()
    $script:ser = $s
    Log "opened $p"
  }
  $ser.DiscardInBuffer()   # firmware prints debug lines; nobody reads them
  $ser.WriteLine($json)
}

# --- main loop --------------------------------------------------------------
Log "start: interval=${IntervalSec}s display-gated"
$wx = $null; $wxAt = [datetime]::MinValue
$hl = @{ health = 1; note = 'checking...' }; $hlAt = [datetime]::MinValue
$wasOn = $true
while ($true) {
  try {
    $on = [DisplayWatch]::State -ne 0
    if ($on -ne $wasOn) { Log "display $(if ($on) {'on'} else {'off -> pausing pushes'})"; $wasOn = $on }
    if ($on) {
      if (((Get-Date) - $wxAt).TotalSeconds -ge $WeatherEverySec) {
        try { $wx = Get-Weather } catch { Log "weather failed: $($_.Exception.Message)" }   # keep last good value
        $wxAt = Get-Date
      }
      if (((Get-Date) - $hlAt).TotalSeconds -ge $HealthEverySec) {
        try { $hl = Get-Health } catch { Log "health failed: $($_.Exception.Message)"; $hl = @{ health = 1; note = 'health check error' } }
        $hlAt = Get-Date
      }
      $tz = [int][TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now).TotalSeconds
      $d = [ordered]@{ health = $hl.health; note = $hl.note; ts = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); tz = $tz }
      if ($wx) { foreach ($k in $wx.Keys) { $d[$k] = $wx[$k] } }
      Send-Line (@{ dash = $d } | ConvertTo-Json -Compress)
    } else {
      Close-Serial   # frees the port while the displays are off, so flashing works then
    }
  } catch {
    Log "loop error: $($_.Exception.Message)"
    Close-Serial
  }
  Start-Sleep -Seconds $IntervalSec
}
