# Dev machine setup — checklist for Claude on machine X

## Build / flash (Windows, AMDThinkPad)
- [ ] PlatformIO venv must match an installed Python. If `pio` says `No Python at ...`, the venv
      points at a Python that's gone (hit 2026-10-28, `C:\Python312`): rename `~/.platformio/penv`
      aside, `python -m venv ~/.platformio/penv`, `~/.platformio/penv/Scripts/python -m pip install platformio`.
- [ ] Device = M5StickC Plus, CH9102 USB-serial (shows as `USB-Enhanced-SERIAL CH9102 (COMn)`). Find the port by name, not by number.
- [ ] Stop the dash sender before flashing or opening a serial monitor (it holds the port):
      `Stop-ScheduledTask DesktopBuddyDash`, then `pio run -e m5stickc-plus -t upload`, then `Start-ScheduledTask DesktopBuddyDash`.

## Desk dashboard (weather + lab health)
- [ ] `pwsh tools/register-dash-task.ps1` installs the hidden logon task `DesktopBuddyDash` (`-Remove` uninstalls).
- [ ] Location: `$env:DASH_LAT` / `$env:DASH_LON`, else a one-time IP lookup cached in `%LOCALAPPDATA%\DesktopBuddy\location.json`. Edit that file if the guess is off.
- [ ] Log: `%LOCALAPPDATA%\DesktopBuddy\dash-sender.log`.
- [ ] Mac/Ubuntu: no sender port yet (display-state detection is Windows-only). The device lives on the AMDThinkPad desk.
- No AWS or secrets involved: weather is Open-Meteo (no key), health is HEAD requests to public `*.basementlab.dev` URLs.
