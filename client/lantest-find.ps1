# Finds the iperf3 peer for lantest.cmd. Keep this file next to lantest.cmd.
# Order: 169.254.99.1, iperf-peer.local, pikvm.local, then a scan of the local
# /24 for Raspberry Pi devices with port 5201 open.
# LANTEST_PEERS="name-or-ip ..." replaces the list of names tried before the scan.
# Prints the peer's IPv4 address on stdout (exit 0); messages go to stderr.
# Exit 1 if nothing was found.
# With -Target <name>: no search, just print the first of the name's addresses
# that answers on port 5201 (or the name itself if none does).
param([string]$Target = '')

$ErrorActionPreference = 'SilentlyContinue'
$Port = 5201
$PiOuis = @('b8:27:eb', 'dc:a6:32', 'e4:5f:01', 'd8:3a:dd', '2c:cf:67', '28:cd:c1')

function Say($msg) { [Console]::Error.WriteLine($msg) }

# TCP connect to port 5201, at most 2 s (Test-NetConnection is far slower on failure).
function Test-Port([string]$ip) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($ip, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(2000) -and $client.Connected) { return $true }
    } catch {
    } finally {
        $client.Close()
    }
    return $false
}

# IPv4 addresses of a name (mDNS for .local on Windows 10/11), at most 2 s.
function Resolve-V4([string]$name) {
    $addr = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$addr)) { return @($name) }
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($name)
        if ($task.Wait(2000)) {
            return @($task.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.IPAddressToString } | Select-Object -Unique)
        }
    } catch {}
    return @()
}

# First address of a name that answers on port 5201 (a name can have a wired
# and a Wi-Fi address), or $null.
function Find-Open([string]$name) {
    foreach ($ip in (Resolve-V4 $name)) {
        if (Test-Port $ip) { return $ip }
    }
    return $null
}

function Find-ByScan {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { Say 'Network scan skipped: no default route (no normal network).'; return $null }
    $ifIndex = $route.InterfaceIndex
    $addr = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $addr) { Say 'Network scan skipped: the network interface has no IPv4 address.'; return $null }
    $myIp = $addr.IPAddress
    $prefix = [int]$addr.PrefixLength
    if ($prefix -lt 24) {
        Say "Network scan skipped: $myIp/$prefix is too large to scan. Pass the peer's IP as argument."
        return $null
    }
    if ($prefix -gt 30) { Say "Network scan skipped: $myIp/$prefix has no other hosts."; return $null }

    # /24 or smaller: only the last octet varies.
    $size = [int][math]::Pow(2, 32 - $prefix)
    $octets = $myIp.Split('.')
    $base = ($octets[0..2] -join '.')
    $first = [int]([math]::Floor([int]$octets[3] / $size) * $size)
    Say "Scanning $base.$first/$prefix for Raspberry Pi devices (takes a few seconds)..."

    # Ping everything in parallel; the replies do not matter, the neighbour table does.
    $tasks = @()
    for ($i = 1; $i -lt $size - 1; $i++) {
        $ip = "$base.$($first + $i)"
        if ($ip -ne $myIp) { $tasks += (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip, 1000) }
    }
    try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, 5000) | Out-Null } catch {}

    $neighbours = Get-NetNeighbor -InterfaceIndex $ifIndex -AddressFamily IPv4 |
        Where-Object { $_.LinkLayerAddress -and $_.IPAddress -like "$base.*" }
    foreach ($n in $neighbours) {
        $last = [int]($n.IPAddress.Split('.')[3])
        if ($last -le $first -or $last -ge $first + $size - 1) { continue }
        $mac = $n.LinkLayerAddress.ToLower().Replace('-', ':')
        if ($PiOuis -notcontains $mac.Substring(0, [math]::Min(8, $mac.Length))) { continue }
        if (Test-Port $n.IPAddress) {
            Say "Peer found: $($n.IPAddress) (Raspberry Pi, found by network scan)"
            return $n.IPAddress
        }
    }
    Say "Network scan: no Raspberry Pi with port $Port open on $base.$first/$prefix."
    return $null
}

if ($Target) {
    $ip = Find-Open $Target
    if ($ip -and $ip -ne $Target) { Say "Peer: $Target ($ip)"; Write-Output $ip } else { Write-Output $Target }
    exit 0
}

if ($env:LANTEST_PEERS) {
    $candidates = $env:LANTEST_PEERS -split '\s+' | Where-Object { $_ }
} else {
    $candidates = @('169.254.99.1', 'iperf-peer.local', 'pikvm.local')
}

Say '=== Looking for the peer ==='
foreach ($c in $candidates) {
    $ip = Find-Open $c
    if ($ip) {
        if ($ip -eq $c) { Say "Peer found: $c" } else { Say "Peer found: $c ($ip)" }
        Write-Output $ip
        exit 0
    }
}

$found = Find-ByScan
if ($found) { Write-Output $found; exit 0 }

Say ''
Say "No iperf3 peer found. Tried: $($candidates -join ' '), then a scan for Raspberry Pi devices."
Say 'On a bare cable: wait about 30 s after plugging in until Windows has given itself'
Say 'a 169.254.x.x address, turn Wi-Fi off, check the peer is powered and booted, run again.'
Say "On a normal network: pass the peer's IP (from the router's device list) as argument,"
Say 'for example: lantest.cmd 192.168.1.50'
exit 1
