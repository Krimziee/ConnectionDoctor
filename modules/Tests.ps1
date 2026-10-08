<#
    The four optional tests behind the buttons. Each runs on a background
    thread and returns one result:
      Name     button name
      Level    good | warn | bad | info
      Verdict  one sentence
      Fixes    up to 3 suggestions, plain words (the tool never applies them)
      Details  the numbers, one line each
#>

function New-TestResult {
    param([string]$Name, [string]$Level, [string]$Verdict, [string[]]$Fixes = @(), [string[]]$Details = @())
    [pscustomobject]@{ Name = $Name; Level = $Level; Verdict = $Verdict; Fixes = @($Fixes | Select-Object -First 3); Details = @($Details) }
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
}

# ------------------------------------------------------------------
#  Connection Details
# ------------------------------------------------------------------

function Invoke-ConnectionDetailsTest {
    param($BaselineErrors, [double]$PlanMbps)

    $c = Get-ConnectionInfo
    if (-not $c.Found) {
        return New-TestResult 'Connection Details' 'bad' 'No network connection found - this PC has no route to a router.' `
            @('Check that the cable is plugged in or Wi-Fi is connected.', 'Restart the router.')
    }

    $details = @()
    $fixes = @(); $level = 'good'; $verdict = $null
    $kind = if ($c.IsWifi) { 'Wi-Fi' } else { 'Cable (Ethernet)' }
    $details += "Connection: $kind - $($c.Description)"
    $details += "Router: $($c.Gateway)   This PC: $($c.IPv4)"
    if ($c.DnsServers) { $details += "DNS server: $($c.DnsServers -join ', ')" }
    if ($c.TrafficAdapter) { $details += "Internet traffic goes through: $($c.TrafficAdapter) (VPN or tunnel) - ping results include it" }

    $planBps = $PlanMbps * 1e6
    if ($c.IsWifi) {
        $w = Get-WifiInfo
        if ($w -and $w.Signal) {
            $details += "Wi-Fi: signal $($w.Signal)%, $($w.Band), channel $($w.Channel), $($w.RadioType)"
            $details += "Wi-Fi link rate: $($w.ReceiveMbps) Mbps down / $($w.TransmitMbps) Mbps up"
            if ($w.Signal -lt 50) {
                $level = 'warn'; $verdict = "Your Wi-Fi signal is weak ($($w.Signal)%)."
                $fixes += 'Move closer to the router, or remove walls/obstacles between them.'
                $fixes += 'Use a cable for gaming if you can - it removes Wi-Fi from the picture entirely.'
            }
            if ($w.Band -match '^2\.4') {
                if ($level -eq 'good') { $level = 'warn'; $verdict = "You're on 2.4 GHz Wi-Fi, which is slower and more crowded." }
                $fixes += "Connect to your router's 5 GHz network if it has one (often the same name with '5G')."
            }
            if ($planBps -gt 0 -and $w.ReceiveMbps -and $w.ReceiveMbps * 1e6 -lt $planBps) {
                $details += "Note: your Wi-Fi link rate is below your $PlanMbps Mbps plan, so downloads can't reach full speed over Wi-Fi."
            }
        } elseif ($w -and $w.Hidden) {
            $details += "Wi-Fi details are hidden by Windows unless Location access is allowed for desktop apps (Settings > Privacy & security > Location)."
        }
        $details += "Adapter link speed: $(Format-Speed $c.LinkSpeedBps)"
    } else {
        $speed = Get-AdapterSpeedInfo $c.AdapterName
        $supports = if ($speed.MaxBps -gt 0) { " (network card supports up to $(Format-Speed $speed.MaxBps))" } else { '' }
        $details += "Cable link speed: $(Format-Speed $c.LinkSpeedBps)$supports"
        if ($speed.SpeedSetting -and $speed.SpeedSetting -notmatch 'Auto') {
            $details += "Speed is set by hand in the adapter settings: '$($speed.SpeedSetting)'"
        }

        $slowerThanCard = $speed.MaxBps -gt 0 -and $c.LinkSpeedBps -gt 0 -and $c.LinkSpeedBps -lt $speed.MaxBps
        $slowerThanPlan = $planBps -gt 0 -and $c.LinkSpeedBps -gt 0 -and $c.LinkSpeedBps -lt $planBps
        if ($slowerThanCard -or $slowerThanPlan) {
            $level = 'warn'
            $verdict = if ($slowerThanPlan) {
                "Your cable connection runs at $(Format-Speed $c.LinkSpeedBps) - slower than your $PlanMbps Mbps plan, so downloads are capped."
            } else {
                "Your cable connection runs at $(Format-Speed $c.LinkSpeedBps), but your network card supports $(Format-Speed $speed.MaxBps)."
            }
            $fixes += 'Try a different cable (Cat5e or newer) - a damaged or old cable is the most common cause.'
            $fixes += 'Try a different port on the router; also check any switch, powerline adapter or wall socket in between - some only do 100 Mbps.'
            if ($speed.SpeedSetting -and $speed.SpeedSetting -notmatch 'Auto') {
                $fixes += "Set 'Speed & Duplex' back to 'Auto Negotiation' in the adapter's settings."
            } elseif ($speed.PowerSaving) {
                $fixes += "Power-saving options ($($speed.PowerSaving -join ', ')) can lower the link speed - try turning them off in the adapter's settings."
            }
            $details += "This does NOT cause lag or high ping - even 100 Mbps is far more than any game uses. It only limits downloads."
        }
        if ($speed.PowerSaving) { $details += "Power-saving options on: $($speed.PowerSaving -join ', ')" }
    }

    $errors = Get-AdapterErrorCount $c.InterfaceIndex
    if ($null -ne $errors -and $null -ne $BaselineErrors) {
        $newErrors = [Math]::Max(0, $errors - $BaselineErrors)
        $details += "Adapter errors since Connection Doctor started: $newErrors"
        if ($newErrors -gt 10) {
            if ($level -eq 'good') { $level = 'warn'; $verdict = "Your network card reported $newErrors errors while the monitor was running." }
            $fixes += 'Errors on the adapter usually mean a bad cable or port, or an outdated network driver.'
        }
    }

    if (-not $verdict) { $verdict = if ($c.IsWifi) { 'Your Wi-Fi connection looks normal.' } else { 'Your cable connection looks normal.' } }
    New-TestResult 'Connection Details' $level $verdict $fixes $details
}

# ------------------------------------------------------------------
#  DNS Test
# ------------------------------------------------------------------

function Measure-DnsServer {
    param([string]$Server, [string[]]$Domains)
    $times = @(); $failed = 0
    foreach ($round in 1..2) {
        foreach ($d in $Domains) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                # Asks the server directly, so the Windows DNS cache can't hide a slow answer
                $null = Resolve-DnsName -Name $d -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
                $times += $sw.Elapsed.TotalMilliseconds
            } catch { $failed++ }
        }
    }
    [pscustomobject]@{ Server = $Server; Median = Get-Median $times; Failed = $failed; Total = 2 * $Domains.Count }
}

function Invoke-DnsTest {
    param($Targets)
    $c = Get-ConnectionInfo
    $dns = @($c.TrafficDns) + @($c.DnsServers) | Where-Object { $_ } | Select-Object -First 1
    $domains = $Targets.DnsDomains
    # Warm-up: the first lookup in a fresh thread is slow for reasons unrelated to the network
    try { $null = Resolve-DnsName -Name 'example.com' -Server '1.1.1.1' -DnsOnly -QuickTimeout -ErrorAction Stop } catch { }

    $servers = @()
    if ($dns) { $servers += @{ Name = "Your DNS ($dns)"; Address = $dns; Mine = $true } }
    $servers += @{ Name = 'Cloudflare (1.1.1.1)'; Address = '1.1.1.1'; Mine = $false }
    $servers += @{ Name = 'Google (8.8.8.8)';     Address = '8.8.8.8'; Mine = $false }

    $results = foreach ($s in $servers) {
        $m = Measure-DnsServer $s.Address $domains
        [pscustomobject]@{ Name = $s.Name; Mine = $s.Mine; Median = $m.Median; Failed = $m.Failed; Total = $m.Total }
    }
    $details = foreach ($r in $results) {
        $fail = if ($r.Failed) { "  ($($r.Failed) of $($r.Total) lookups failed)" } else { '' }
        "$($r.Name): $(if ($null -ne $r.Median) { '{0:0} ms' -f $r.Median } else { 'no answer' })$fail"
    }
    $details = @($details) + 'DNS affects how fast logins, launchers and matchmaking start - not your in-game ping.'

    $mine = $results | Where-Object Mine | Select-Object -First 1
    $best = $results | Where-Object { -not $_.Mine -and $null -ne $_.Median } | Sort-Object Median | Select-Object -First 1
    $bestName = if ($best) { $best.Name.Split(' ')[0] } else { 'Cloudflare' }
    if (-not $mine) {
        return New-TestResult 'DNS Test' 'info' "Couldn't find which DNS server this PC uses; showing public servers only." @() $details
    }
    $change = 'If you want to switch: Settings > Network & internet > your connection > DNS server assignment > Edit. (This tool never changes it.)'
    if ($null -eq $mine.Median -or $mine.Failed -ge [Math]::Ceiling($mine.Total / 2)) {
        return New-TestResult 'DNS Test' 'bad' 'Your DNS server is failing to answer.' @("Use $bestName DNS instead of your current one.", $change, 'Restarting the router often fixes a stuck DNS server.') $details
    }
    if ($best -and $mine.Median -gt 100 -and $mine.Median -gt 2 * $best.Median) {
        return New-TestResult 'DNS Test' 'warn' ("Your DNS is slow ({0:0} ms); {1} answers in {2:0} ms." -f $mine.Median, $best.Name, $best.Median) @("Consider using $bestName DNS.", $change) $details
    }
    if ($mine.Failed -gt 0) {
        return New-TestResult 'DNS Test' 'warn' "Your DNS answers quickly, but $($mine.Failed) lookups failed." @('If launchers sometimes fail to connect, try a different DNS server.', $change) $details
    }
    if ($best -and $mine.Median -gt $best.Median + 30) {
        return New-TestResult 'DNS Test' 'good' ("Your DNS is fine ({0:0} ms). {1} is a bit quicker ({2:0} ms), but you wouldn't notice in games." -f $mine.Median, $best.Name, $best.Median) @() $details
    }
    # Compared with the public servers rather than a fixed number: DNS can't answer faster than your ping allows
    New-TestResult 'DNS Test' 'good' ("Your DNS is fine - as quick as Cloudflare and Google ({0:0} ms)." -f $mine.Median) @() $details
}

# ------------------------------------------------------------------
#  Route Check
# ------------------------------------------------------------------

function Get-RouteHops {
    # Maps the route with tracert, which keeps going past routers that stay silent
    # (pathping gives up at the first silent one, which hides most of the route on many ISPs)
    param($Shared, [string]$Target)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\TRACERT.EXE'
    $psi.Arguments = "-d -h 20 -w 800 $Target"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    $Shared.TestProcess = $process
    $output = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $Shared.TestProcess = $null

    # Hop lines look like:   3     2 ms     2 ms     3 ms  192.0.2.1   (or * * * for a silent hop)
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+(.*)$') {
            $hop = [int]$Matches[1]; $rest = $Matches[2]
            $address = if ($rest -match '(\d{1,3}(\.\d{1,3}){3})\s*$') { $Matches[1] } else { $null }
            [pscustomobject]@{ Hop = $hop; Address = $address }
        }
    }
}

function Invoke-RouteCheck {
    param($Shared, [string]$Target = '1.1.1.1', [int]$Probes = 50)

    $route = @(Get-RouteHops $Shared $Target)
    $withAddress = @($route | Where-Object Address)
    if ($withAddress.Count -eq 0) {
        return New-TestResult 'Route Check' 'info' "The route check couldn't map the route - no hop answered." @('Try again in a minute. A VPN or firewall can also block this test.')
    }

    # Ping every hop at the same time, $Probes rounds, 200 ms apart (about 10 seconds)
    $times = @{}; $lost = @{}
    foreach ($h in $withAddress) { $times[$h.Hop] = New-Object System.Collections.Generic.List[double]; $lost[$h.Hop] = 0 }
    for ($round = 0; $round -lt $Probes -and -not $Shared.Stop; $round++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $pending = foreach ($h in $withAddress) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            @{ Hop = $h.Hop; Ping = $ping; Task = $ping.SendPingAsync([Net.IPAddress]::Parse($h.Address), 1000) }
        }
        foreach ($p in $pending) {
            try {
                if ($p.Task.Wait(1500) -and $p.Task.Result.Status -eq 'Success') { $times[$p.Hop].Add([double]$p.Task.Result.RoundtripTime) }
                else { $lost[$p.Hop]++ }
            } catch { $lost[$p.Hop]++ }
            $p.Ping.Dispose()
        }
        $wait = 200 - $sw.ElapsedMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }

    # Label each hop. Private addresses right after your router can be a second router/modem
    # in your home OR your ISP's first equipment - there is no way to tell them apart from here.
    $gateway = $Shared.Connection.Gateway
    $publicSeen = 0
    $hops = foreach ($h in $route) {
        $where = if (-not $h.Address) { 'silent' }
                 elseif ($h.Address -eq $gateway) { 'your router' }
                 elseif (Test-IspSharedAddress $h.Address) { 'ISP' }
                 elseif (Test-PrivateAddress $h.Address) { if ($publicSeen -eq 0) { 'second router or ISP' } else { 'ISP' } }
                 else { $publicSeen++; if ($publicSeen -le 3) { 'ISP' } else { 'further out' } }
        $sent = if ($h.Address) { $times[$h.Hop].Count + $lost[$h.Hop] } else { 0 }
        $ok = if ($h.Address) { @($times[$h.Hop]) } else { @() }
        [pscustomobject]@{
            Hop = $h.Hop; Address = $h.Address; Where = $where
            Ms = if ($ok.Count) { Get-Median $ok } else { $null }
            Loss = if ($sent) { [int][Math]::Round(100.0 * $lost[$h.Hop] / $sent) } else { $null }
        }
    }
    $details = foreach ($h in $hops) {
        if (-not $h.Address) { '{0,2}.  {1}' -f $h.Hop, "(doesn't answer - normal for some routers)"; continue }
        $ms = if ($null -eq $h.Ms) { 'no reply' } else { Format-Ms $h.Ms }
        '{0,2}.  {1,-16} {2,-9} {3,4}% lost   {4}' -f $h.Hop, $h.Address, $ms, $h.Loss, $h.Where
    }
    $details = @($details) + 'Loss on one hop while the hops after it are clean is just a router ignoring test traffic - that is normal.'

    # Hops that ignore pings completely are skipped, like silent ones
    $answering = @($hops | Where-Object { $null -ne $_.Ms })
    if ($answering.Count -eq 0) {
        return New-TestResult 'Route Check' 'info' "No hop on the route answered pings, so it couldn't be checked." @('A VPN or firewall can block this test.') $details
    }
    $final = $answering[-1]
    if ($final.Address -ne $Target) {
        $details += "The route didn't answer all the way to $Target; the last hop that answered is treated as the end."
    }
    if ($final.Loss -lt 2) {
        $level = 'good'; $verdict = "No lasting packet loss anywhere on the route to $Target."
        $first = $answering | Select-Object -First 1
        if ($first.Where -eq 'your router' -and $first.Ms -gt 10) {
            $level = 'warn'; $verdict = "No lasting packet loss, but your router answers slowly ($(Format-Ms $first.Ms)) - usually a Wi-Fi or busy-network sign."
        }
        return New-TestResult 'Route Check' $level $verdict @() $details
    }

    # Lasting loss: the earliest hop from which every later answering hop also loses packets
    $start = $final
    for ($i = $answering.Count - 1; $i -ge 0; $i--) {
        if ($answering[$i].Loss -ge 2) { $start = $answering[$i] } else { break }
    }
    $at = "hop $($start.Hop), $($start.Address)"
    switch ($start.Where) {
        'your router' {
            New-TestResult 'Route Check' 'bad' "Packet loss starts at your own router ($at) and carries on to the end - the problem is inside your home." `
                @('Use a cable instead of Wi-Fi, or move closer to the router.', 'Restart the router.', 'Try another cable or router port.') $details
        }
        'second router or ISP' {
            New-TestResult 'Route Check' 'bad' "Packet loss starts just past your router ($at) and carries on to the end." `
                @("That hop is either a second router/modem in your home or your ISP's first equipment. Restart both your router and modem.",
                  'If you have two boxes (modem + router), check the cable between them.',
                  'If it continues, contact your ISP and show them this result.') $details
        }
        'ISP' {
            New-TestResult 'Route Check' 'bad' "Packet loss starts in your ISP's network ($at) and carries on to the end." `
                @('Restart your router/modem once - it reconnects you to the ISP.', 'If it continues, contact your ISP and show them this result (the hop number and address).') $details
        }
        default {
            New-TestResult 'Route Check' 'warn' "Packet loss starts far out on the internet ($at), past your ISP." `
                @('This is outside your home and usually outside your ISP too - it often clears up by itself.', 'If it lasts for days, report it to your ISP; they can raise it with the network involved.') $details
        }
    }
}
# ------------------------------------------------------------------
#  Lag Under Load (bufferbloat)
# ------------------------------------------------------------------

function Invoke-DownloadStream {
    # Reads the test file and throws the data away. Nothing is saved.
    param([string]$Url, $State, [string]$Slot)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # .NET allows only 2 connections per server by default; the test needs all streams at once
    if ([Net.ServicePointManager]::DefaultConnectionLimit -lt 16) { [Net.ServicePointManager]::DefaultConnectionLimit = 16 }
    $State[$Slot] = 0.0
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Timeout = 10000
        $request.ReadWriteTimeout = 10000
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 262144
        while (-not $State.Stop) {
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $State[$Slot] += $n
        }
        $stream.Dispose(); $response.Dispose()
    } catch { $State["$Slot-error"] = $_.Exception.Message }
    $State["$Slot-done"] = $true
}

function Invoke-LoadTest {
    param($Shared, [string]$Root, $Targets, [double]$PlanMbps)

    $gateway = $Shared.Connection.Gateway
    $samples = @{ Idle = @{ Internet = @(); Router = @() }; Load = @{ Internet = @(); Router = @() } }
    $lost    = @{ Idle = 0; Load = 0 }

    function Measure-Round([string]$Phase) {
        $p1 = New-Object System.Net.NetworkInformation.Ping
        $t1 = $p1.SendPingAsync([Net.IPAddress]::Parse('1.1.1.1'), 1000)
        $p2 = $null; $t2 = $null
        if ($gateway) { $p2 = New-Object System.Net.NetworkInformation.Ping; $t2 = $p2.SendPingAsync([Net.IPAddress]::Parse($gateway), 1000) }
        try { if ($t1.Wait(1500) -and $t1.Result.Status -eq 'Success') { $samples[$Phase].Internet += [double]$t1.Result.RoundtripTime } else { $lost[$Phase]++ } } catch { $lost[$Phase]++ }
        if ($t2) { try { if ($t2.Wait(1500) -and $t2.Result.Status -eq 'Success') { $samples[$Phase].Router += [double]$t2.Result.RoundtripTime } } catch { } }
        $p1.Dispose(); if ($p2) { $p2.Dispose() }
    }

    # 1. Idle: 5 seconds of pings with nothing extra running
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 5 -and -not $Shared.Stop) { Measure-Round 'Idle'; Start-Sleep -Milliseconds 200 }

    # 2. Load: download the test file on several connections at once and keep pinging
    $state = [hashtable]::Synchronized(@{ Stop = $false })
    $streams = foreach ($i in 1..$Targets.LoadTestStreams) {
        Start-Background -Root $Root -Command 'Invoke-DownloadStream' -Arguments @{ Url = $Targets.LoadTestUrl; State = $state; Slot = "s$i" }
    }
    $sw.Restart()
    while ($sw.Elapsed.TotalSeconds -lt $Targets.LoadTestSeconds -and -not $Shared.Stop) {
        Measure-Round 'Load'
        $done = @(1..$Targets.LoadTestStreams | Where-Object { $state["s$_-done"] }).Count
        if ($done -eq $Targets.LoadTestStreams) { break }
        Start-Sleep -Milliseconds 200
    }
    $loadSeconds = $sw.Elapsed.TotalSeconds
    $state.Stop = $true
    $bytes = 0.0; foreach ($i in 1..$Targets.LoadTestStreams) { if ($state["s$i"]) { $bytes += $state["s$i"] } }
    $errors = @(1..$Targets.LoadTestStreams | ForEach-Object { $state["s$_-error"] } | Where-Object { $_ })
    foreach ($s in $streams) { Stop-Background $s }

    $mbps = if ($loadSeconds -gt 0) { $bytes * 8 / $loadSeconds / 1e6 } else { 0 }
    $idle = Get-Median $samples.Idle.Internet
    $load = Get-Median $samples.Load.Internet
    $idleR = Get-Median $samples.Idle.Router
    $loadR = Get-Median $samples.Load.Router

    $details = @()
    $details += ('Download during the test: {0:0} MB in {1:0.0} s = about {2:0} Mbps' -f ($bytes / 1MB), $loadSeconds, $mbps)
    if ($PlanMbps -gt 0) { $details += ('Your plan: {0:0} Mbps' -f $PlanMbps) }
    $details += "Ping to the internet: $(Format-Ms $idle) normally, $(Format-Ms $load) while downloading"
    if ($gateway) { $details += "Ping to your router: $(Format-Ms $idleR) normally, $(Format-Ms $loadR) while downloading" }
    if ($lost.Load -gt 0) { $details += "Lost pings while downloading: $($lost.Load)" }
    if ($loadSeconds -lt 4) { $details += 'Your line is fast: the test file finished in a few seconds, so the busy period was short.' }

    if ($bytes -lt 1MB) {
        $why = if ($errors) { " ($($errors[0]))" } else { '' }
        return New-TestResult 'Lag Under Load' 'info' "The test download didn't start$why, so lag under load couldn't be measured." @('Try again in a minute.') $details
    }
    if ($null -eq $idle -or $null -eq $load) {
        return New-TestResult 'Lag Under Load' 'info' "Pings didn't come back during the test, so it couldn't be measured." @() $details
    }

    $added = $load - $idle
    $routerAdded = if ($null -ne $idleR -and $null -ne $loadR) { $loadR - $idleR } else { 0 }
    $details = @("Extra lag while downloading: $(Format-Ms ([Math]::Max(0, $added)))") + $details
    $wifiNote = if ($Shared.Connection.IsWifi -and $routerAdded -gt 30) { ' Even your router slows down, so the Wi-Fi link itself is getting congested.' } else { '' }
    $fixes = @(
        "Turn on QoS / SQM / 'Smart Queue' in your router's settings - it's the real fix for this.",
        'Pause or speed-limit downloads (Steam, launchers, updates) while you play.',
        "If your router has no such option, ask your ISP for one that does."
    )
    if ($added -ge 100) {
        return New-TestResult 'Lag Under Load' 'bad' ("Bufferbloat: your ping jumps by about {0:0} ms when the connection is busy.{1}" -f $added, $wifiNote) $fixes $details
    }
    if ($added -ge 30) {
        return New-TestResult 'Lag Under Load' 'warn' ("Your ping rises by about {0:0} ms when the connection is busy - noticeable in games.{1}" -f $added, $wifiNote) $fixes $details
    }
    New-TestResult 'Lag Under Load' 'good' ("Your ping stays steady when the connection is busy (+{0:0} ms)." -f [Math]::Max(0, $added)) @() $details
}
