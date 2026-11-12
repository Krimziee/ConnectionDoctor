<#
    The live monitor's background threads. They only measure and put results
    in queues; the window reads the queues once per second and draws them.
    That way a ping that times out can never freeze the window.

      Ping loop     once per second: router + the three internet targets, all at once
      Region loop   every 5 seconds: TCP connection time to each game region
      Network loop  every 5 seconds: Wi-Fi signal; every 15 s: re-checks adapter/router

    $Shared is a synchronized hashtable owned by the window:
      Stop, Paused        flags set by the window
      Connection          latest Get-ConnectionInfo result (Network loop updates it)
      Wifi                latest Get-WifiInfo result
      Rounds              queue of ping rounds  { Time; Ms = @{ Key = ms or $null } }
      RegionSamples       queue of region tests { Time; Key; Ms or $null; Via }
      Notes               queue of plain messages for the event list
#>

function New-SharedState {
    param($Targets, $Connection)
    $shared = [hashtable]::Synchronized(@{})
    $shared.Stop          = $false
    $shared.Paused        = $false
    $shared.Targets       = $Targets
    $shared.Connection    = $Connection
    $shared.Wifi          = $null
    $shared.Rounds        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $shared.RegionSamples = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $shared.Notes         = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $shared
}

function Invoke-PingLoop {
    param($Shared)
    while (-not $Shared.Stop) {
        $roundStart = [Diagnostics.Stopwatch]::StartNew()
        if (-not $Shared.Paused) {
            $list = @()
            if ($Shared.Connection.Gateway) { $list += @{ Key = 'Router'; Address = $Shared.Connection.Gateway } }
            foreach ($t in $Shared.Targets.Internet) { $list += @{ Key = $t.Key; Address = $t.Address } }

            # Every target is pinged at the same moment, so spikes can be compared between them
            $pending = foreach ($t in $list) {
                $ping = New-Object System.Net.NetworkInformation.Ping
                @{ Key = $t.Key; Ping = $ping; Task = $ping.SendPingAsync([Net.IPAddress]::Parse($t.Address), 1000) }
            }
            $time = Get-Date
            $ms = @{}
            foreach ($p in $pending) {
                $value = $null
                try {
                    if ($p.Task.Wait(1500) -and $p.Task.Result.Status -eq 'Success') { $value = [double]$p.Task.Result.RoundtripTime }
                } catch { }
                $ms[$p.Key] = $value
                $p.Ping.Dispose()
            }
            $Shared.Rounds.Enqueue([pscustomobject]@{ Time = $time; Ms = $ms })
        }
        $wait = 1000 - $roundStart.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}

function Get-SteamRelays {
    # Valve's public list of relay locations. Only the first address of each wanted city is kept.
    param($Targets)
    $relays = @{}
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $config = Invoke-RestMethod -Uri $Targets.SteamRelayList -TimeoutSec 10 -UseBasicParsing
        foreach ($r in $Targets.Regions) {
            $pop = $config.pops.($r.Steam)
            $first = @($pop.relays) | Where-Object { $_.ipv4 } | Select-Object -First 1
            if ($first) { $relays[$r.Key] = $first.ipv4 }
        }
    } catch { }
    $relays
}

