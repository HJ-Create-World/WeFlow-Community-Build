@echo off
rem WeFlow dev launcher
rem Why this exists: WorkBuddy's shell env exports ELECTRON_RUN_AS_NODE=1,
rem which makes Electron run as plain Node.js and crash on startup
rem ("Cannot read properties of undefined (reading 'commandLine')").
rem `set VAR=` in cmd unsets the variable, fixing it for this session only.
set "ELECTRON_RUN_AS_NODE="
cd /d "%~dp0"
"C:\Users\15056\.workbuddy\binaries\node\versions\22.22.2-6\npm.cmd" run dev
pause
