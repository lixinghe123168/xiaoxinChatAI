@echo off
chcp 936 >nul 2>&1
title xiaoxinChatAI Web UI

cd /d "%~dp0"

echo.
echo   xiaoxinChatAI Web Management Interface
echo.

where python >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo   [ERROR] Python not found!
    echo.
    echo   Please install Python 3.10+ first:
    echo     https://www.python.org/downloads/
    echo.
    echo   IMPORTANT: Check "Add Python to PATH" during installation!
    pause
    exit /b 1
)

python -c "import streamlit" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo   [ERROR] streamlit not installed!
    echo.
    echo   Please run this command to install:
    echo     pip install streamlit aiohttp openai cryptography
    pause
    exit /b 1
)

if not exist "web_ui.py" (
    echo   [ERROR] web_ui.py not found in current directory!
    pause
    exit /b 1
)

echo   [OK] Starting Streamlit server...
echo   [OK] Please open browser and visit: http://localhost:8501
echo   [OK] Press Ctrl+C to stop
echo.

streamlit run web_ui.py --server.port 8501 --server.headless true

echo.
echo   [INFO] Server stopped. Press any key to exit...
pause >nul