function Measure-TcpConnect {
    # Time to open a TCP connection (one round trip). The connection is closed straight away.
    param([Net.IPAddress]$Address, [int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient($Address.AddressFamily)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $task = $client.ConnectAsync($Address, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { return [double]$sw.ElapsedMilliseconds }
        return $null
    } catch { return $null }
    finally { $client.Dispose() }
}

function Measure-Ping {
    param([string]$Address, [int]$TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($Address, $TimeoutMs)
        if ($reply.Status -eq 'Success') { return [double]$reply.RoundtripTime }
        return $null
    } catch { return $null }
    finally { $ping.Dispose() }
}

function Invoke-RegionLoop {
    param($Shared)
    $regions  = $Shared.Targets.Regions
    $steam    = Get-SteamRelays $Shared.Targets
    $addresses = @{}; $resolvedAt = [datetime]::MinValue
    # Each region is measured through ONE test point at a time, so its numbers stay comparable
    # (the two have different normal pings): the AWS endpoint normally, Steam's relay only after
    # AWS failed 3 times in a row. While on Steam, AWS is tried again once a minute and takes
    # over after 3 answers in a row. The window starts a region's numbers afresh on a switch.
    $source = @{}; $awsFails = @{}; $awsOk = @{}
    foreach ($r in $regions) { $source[$r.Key] = 'AWS'; $awsFails[$r.Key] = 0; $awsOk[$r.Key] = 0 }
    $round = 0

    while (-not $Shared.Stop) {
        $roundStart = [Diagnostics.Stopwatch]::StartNew()
        if (-not $Shared.Paused) {
            # Look the addresses up again every 5 minutes; the lookup itself is kept out of the timing
            if (((Get-Date) - $resolvedAt).TotalMinutes -ge 5) {
                foreach ($r in $regions) {
                    try { $addresses[$r.Key] = [Net.Dns]::GetHostAddresses($r.Host) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1 }
                    catch { }
                }
                # The relay list is read when the monitor starts; if that failed (offline), try again now
                if ($steam.Count -eq 0) { $steam = Get-SteamRelays $Shared.Targets }
                $resolvedAt = Get-Date
            }

            $round++
            foreach ($r in $regions) {
                $key = $r.Key; $ms = $null
                if ($source[$key] -eq 'AWS') {
                    if ($addresses[$key]) { $ms = Measure-TcpConnect $addresses[$key] $r.Port }
                    if ($null -ne $ms) {
                        $awsFails[$key] = 0
                    } else {
                        $awsFails[$key]++
                        if ($awsFails[$key] -ge 3 -and $steam[$key]) {
                            $source[$key] = 'Steam'; $awsOk[$key] = 0
                            $Shared.Notes.Enqueue(@{ Level = 'info'; Text = "$($r.Name): the AWS test point stopped answering, now measuring via Steam's relay instead." })
                            $ms = Measure-Ping $steam[$key] 1500
                        }
                    }
                } else {
                    $ms = Measure-Ping $steam[$key] 1500
                    # Once a minute: is the AWS test point back?
                    if ($round % 12 -eq 0 -and $addresses[$key]) {
                        if ($null -ne (Measure-TcpConnect $addresses[$key] $r.Port)) { $awsOk[$key]++ } else { $awsOk[$key] = 0 }
                        if ($awsOk[$key] -ge 3) {
                            $source[$key] = 'AWS'; $awsFails[$key] = 0
                            $Shared.Notes.Enqueue(@{ Level = 'info'; Text = "$($r.Name): the AWS test point answers again, measuring through it as before." })
                        }
                    }
                }
                $Shared.RegionSamples.Enqueue([pscustomobject]@{ Time = Get-Date; Key = $key; Ms = $ms; Via = $source[$key] })
            }
        }
        $wait = 5000 - $roundStart.ElapsedMilliseconds
        while ($wait -gt 0 -and -not $Shared.Stop) { Start-Sleep -Milliseconds ([Math]::Min(250, $wait)); $wait -= 250 }
    }
}

function Invoke-NetworkLoop {
    param($Shared)
    $tick = 0
    while (-not $Shared.Stop) {
        # Paused (Pause button): nothing is read
        if ($Shared.Paused) { Start-Sleep -Milliseconds 250; continue }
        try {
            if ($tick % 3 -eq 2) {
                $now = Get-ConnectionInfo
                $old = $Shared.Connection
                if ($now.Found -and ($now.Gateway -ne $old.Gateway -or $now.IsWifi -ne $old.IsWifi)) {
                    $kind = if ($now.IsWifi) { 'Wi-Fi' } else { 'cable (Ethernet)' }
                    $Shared.Notes.Enqueue(@{ Level = 'info'; Text = "Connection changed: now on $kind, router $($now.Gateway)." })
                }
                if (-not $now.Found -and $old.Found) {
                    $Shared.Notes.Enqueue(@{ Level = 'bad'; Text = 'The network connection was lost (no router found).' })
                }
                $Shared.Connection = $now
            }
            $Shared.Wifi = if ($Shared.Connection.IsWifi) { Get-WifiInfo } else { $null }
            $Shared.WifiTime = Get-Date
        } catch { }
        $tick++
        for ($i = 0; $i -lt 20 -and -not $Shared.Stop; $i++) { Start-Sleep -Milliseconds 250 }
    }
}

function Start-Background {
    # Runs one of the loops (or a test) on its own thread. Returns a handle the window keeps.
    param([string]$Root, [string]$Command, [hashtable]$Arguments)
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($Root, $Command, $Arguments)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        foreach ($m in 'Network', 'Monitor', 'Tests') { . (Join-Path $Root "modules\$m.ps1") }
        & $Command @Arguments
    }).AddArgument($Root).AddArgument($Command).AddArgument($Arguments)
    [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Handle = $ps.BeginInvoke(); Command = $Command }
}

function Stop-Background {
    # Called when the window closes. The loops see Stop and end; anything still busy is abandoned.
    param($Job)
    if (-not $Job) { return }
    try { [void]$Job.PowerShell.BeginStop($null, $null) } catch { }
}
