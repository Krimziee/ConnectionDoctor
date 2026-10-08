<#
    What Connection Doctor measures. Edit this file to change targets;
    the code does not need to change.

    Internet  - pinged once per second. Three different companies, so one of
                them having a bad moment can't be mistaken for your connection.
    Regions   - game hosting regions, tested with a TCP connection every few
                seconds (most game servers ignore pings).
                Primary: an AWS regional endpoint (many games host on AWS).
                Steam:   code of Valve's relay in that city, used when the
                         primary doesn't answer. The address is read from
                         Valve's published relay list when the tool starts.
#>
@{
    Internet = @(
        @{ Key = 'Cloudflare'; Name = 'Cloudflare'; Address = '1.1.1.1'; Color = '#F6A04D' }
        @{ Key = 'Google';     Name = 'Google';     Address = '8.8.8.8'; Color = '#4CA6FF' }
        @{ Key = 'Quad9';      Name = 'Quad9';      Address = '9.9.9.9'; Color = '#B48CFF' }
    )

    Regions = @(
        @{ Key = 'Frankfurt'; Name = 'Frankfurt'; Host = 'dynamodb.eu-central-1.amazonaws.com'; Port = 443; Steam = 'fra'; Color = '#4CD6A6' }
        @{ Key = 'London';    Name = 'London';    Host = 'dynamodb.eu-west-2.amazonaws.com';    Port = 443; Steam = 'lhr'; Color = '#FF7EB6' }
        @{ Key = 'USEast';    Name = 'US East';   Host = 'dynamodb.us-east-1.amazonaws.com';    Port = 443; Steam = 'iad'; Color = '#FCE100' }
    )

    SteamRelayList = 'https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730'

    # Used by the DNS Test: popular gaming and general domains
    DnsDomains = @('steampowered.com', 'epicgames.com', 'riotgames.com', 'microsoft.com', 'discord.com')

    # Used by Lag Under Load: Cloudflare's public speed-test file. Read and thrown away, never saved.
    LoadTestUrl     = 'https://speed.cloudflare.com/__down?bytes=25000000'
    LoadTestStreams = 4      # 4 x 25 MB = at most 100 MB
    LoadTestSeconds = 15
}
