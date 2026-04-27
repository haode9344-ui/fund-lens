@echo off
cd /d "%~dp0"
echo Starting Fund Lens local monitor...
echo Open: http://127.0.0.1:8765
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8765" ^| findstr "LISTENING"') do taskkill /PID %%a /F >nul 2>nul
set FUND_LENS_OPEN_BROWSER=1
python app.py
pause
