<#
    Reads how this PC is connected: which adapter, which router, which DNS
    server, and Wi-Fi signal details. Read-only - nothing here changes a setting.
    Also loaded inside the background measuring threads.
#>

function Get-ConnectionInfo {
    # The adapter and router that internet traffic actually leaves through.
    # VPN tunnels add default routes without a real next hop, so those are skipped
    # when looking for the router.
    $info = [ordered]@{
        Found = $false; Gateway = $null; InterfaceIndex = $null; AdapterName = $null; Description = $null
        IsWifi = $false; LinkSpeedBps = 0; IPv4 = $null; DnsServers = @(); TrafficAdapter = $null; TrafficDns = @()
    }

    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } |
        Select-Object -First 1
    if (-not $route) { return [pscustomobject]$info }

    $adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    $info.Found          = $true
    $info.Gateway        = $route.NextHop
    $info.InterfaceIndex = $route.ifIndex
    if ($adapter) {
        $info.AdapterName  = $adapter.Name
        $info.Description  = $adapter.InterfaceDescription
        $info.IsWifi       = $adapter.PhysicalMediaType -match '802\.11' -or $adapter.NdisPhysicalMedium -eq 9
        $info.LinkSpeedBps = [double]$adapter.ReceiveLinkSpeed
    }
    $info.IPv4 = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $info.DnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

    # Where traffic to the internet really goes (differs from the router's adapter when a VPN is carrying it)
    $traffic = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($traffic -and $traffic.InterfaceIndex -ne $route.ifIndex) {
        $info.TrafficAdapter = (Get-NetAdapter -InterfaceIndex $traffic.InterfaceIndex -ErrorAction SilentlyContinue).Name
        $info.TrafficDns     = @((Get-DnsClientServerAddress -InterfaceIndex $traffic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }
    [pscustomobject]$info
}

function Get-WifiInfo {
    # Signal, band and channel from "netsh wlan show interfaces".
    # Labels are matched in English first; on other Windows languages the values
    # are recognised by their shape (85%, 5 GHz, 802.11ax).
    $lines = @(netsh wlan show interfaces 2>$null)
    if (-not $lines) { return $null }

    $wifi = [ordered]@{ Connected = $false; Signal = $null; Band = $null; Channel = $null; RadioType = $null; ReceiveMbps = $null; TransmitMbps = $null; Hidden = $false }
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*([^:]+?)\s*:\s*(.+?)\s*$') { continue }
        $label = $Matches[1]; $value = $Matches[2]
        switch -Regex ($label) {
            '^State$'                { $wifi.Connected = $value -eq 'connected' }
            '^Signal$'               { if ($value -match '(\d+)\s*%') { $wifi.Signal = [int]$Matches[1] } }
            '^Band$'                 { $wifi.Band = $value }
            '^Channel$'              { if ($value -match '^\d+$') { $wifi.Channel = [int]$value } }
            '^Radio type$'           { $wifi.RadioType = $value }
            '^Receive rate \(Mbps\)' { if ($value -match '^[\d.]+$') { $wifi.ReceiveMbps = [double]$value } }
            '^Transmit rate \(Mbps\)'{ if ($value -match '^[\d.]+$') { $wifi.TransmitMbps = [double]$value } }
            default {
                if (-not $wifi.Signal    -and $value -match '^(\d+)\s*%$')        { $wifi.Signal = [int]$Matches[1]; $wifi.Connected = $true }
                if (-not $wifi.Band      -and $value -match '^[\d.]+\s*GHz$')     { $wifi.Band = $value }
                if (-not $wifi.RadioType -and $value -match '^802\.11')           { $wifi.RadioType = $value }
            }
        }
    }
    if ($wifi.Signal) { $wifi.Connected = $true }
    # Newer Windows hides Wi-Fi details from apps unless Location access is allowed
    if ($wifi.Connected -and -not $wifi.Signal) { $wifi.Hidden = $true }
    if (-not $wifi.Band -and $wifi.Channel) {
        $wifi.Band = if ($wifi.Channel -le 14) { '2.4 GHz' } else { '5 GHz' }
    }
    [pscustomobject]$wifi
}

function Get-AdapterSpeedInfo {
    # What the network card supports, and whether its speed or power saving was set by hand
    param([string]$AdapterName)
    $result = [ordered]@{ MaxBps = 0; SpeedSetting = $null; PowerSaving = @() }
    if (-not $AdapterName) { return [pscustomobject]$result }

    $props = @(Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue)
    $speed = $props | Where-Object RegistryKeyword -eq '*SpeedDuplex' | Select-Object -First 1
    if ($speed) {
        $result.SpeedSetting = $speed.DisplayValue
        foreach ($v in @($speed.ValidDisplayValues)) {
            if ($v -match '([\d.]+)\s*(G|M)bps') {
                $bps = [double]$Matches[1] * $(if ($Matches[2] -eq 'G') { 1e9 } else { 1e6 })
                if ($bps -gt $result.MaxBps) { $result.MaxBps = $bps }
            }
        }
    }
    $powerKeywords = '^\*EEE$|^AdvancedEEE$|^EnableGreenEthernet$|^GigaLite$|^PowerSavingMode$|^EEELinkAdvertisement$'
    $result.PowerSaving = @($props | Where-Object { $_.RegistryKeyword -match $powerKeywords -and $_.DisplayValue -match '^(Enabled|On)$' } |
                            ForEach-Object DisplayName)
    [pscustomobject]$result
}

function Get-AdapterErrorCount {
    param($InterfaceIndex)
    if (-not $InterfaceIndex) { return $null }
    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $adapter) { return $null }
    $s = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    [double]($s.ReceivedPacketErrors + $s.ReceivedDiscardedPackets + $s.OutboundPacketErrors + $s.OutboundDiscardedPackets)
}

function Test-PrivateAddress {
    # Home-network addresses, plus the 100.64.x.x range ISPs use internally
    param([string]$Address)
    $Address -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)'
}

function Test-IspSharedAddress {
    param([string]$Address)
    $Address -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.'
}

function Format-Speed {
    param([double]$Bps)
    if ($Bps -ge 1e9) { return ('{0:0.#} Gbps' -f ($Bps / 1e9)) }
    if ($Bps -ge 1e6) { return ('{0:0} Mbps' -f ($Bps / 1e6)) }
    if ($Bps -gt 0)   { return ('{0:0} kbps' -f ($Bps / 1e3)) }
    'unknown'
}

function Format-Ms {
    param($Value)
    if ($null -eq $Value) { return '--' }
    if ($Value -lt 1) { return '<1 ms' }
    '{0:0} ms' -f $Value
}
