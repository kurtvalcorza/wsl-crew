' Holds a WSL distro running at logon so its systemd services stay reachable.
' Without this, WSL idle-shuts-down the VM and the gateway dies -- systemd
' lingering alone is NOT enough, because WSL tears down the whole utility VM.
'
' Copy (or re-copy) this file into:
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
'
' UPDATE the distro name and user below to match your setup.
' Window style 0 = hidden, False = don't wait.
Set shell = CreateObject("WScript.Shell")
shell.Run "wsl.exe -d kirocrew -u kurt --exec /bin/sleep infinity", 0, False
