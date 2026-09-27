' Run a PowerShell script with no console window, and wait for it.
'
' powershell.exe -WindowStyle Hidden is not enough on Windows 11: Windows
' Terminal creates its window before PowerShell can honour the flag.
' WScript.Shell.Run with window style 0 suppresses it at creation. Waiting
' (True) keeps the scheduled task alive for the script's lifetime, so the
' task's time limit and IgnoreNew apply to the script itself.
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
WScript.Quit sh.Run(cmd, 0, True)
