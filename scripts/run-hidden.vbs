' Launch a PowerShell script with NO console window.
'
' powershell.exe -WindowStyle Hidden is NOT enough on Windows 11: Windows
' Terminal is the default console host, and it creates its own window before
' PowerShell ever gets to honour -WindowStyle. The update checker therefore
' flashed a visible terminal on every run, six times a day.
'
' WScript.Shell.Run with intWindowStyle = 0 suppresses the window at creation,
' which is the only thing Terminal cannot override.
'
' Usage: wscript.exe run-hidden.vbs <script.ps1> [args...]
Option Explicit
Dim sh, cmd, i
Set sh = CreateObject("WScript.Shell")
If WScript.Arguments.Count = 0 Then WScript.Quit 1
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
  cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False