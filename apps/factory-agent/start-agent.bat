@echo off
rem Starts the machine data collector. Used by Task Scheduler for auto-start
rem on boot (see FACTORY-SETUP.md Part 3). Loops so a crash restarts it.
cd /d "%~dp0"
:loop
call npm run agent
echo Agent stopped (exit %errorlevel%). Restarting in 10 seconds...
timeout /t 10 /nobreak >nul
goto loop
