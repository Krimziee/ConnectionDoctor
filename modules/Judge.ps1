<#
    Turns raw measurements into numbers people understand (normal ping, jitter,
    loss) and into plain-language verdicts. Runs on the window's thread.

    Thresholds are deliberately about STABILITY. A steady 70 ms to Cloudflare is
    normal in many countries; what makes games lag is jitter and lost packets.
#>

$script:Limits = @{
    # Router: tighter on cable than on Wi-Fi
    RouterWired = @{ LossWarn = 2; LossBad = 5; JitterWarn = 3; JitterBad = 10; MedianWarn = 3;  MedianBad = 10 }
    RouterWifi  = @{ LossWarn = 2; LossBad = 5; JitterWarn = 6; JitterBad = 20; MedianWarn = 10; MedianBad = 30 }
    Internet    = @{ LossWarn = 2; LossBad = 5; JitterWarn = 8; JitterBad = 20; MedianWarn = 150; MedianBad = 250 }
    Region      = @{ LossWarn = 5; LossBad = 10; JitterWarn = 10; JitterBad = 25; MedianWarn = 1e9; MedianBad = 1e9 }
}

$script:StatusRank = @{ none = -1; good = 0; warn = 1; bad = 2 }

function Get-SampleStats {
    # Samples: objects with .Ms ($null = lost)
    param($Samples)
    $all = @($Samples)
    $ok  = @($all | Where-Object { $null -ne $_.Ms } | ForEach-Object Ms)
    $s = [ordered]@{ Count = $all.Count; Lost = $all.Count - $ok.Count; LossPct = 0; Median = $null; P95 = $null; Jitter = $null; Last = $null }
    if ($all.Count -eq 0) { return [pscustomobject]$s }
    $s.LossPct = 100.0 * $s.Lost / $all.Count
    $s.Last = $all[-1].Ms
    if ($ok.Count -gt 0) {
        $sorted = @($ok | Sort-Object)
        $s.Median = $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
        $s.P95    = $sorted[[int][Math]::Floor(($sorted.Count - 1) * 0.95)]
    }
    if ($ok.Count -gt 1) {
        $sum = 0.0
        for ($i = 1; $i -lt $ok.Count; $i++) { $sum += [Math]::Abs($ok[$i] - $ok[$i - 1]) }
        $s.Jitter = $sum / ($ok.Count - 1)
    }
    [pscustomobject]$s
}

function Get-TargetStatus {
    param($Stats, [string]$Kind)   # Kind: RouterWired, RouterWifi, Internet, Region
    if (-not $Stats -or $Stats.Count -lt 5) { return 'none' }
    if ($Stats.LossPct -ge 100) { return 'bad' }
    $l = $script:Limits[$Kind]
    $status = 'good'
    $checks = @(
        @{ Value = $Stats.LossPct; Warn = $l.LossWarn;   Bad = $l.LossBad }
        @{ Value = $Stats.Jitter;  Warn = $l.JitterWarn; Bad = $l.JitterBad }
        @{ Value = $Stats.Median;  Warn = $l.MedianWarn; Bad = $l.MedianBad }
    )
    foreach ($c in $checks) {
        if ($null -eq $c.Value) { continue }
        if ($c.Value -ge $c.Bad) { return 'bad' }
        if ($c.Value -ge $c.Warn) { $status = 'warn' }
    }
    $status
}

function Get-WorstStatus {
    param([string[]]$Statuses)
    $worst = 'none'
    foreach ($s in $Statuses) { if ($script:StatusRank[$s] -gt $script:StatusRank[$worst]) { $worst = $s } }
    $worst
}

