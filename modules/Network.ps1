<#
    Reads how this PC is connected: which adapter, which router, which DNS
    server, and Wi-Fi signal details. Read-only - nothing here changes a setting.
    Also loaded inside the background measuring threads.
#>

# Windows' network classes are read directly. Get-NetRoute, Get-NetAdapter and the other
# network cmdlets load modules that take over a second and about 25 MB of memory per thread.
function Get-NetClass {
    param([string]$Class, [string]$Filter)
    @(Get-CimInstance -Namespace 'root\StandardCimv2' -ClassName $Class -Filter $Filter -ErrorAction SilentlyContinue)
}

function ConvertTo-WqlText {
    # Adapter names are chosen by the user and can contain quotes or backslashes
    param([string]$Text)
    $Text -replace '\\', '\\' -replace "'", "\'"
}

function Get-DnsServers {
    param([int]$InterfaceIndex)
    @(Get-NetClass MSFT_DNSClientServerAddress "InterfaceIndex=$InterfaceIndex AND AddressFamily=2" | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
}

function Get-ConnectionInfo {
    # The adapter and router that internet traffic actually leaves through.
    # VPN tunnels add default routes without a real next hop, so those are skipped
    # when looking for the router.
    $info = [ordered]@{
        Found = $false; Gateway = $null; InterfaceIndex = $null; AdapterName = $null; Description = $null
        IsWifi = $false; LinkSpeedBps = 0; IPv4 = $null; DnsServers = @(); TrafficAdapter = $null; TrafficDns = @()
    }

    $metric = @{}
    foreach ($i in Get-NetClass MSFT_NetIPInterface 'AddressFamily=2') { $metric[[int]$i.InterfaceIndex] = [int]$i.InterfaceMetric }
    $route = Get-NetClass MSFT_NetRoute "DestinationPrefix='0.0.0.0/0'" |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object { $_.RouteMetric + $metric[[int]$_.InterfaceIndex] } |
        Select-Object -First 1
    if (-not $route) { return [pscustomobject]$info }

    $index = [int]$route.InterfaceIndex
    $adapter = Get-NetClass MSFT_NetAdapter "InterfaceIndex=$index" | Select-Object -First 1
    $info.Found          = $true
    $info.Gateway        = $route.NextHop
    $info.InterfaceIndex = $index
    if ($adapter) {
        $info.AdapterName  = $adapter.Name
        $info.Description  = $adapter.InterfaceDescription
        $info.IsWifi       = $adapter.NdisPhysicalMedium -eq 9   # Native 802.11
        $info.LinkSpeedBps = [double]$adapter.ReceiveLinkSpeed
    }
    $info.IPv4 = (Get-NetClass MSFT_NetIPAddress "InterfaceIndex=$index AND AddressFamily=2" | Select-Object -First 1).IPAddress
    $info.DnsServers = @(Get-DnsServers $index)

    # Where traffic to the internet really goes (differs from the router's adapter when a VPN is carrying it).
    # Windows picks the source address for 1.1.1.1; a UDP "connect" only does that lookup and sends nothing.
    try {
        $udp = New-Object Net.Sockets.Socket ([Net.Sockets.AddressFamily]::InterNetwork), ([Net.Sockets.SocketType]::Dgram), ([Net.Sockets.ProtocolType]::Udp)
        try { $udp.Connect('1.1.1.1', 53); $source = $udp.LocalEndPoint.Address.ToString() } finally { $udp.Dispose() }
        $traffic = [int](Get-NetClass MSFT_NetIPAddress "IPAddress='$source'" | Select-Object -First 1).InterfaceIndex
        if ($traffic -and $traffic -ne $index) {
            $name = (Get-NetClass MSFT_NetAdapter "InterfaceIndex=$traffic" | Select-Object -First 1).Name
            if (-not $name) { $name = (Get-NetClass MSFT_NetIPInterface "InterfaceIndex=$traffic AND AddressFamily=2" | Select-Object -First 1).InterfaceAlias }
            $info.TrafficAdapter = $name
            $info.TrafficDns     = @(Get-DnsServers $traffic)
        }
    } catch { }   # no route to the internet: nothing to add
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

    $props = Get-NetClass MSFT_NetAdapterAdvancedPropertySettingData "Name='$(ConvertTo-WqlText $AdapterName)'"
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
    $adapter = Get-NetClass MSFT_NetAdapter "InterfaceIndex=$([int]$InterfaceIndex)" | Select-Object -First 1
    if (-not $adapter) { return $null }
    $s = Get-NetClass MSFT_NetAdapterStatisticsSettingData "Name='$(ConvertTo-WqlText $adapter.Name)'" | Select-Object -First 1
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
