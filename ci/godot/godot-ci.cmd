@echo off
rem Runs godot-ci from cmd or PowerShell through Git Bash (installed with Git for Windows).
rem   ci\godot\godot-ci.cmd [test^|build^|export^|setup^|detect] [options]
setlocal
set "GIT_BASH="
for %%G in ("%ProgramFiles%\Git\bin\bash.exe" "%ProgramFiles(x86)%\Git\bin\bash.exe" "%LocalAppData%\Programs\Git\bin\bash.exe") do (
  if not defined GIT_BASH if exist "%%~G" set "GIT_BASH=%%~G"
)
if not defined GIT_BASH (
  rem Fall back to git.exe on PATH: Git Bash lives at ..\bin\bash.exe relative to its cmd folder.
  for /f "delims=" %%G in ('where git 2^>nul') do if not defined GIT_BASH if exist "%%~dpG..\bin\bash.exe" set "GIT_BASH=%%~dpG..\bin\bash.exe"
)
if not defined GIT_BASH (
  echo godot-ci: Git Bash not found. Install Git for Windows: https://git-scm.com/download/win 1>&2
  exit /b 1
)
"%GIT_BASH%" "%~dp0godot-ci" %*
exit /b %ERRORLEVEL%
