@echo off
rem sc.cmd - study-coach entry for Windows cmd / PowerShell.
rem Finds Git Bash and forwards all arguments to bin/sc (same folder).
rem Why: .sh scripts cannot run in cmd/PowerShell directly; Git Bash is the official Windows path.
rem Override: set SC_BASH=C:\path\to\bash.exe
setlocal EnableExtensions
chcp 65001 >nul 2>&1

set "SC_SELF=%~dp0sc"
set "BASH_EXE="

if defined SC_BASH if exist "%SC_BASH%" set "BASH_EXE=%SC_BASH%"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramW6432%\Git\bin\bash.exe" set "BASH_EXE=%ProgramW6432%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"

rem Fallback: locate git.exe on PATH (...\Git\cmd\git.exe) and use ..\bin\bash.exe.
rem Never use C:\Windows\System32\bash.exe - that is WSL, not Git Bash.
if not defined BASH_EXE (
  for /f "delims=" %%G in ('where git 2^>nul') do (
    if not defined BASH_EXE if exist "%%~dpG..\bin\bash.exe" set "BASH_EXE=%%~dpG..\bin\bash.exe"
  )
)

if not defined BASH_EXE (
  echo [study-coach] Git Bash not found. Install Git for Windows first:
  echo     winget install --id Git.Git -e
  echo   then open a NEW terminal and run this command again.
  echo   Or set SC_BASH to the full path of bash.exe.
  exit /b 1
)

"%BASH_EXE%" "%SC_SELF%" %*
exit /b %ERRORLEVEL%
