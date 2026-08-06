' Launches the WSL Crew tray app hidden at logon.
' Copy (or re-copy) this file into:
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
'
' UPDATE THE PATH BELOW to match where you cloned the wsl-crew repo.
' Window style 0 = hidden, False = don't wait.
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""PATH_TO_REPO\wsl-crew-tray.ps1""", 0, False