function Get-Verdict {
    <#
        The five questions, in order:
          1. Is the router bad?                          -> inside your home
          2. Router fine, 2+ of 3 internet targets bad?  -> ISP or line
          3. Only one internet target bad?               -> that company's hiccup, not you
          4. Everything fine except a game region?       -> the route to that region
          5. Otherwise                                   -> healthy
        Status per target: good / warn / bad / none (not enough data).
    #>
    param([hashtable]$Status, [hashtable]$Stats, [bool]$IsWifi, [bool]$HasRouter, [string[]]$InternetKeys, $Regions, [hashtable]$Names)

    $place = if ($IsWifi) { 'Wi-Fi' } else { 'cable or router' }
    $internetBad  = @($InternetKeys | Where-Object { $Status[$_] -eq 'bad' })
    $internetWarn = @($InternetKeys | Where-Object { $Status[$_] -eq 'warn' })
    $internetDead = @($InternetKeys | Where-Object { $Stats[$_] -and $Stats[$_].LossPct -ge 100 })

    if ($HasRouter -and $Stats.Router -and $Stats.Router.LossPct -ge 100) {
        return @{ Key = 'norouter'; Level = 'bad'; Title = "Your PC can't reach your router"
                  Detail = 'Nothing past this point can work. Check the cable or Wi-Fi connection, or restart the router.' }
    }
    if ($internetDead.Count -eq $InternetKeys.Count) {
        return @{ Key = 'nointernet'; Level = 'bad'; Title = 'No internet: your router answers, but nothing beyond it does'
                  Detail = 'Your home network is fine. The router has lost its internet connection - restart the router, or check for an outage with your ISP.' }
    }

    # 1. Router
    if ($Status.Router -eq 'bad') {
        $detail = if ($IsWifi) { 'Pings to your own router are dropping or jumping around, so the problem is the Wi-Fi link. Try 5 GHz, move closer to the router, or use a cable.' }
                  else { 'Pings to your own router are dropping or jumping around even over a cable. Try another cable or router port, or restart the router.' }
        return @{ Key = 'home'; Level = 'bad'; Title = "The problem is inside your home ($place)"; Detail = $detail }
    }
    # 2. Two or more internet targets
    if ($internetBad.Count -ge 2) {
        return @{ Key = 'isp'; Level = 'bad'; Title = 'Your ISP or line is having problems'
                  Detail = "Your router is fine, but $($internetBad.Count) of 3 internet targets are unstable at the same time. That points past your home: the line or your ISP. If it keeps happening, the Route Check gives details to show your ISP." }
    }

    $regionBad = @($Regions | Where-Object { $Status[$_.Key] -eq 'bad' } | ForEach-Object { $_.Name })
    $oneProviderNote = ''
    # 3. Only one internet target
    if ($internetBad.Count -eq 1) {
        $oneProviderNote = " $($Names[$internetBad[0]]) is having a hiccup right now - that's on their side, not yours."
    }
    # 4. Game regions
    if ($regionBad.Count -gt 0) {
        $list = $regionBad -join ', '
        return @{ Key = "region:$list"; Level = 'warn'; Title = "Your connection is fine, but the route to $list is unstable"
                  Detail = "Your home network and internet look stable. The problem is somewhere between your ISP and $list - you can't fix that from your PC. Servers in another region may play better for now.$oneProviderNote" }
    }
    # Small hiccups
    if ($Status.Router -eq 'warn') {
        return @{ Key = 'homewarn'; Level = 'warn'; Title = 'Mostly fine, with small hiccups inside your home'
                  Detail = "Your link to the router ($place) shows some jitter or the odd lost packet. Usually not noticeable, but it's the first thing to improve.$oneProviderNote" }
    }
    if ($internetWarn.Count + $internetBad.Count -ge 2) {
        return @{ Key = 'ispwarn'; Level = 'warn'; Title = 'Mostly fine, with small hiccups beyond your router'
                  Detail = "Your home network is stable, but the internet targets show some jitter or the odd lost packet. Often busy-hour traffic at the ISP.$oneProviderNote" }
    }
    # 5. Healthy
    @{ Key = if ($oneProviderNote) { 'healthy1' } else { 'healthy' }; Level = 'good'; Title = 'Your connection is healthy'
       Detail = "Router, internet and game regions are all stable. If a game still lags, it's most likely the game server or your PC.$oneProviderNote" }
}

function Get-RoundEvent {
    <#
        Looks at one ping round (all targets pinged at the same moment) and
        decides whether it's worth a line in the event list.
        A target "spikes" when it is lost or clearly above its own normal ping.
    #>
    param($Round, [hashtable]$Normal, [bool]$IsWifi, [string[]]$InternetKeys)

    function Test-Spike($key, [double]$extra) {
        if (-not $Round.Ms.ContainsKey($key)) { return $false }
        $ms = $Round.Ms[$key]
        if ($null -eq $ms) { return $true }
        if ($null -eq $Normal[$key]) { return $false }
        $ms -gt ($Normal[$key] * 2 + $extra)
    }
    function Test-Lost($key) { $Round.Ms.ContainsKey($key) -and $null -eq $Round.Ms[$key] }

    $routerExtra = if ($IsWifi) { 30 } else { 10 }
    $routerSpike = Test-Spike 'Router' $routerExtra
    $spiked = @($InternetKeys | Where-Object { Test-Spike $_ 25 })
    $lost   = @($InternetKeys | Where-Object { Test-Lost $_ })
    $worst  = ($InternetKeys | ForEach-Object { $Round.Ms[$_] } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
    $what   = if ($lost.Count -ge 2) { 'Lost packets' } elseif ($worst) { "Spike to $([int]$worst) ms" } else { 'Lost packets' }
    $place   = if ($IsWifi) { 'Wi-Fi' } else { 'cable or router' }

    if ($routerSpike -and $spiked.Count -ge 2) {
        return @{ Type = 'home'; Level = 'bad'; Text = "$what on everything, including your router -> the problem is inside your home ($place)." }
    }
    if ($routerSpike) {
        $r = if ($null -eq $Round.Ms.Router) { 'lost' } else { "$([int]$Round.Ms.Router) ms" }
        return @{ Type = 'router'; Level = 'warn'; Text = "Your router itself answered slowly ($r) -> $place hiccup." }
    }
    if ($spiked.Count -ge 2) {
        return @{ Type = 'isp'; Level = 'bad'; Text = "$what on $($spiked.Count) of 3 internet targets, router fine -> beyond your home (ISP or line)." }
    }
    $null
}
