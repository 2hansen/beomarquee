' run-hidden.vbs <full-path-to.ps1>
'
' Launches a PowerShell script with a TRULY hidden window (window style 0),
' bypassing the Windows 11 bug where -WindowStyle Hidden is ignored when
' Windows Terminal is the default console host (WT shows the window before
' PowerShell can hide itself). wscript.exe has no console of its own, so the
' three BeoSound logon tasks no longer flash terminal windows on reboot.
'
' Used by the BeoPort Auto-Attach / BeoSound NowPlaying Writer /
' BeoSound Player Control scheduled tasks. See register-hidden-tasks.ps1.

' bWaitOnReturn = True: wscript blocks until the PowerShell loop exits, so the
' scheduled task stays in the Running state and its RestartCount safety net
' still relaunches the chain if the loop ever dies. Window stays hidden (0).
Set sh = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)
WScript.Quit sh.Run("powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File """ & ps1 & """", 0, True)
