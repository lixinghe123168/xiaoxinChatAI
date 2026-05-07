@echo off
chcp 65001 >nul
echo ============================================
echo   xiaoxinChatAI Web UI 启动器 (热重载版)
echo ============================================
echo.

cd /d "%~dp0.."

echo [1/2] 检查依赖...
pip show streamlit >nul 2>&1
if errorlevel 1 (
    echo   安装 streamlit 中...
    pip install streamlit
)

echo.
echo [2/2] 启动 Web UI (热重载模式)...
echo.
echo   ✨ 功能:
echo     - 修改 .py 文件后自动重载
echo     - 不需要手动重启
echo     - 控制台会显示重载日志
echo.
echo   📱 访问地址: http://localhost:8501
echo.
echo   按 Ctrl+C 停止
echo.

streamlit run web_ui.py --server.runOnSave true --server.port 8501

pause
