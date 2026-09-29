@echo off
rem Throughput test against the iperf3 peer. iperf3.exe and lantest-find.ps1
rem must be in the same folder.
rem Usage: lantest.cmd                  (finds the peer: 169.254.99.1, iperf-peer.local,
rem                                      pikvm.local, then a scan for Raspberry Pi devices)
rem        lantest.cmd <peer IP/name>   (use this peer)
setlocal
set "TARGET=%~1"
cd /d "%~dp0"
set FINDARGS=
if not "%TARGET%"=="" set FINDARGS=-Target "%TARGET%"
set "PEER="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lantest-find.ps1" %FINDARGS%`) do set "PEER=%%A"
if "%PEER%"=="" goto notfound
set "TARGET=%PEER%"

echo.
echo === Link speed of this computer ===
powershell -NoProfile -Command "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Format-Table Name, InterfaceDescription, LinkSpeed -AutoSize"

echo === This computer -^> peer (10 s) ===
iperf3.exe -c %TARGET% -t 10 --connect-timeout 3000
if errorlevel 1 goto failed

echo === Peer -^> this computer (10 s) ===
iperf3.exe -c %TARGET% -t 10 -R --connect-timeout 3000
if errorlevel 1 goto failed

echo.
echo Reference values (line "receiver"): healthy gigabit = about 850-940 Mbit/s, 100 Mbit/s link = about 94 Mbit/s.
pause
exit /b 0

:notfound
pause
exit /b 1

:failed
echo.
echo Peer not reachable at %TARGET%. On a bare cable, wait about 30 seconds after plugging in
echo until Windows has assigned itself a 169.254.x.x address, turn Wi-Fi off, then run again.
pause
exit /b 1
