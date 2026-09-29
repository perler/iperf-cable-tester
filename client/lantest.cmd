@echo off
rem Throughput test against the iperf3 peer. iperf3.exe must be in the same folder.
rem Usage: lantest.cmd              (bare cable, peer = 169.254.99.1)
rem        lantest.cmd <peer IP>    (peer is on a normal network)
setlocal
set TARGET=%1
if "%TARGET%"=="" set TARGET=169.254.99.1
cd /d "%~dp0"

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
echo Reference values (line "receiver"): healthy gigabit = about 900-940 Mbit/s, 100 Mbit/s link = about 94 Mbit/s.
pause
exit /b 0

:failed
echo.
echo Peer not reachable at %TARGET%. On a bare cable, wait about 30 seconds after plugging in
echo until Windows has assigned itself a 169.254.x.x address, turn Wi-Fi off, then run again.
pause
exit /b 1
