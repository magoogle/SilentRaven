@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: SilentRaven - Cloud Catalog Updater
::
:: Patterned on LooteerV3/Updater.bat. Pulls the BountyMetaCache +
:: Whisper Cache catalog from the looter server and drops it at
:: data/caches.lua next to the script. SilentRaven's core/rewards.lua
:: tries to require it first; falls back to the embedded mini-catalog
:: when the file isn't present yet.
::
:: Default mode (no args) : single fetch then exit. The "Reload Catalog"
::                          GUI button invokes this form.
:: loop mode               : Updater.bat loop -- background sync every
::                          15 minutes. Useful if you want the catalog
::                          to track new-season SNO additions without
::                          touching the GUI.
::
:: Each successful sync writes data/last_sync.lua with the current epoch
:: so the GUI header can show "synced Nm ago".
:: ============================================================

set BASE_URL=https://looter.d4data.live
set DATA_DIR=%~dp0data
set MODE=%~1

:: Make sure data/ exists before we write anything.
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%" >nul 2>&1

call :sync_once

if /i "%MODE%"=="loop" (
    :loop
    echo   Next sync in 15 minutes...
    timeout /t 900 /nobreak > nul
    echo [%TIME%] Syncing...
    call :sync_once
    goto loop
)

exit /b 0

:: ----- single sync ------------------------------------------
:: Always write a structured log to data\last_sync_log.txt so the
:: GUI can tell us EXACTLY what happened, even when the bat is
:: invoked through `>NUL 2>&1` from os.execute. The log's existence
:: also proves the bat actually executed (vs a Lua-host sandbox
:: blocking it silently).
:sync_once
set LOG=%DATA_DIR%\last_sync_log.txt
> "%LOG%" echo == SilentRaven Updater.bat sync_once ==
>> "%LOG%" echo time     : %DATE% %TIME%
>> "%LOG%" echo mode     : %MODE%
>> "%LOG%" echo cwd      : %CD%
>> "%LOG%" echo bat_dir  : %~dp0
>> "%LOG%" echo data_dir : %DATA_DIR%
>> "%LOG%" echo base_url : %BASE_URL%

curl -fsS -o "%DATA_DIR%\caches.lua" "%BASE_URL%/d4/silentraven/caches.lua" 2>> "%LOG%"
set CACHE_OK=%errorlevel%
>> "%LOG%" echo curl caches.lua exit=%CACHE_OK%

for %%I in ("%DATA_DIR%\caches.lua") do >> "%LOG%" echo caches.lua_size=%%~zI

if %CACHE_OK% equ 0 (
    if /i not "%MODE%"=="loop" echo   [OK] caches.lua
) else (
    if /i not "%MODE%"=="loop" echo   [FAIL] caches.lua - see data\last_sync_log.txt
)

:: Stamp sync time as a Lua module so gui.lua can require() it.
:: Only stamp on success -- a failed fetch shouldn't lie about freshness.
if %CACHE_OK% equ 0 (
    powershell -NoProfile -Command "$e = [int64]([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds; Set-Content -Path '%DATA_DIR%\last_sync.lua' -Value (\"return \" + $e) -Encoding ASCII"
)
exit /b 0

endlocal
