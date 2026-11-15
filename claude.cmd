@echo off
REM ============================================================
REM   BALUCHON - lanceur Windows
REM   Execute le MEME wizard que Mac (Claude.command) via le bash
REM   de Git portable -> interface 100%% identique
REM   (Filet de secours batch : claude-classic.cmd)
REM ============================================================
chcp 65001 >nul 2>&1
setlocal
set "ROOT=%~dp0"
set "BASH=%ROOT%git-win\bin\bash.exe"
if not exist "%BASH%" set "BASH=%ROOT%git-win\usr\bin\bash.exe"
if not exist "%BASH%" (
  echo.
  echo Git portable introuvable. Lance la version batch : claude-classic.cmd
  echo.
  pause
  exit /b 1
)
set "ROOTU=%ROOT:\=/%"
set "R=%ROOT:~0,-1%"
REM "Partir" (menu) efface tout SAUF git-win, dont le bash tourne encore, et pose .baluchon-a-finir
REM (voir uninstall.sh). Ce fichier-ci est efface pendant que cmd l'execute : le lancement et la
REM derniere etape tiennent donc dans UN bloc entre parentheses, lu en entier avant d'etre execute.
REM git-win est retire avec reessais (un guetteur bash peut finir ~2 s apres le menu), puis le
REM dossier par un rmdir NON recursif : il ne part que s'il est vide, rien d'autre n'est jamais efface.
(
  "%BASH%" --login "%ROOTU%Claude.command"
  if exist "%R%\.baluchon-a-finir" if not exist "%R%\.baluchon-install" (
    cd /d "%TEMP%"
    for /l %%i in (1,1,30) do if exist "%R%\git-win" (rmdir /s /q "%R%\git-win" 2>nul & if exist "%R%\git-win" ping -n 2 127.0.0.1 >nul)
    if not exist "%R%\git-win" del /f /q /a "%R%\.baluchon-a-finir" 2>nul
    rmdir "%R%" 2>nul
    if exist "%R%" (
      echo   [!] Il reste le dossier "%R%" : ferme les fenetres Baluchon puis supprime-le a la main.
      echo.
      exit /b 12
    )
    echo   [OK] Rien ne reste sur cet ordinateur.
    echo.
    exit /b 0
  )
)
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [Probleme] code %RC%. Voir le dossier logs\, ou essaie claude-classic.cmd
  echo.
  pause
)
exit /b %RC%
