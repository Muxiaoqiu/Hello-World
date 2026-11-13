@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

REM 双击运行进入交互问答；也可: chat-qwen.bat 你好
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0chat-qwen.ps1" %*
set EXITCODE=%ERRORLEVEL%
if %EXITCODE% neq 0 (
  echo.
  echo 脚本退出码: %EXITCODE%
  pause
)
endlocal & exit /b %EXITCODE%
