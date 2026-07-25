' Launches the OpenClaw Helper tray app hidden at logon.
' Copy (or re-copy) this file into:
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
' Window style 0 = hidden, False = don't wait.
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\Kurt Valcorza\Projects\openclaw-helper\openclaw-tray.ps1""", 0, False
