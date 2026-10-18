@echo off
rem Starts the local proxy (127.0.0.1:8881) and opens Steam in a separate Chrome profile that uses it.
start "steam-proxy" /min python -I "%~dp0steam_proxy.py"
timeout /t 2 /nobreak >nul
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" --proxy-server=http://127.0.0.1:8881 --user-data-dir="%~dp0browser-profile" --no-first-run https://store.steampowered.com/
