@echo off
rem Throughput test against the iperf3 peer. iperf3.exe and lantest-find.ps1
rem must be in the same folder.
rem Usage: lantest.cmd                  (finds the peer: 169.254.99.1, iperf-peer.local,
rem                                      pikvm.local, then a scan for Raspberry Pi devices)
rem        lantest.cmd <peer IP/name>   (use this peer)
rem Before the test it asks whether to save the output to a log file
rem (<name>_<date>_<time>.txt next to this script).
setlocal
if "%~1"==":measure" goto measure
set "TARGET=%~1"
cd /d "%~dp0"
rem iperf3 before 3.2 always writes its buffer file next to iperf3.exe (/tmp under Cygwin),
rem so it fails without admin rights in a protected folder, and it lacks --connect-timeout.
iperf3.exe -v 2>&1 | findstr /r /b /c:"iperf 3\.[01]\." >nul && goto oldiperf
set FINDARGS=
if not "%TARGET%"=="" set FINDARGS=-Target "%TARGET%"
set "PEER="
set "SRC="
rem The finder prints "<peer>" or, for a 169.254.x.x peer on the cable, "<peer> <local address>".
for /f "usebackq tokens=1,2" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lantest-find.ps1" %FINDARGS%`) do set "PEER=%%A" & set "SRC=%%B"
if "%PEER%"=="" goto notfound
set "TARGET=%PEER%"
rem Bound to the cable's address, Windows cannot send the test into another adapter
rem (Tailscale's adapter also has a 169.254.x.x address when it is not connected).
set "BIND="
if not "%SRC%"=="" set "BIND=-B %SRC%"

echo.
set "LOGFILE="
set "ANSWER="
set /p "ANSWER=Save the results to a log file? / Messung in Logdatei speichern? (J/Y/N): "
if /i "%ANSWER%"=="j" goto askname
if /i "%ANSWER%"=="y" goto askname
goto run
:askname
set "LANTEST_NAME="
set /p "LANTEST_NAME=Name of the log file / Name der Logdatei: "
if "%LANTEST_NAME%"=="" set "LANTEST_NAME=lantest"
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "($env:LANTEST_NAME -replace '[^\w.-]','_') + '_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.txt'"`) do set "LOGFILE=%~dp0%%F"

:run
set "FAILFLAG=%TEMP%\lantest-%RANDOM%%RANDOM%.failed"
if exist "%FAILFLAG%" del "%FAILFLAG%"
if "%LOGFILE%"=="" (
    call :measure
) else (
    cmd /c ""%~f0" :measure" 2>&1 | powershell -NoProfile -Command "$input | ForEach-Object { $_; Add-Content -LiteralPath $env:LOGFILE -Value $_ -Encoding UTF8 }"
)
if exist "%FAILFLAG%" (
    del "%FAILFLAG%"
    goto failed
)
if not "%LOGFILE%"=="" echo Log file / Logdatei: %LOGFILE%
pause
exit /b 0

rem The measurement itself; also run as "lantest.cmd :measure" when its output goes to the log.
:measure
echo.
echo === %DATE% %TIME:~0,5%  peer %TARGET% ===
if not "%SRC%"=="" echo Through the cable, this computer: %SRC%
echo === Link speed of this computer ===
powershell -NoProfile -Command "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Format-Table Name, InterfaceDescription, LinkSpeed -AutoSize"

echo === This computer -^> peer (10 s) ===
iperf3.exe -c %TARGET% %BIND% -t 10 --connect-timeout 3000 --forceflush
if errorlevel 1 (
    echo.>"%FAILFLAG%"
    exit /b 1
)

echo === Peer -^> this computer (10 s) ===
iperf3.exe -c %TARGET% %BIND% -t 10 -R --connect-timeout 3000 --forceflush
if errorlevel 1 (
    echo.>"%FAILFLAG%"
    exit /b 1
)

echo.
echo Reference values (line "receiver"): healthy gigabit = about 850-940 Mbit/s, 100 Mbit/s link = about 94 Mbit/s.
exit /b 0

:oldiperf
echo This iperf3.exe is too old (3.1 or earlier). It needs admin rights and cannot run this test.
echo Use a current build instead, e.g. https://github.com/ar51an/iperf3-win-builds/releases
pause
exit /b 1

:notfound
pause
exit /b 1

:failed
echo.
if not "%LOGFILE%"=="" echo Log file / Logdatei: %LOGFILE%
echo Peer not reachable at %TARGET%. On a bare cable, wait about 30 seconds after plugging in
echo until Windows has assigned itself a 169.254.x.x address, turn Wi-Fi off, then run again.
pause
exit /b 1
