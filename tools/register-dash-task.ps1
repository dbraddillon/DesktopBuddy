<#
.SYNOPSIS
  Installs tools/dash-sender.ps1 as a hidden logon task (DesktopBuddyDash) for the current user,
  starts it now, and restarts it if it dies. Re-run to update. `-Remove` uninstalls.
  Needs a normal (non-elevated) pwsh; the sender needs the interactive session to see display state.
#>
param([switch]$Remove)

$name = 'DesktopBuddyDash'
if ($Remove) { Unregister-ScheduledTask $name -Confirm:$false -ErrorAction SilentlyContinue; return }

$script = Join-Path $PSScriptRoot 'dash-sender.ps1'
$pwsh   = (Get-Command pwsh).Source
$action   = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask $name -Action $action -Trigger $trigger -Settings $settings `
  -Description 'Pushes weather + lab health to the DesktopBuddy while displays are on' -Force | Out-Null
Start-ScheduledTask $name
Get-ScheduledTask $name | Select-Object TaskName, State
