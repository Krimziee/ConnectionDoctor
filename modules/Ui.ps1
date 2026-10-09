<#
    The Connection Doctor window (WPF, built into Windows).
    The live monitor starts as soon as the window opens. Background threads
    (modules\Monitor.ps1) measure; a once-per-second timer here reads their
    results, updates the tiles, graph and event list, and every 10 seconds
    asks modules\Judge.ps1 for a verdict. Tests run on their own thread.
    The page (ui\Page.xaml) is shown by the standalone window and by the
    Connection Doctor tab in Krimz's Toolkit (modules\Page.ps1). In the toolkit
    the monitor only measures while its tab is selected.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Ui = @{}                 # named controls from MainWindow.xaml
$script:Colors = @{ Text = '#F3F3F3'; Muted = '#A6A6A6'; Faint = '#707070'; Grid = '#333333'; Lost = '#FF5C5C' }
$script:LevelColors = @{ good = '#6CCB5F'; warn = '#FCE100'; bad = '#FF99A4'; info = '#4CA6FF'; none = '#808080' }
$script:RouterColor = '#E6E6E6'

$script:State = @{
    Started = $null; Tick = 0; Jobs = @(); Test = $null
    History = @{}; Stats = @{}; Status = @{}; Normal = @{}; Hidden = @{}; Tiles = @{}
    Spans = New-Object System.Collections.Generic.List[object]
    LastEvent = @{}; RegionFails = @{}; RegionVia = @{}
    Verdict = $null; PendingVerdict = $null; LastWifi = $null; BaselineErrors = $null
    UserPaused = $false   # the Pause button
    OnBusy = $null        # Krimz's Toolkit: shows the working dot while a test runs
}

# ------------------------------------------------------------------
#  Small helpers
# ------------------------------------------------------------------

function Get-NativeMethods {
    # The few Windows functions the window needs, built in memory (no compiler, nothing written to disk)
    if ($script:Native) { return $script:Native }
    $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'ConnectionDoctorNative'), 'Run')
    $type = $assembly.DefineDynamicModule('ConnectionDoctorNative').DefineType('Native', 'Public, Class')
    $functions = @(
        @{ Dll = 'user32.dll'; Name = 'SetProcessDpiAwarenessContext'; Returns = [bool]; Parameters = @([IntPtr]) }
        @{ Dll = 'user32.dll'; Name = 'SetProcessDPIAware';            Returns = [bool]; Parameters = @() }
        @{ Dll = 'dwmapi.dll'; Name = 'DwmSetWindowAttribute';         Returns = [int];  Parameters = @([IntPtr], [int], [int].MakeByRefType(), [int]) }
    )
    foreach ($f in $functions) {
        $method = $type.DefinePInvokeMethod($f.Name, $f.Dll, 'Public, Static, PinvokeImpl', 'Standard', $f.Returns,
                                            [Type[]]$f.Parameters, 'Winapi', 'Auto')
        $method.SetImplementationFlags('PreserveSig')
    }
    $script:Native = $type.CreateType()
    $script:Native
}

function Enable-DpiAwareness {
    # Sharp text on high-resolution screens. Only affects this program while it runs.
    try {
        $native = Get-NativeMethods
        if (-not $native::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) { [void]$native::SetProcessDPIAware() }
    } catch { }
}

function Invoke-UiSafely {
    # An error inside a handler or the timer must never close the window
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        # Shown once in the event list; repeating every second would bury everything else
        $script:State.LastError = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
        if (-not $script:State.ErrorShown) {
            $script:State.ErrorShown = $true
            try { Add-Event 'bad' "Internal error: $($_.Exception.Message)" } catch { }
        }
    }
}

function New-Text {
    param([string]$Text, [string]$Color = $script:Colors.Text, [double]$Size = 13, [string]$Weight = 'Normal', [string]$Margin = '0')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = $Color
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.Margin = $Margin
    $t.TextWrapping = 'Wrap'
    $t
}

function New-Dot {
    param([string]$Color, [double]$Size = 8, [string]$Margin = '0,0,8,0')
    $e = New-Object System.Windows.Shapes.Ellipse
    $e.Width = $Size; $e.Height = $Size
    $e.Fill = $Color
    $e.Margin = $Margin
    $e.VerticalAlignment = 'Center'
    $e
}

function Get-PlanMbps {
    $value = 0.0
    $text = ($script:Ui.PlanBox.Text -replace ',', '.').Trim()
    if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and $value -gt 0) { return $value }
    0.0
}

# ------------------------------------------------------------------
#  Targets, tiles and history
# ------------------------------------------------------------------

function Get-SeriesList {
    # Every line on the graph, in tile order: router, internet targets, regions
    $list = @(@{ Key = 'Router'; Name = 'Router'; Color = $script:RouterColor; Kind = 'Router' })
    foreach ($t in $script:Targets.Internet) { $list += @{ Key = $t.Key; Name = $t.Name; Color = $t.Color; Kind = 'Internet' } }
    foreach ($r in $script:Targets.Regions)  { $list += @{ Key = $r.Key; Name = $r.Name; Color = $r.Color; Kind = 'Region' } }
    $list
}

function New-Tiles {
    $script:Ui.TilesGrid.Columns = $script:Series.Count
    foreach ($s in $script:Series) {
        $border = New-Object System.Windows.Controls.Border
        $border.Background = '#272727'
        $border.BorderBrush = '#3A3A3A'
        $border.BorderThickness = 1
        $border.CornerRadius = 8
        $border.Padding = '10,8'
        $border.Margin = '4,0'
        $border.Cursor = 'Hand'
        $border.Tag = $s.Key
        $border.ToolTip = 'Click to hide or show this line on the graph'

        $panel = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        [void]$head.Children.Add((New-Dot $s.Color 9))
        [void]$head.Children.Add((New-Text $s.Name $script:Colors.Muted 12 'SemiBold'))
        [void]$panel.Children.Add($head)

        $value = New-Text '--' $script:LevelColors.none 22 'SemiBold' '0,2,0,0'
        $line1 = New-Text '' $script:Colors.Muted 11
        $line2 = New-Text '' $script:Colors.Muted 11
        foreach ($c in $value, $line1, $line2) { [void]$panel.Children.Add($c) }
        $border.Child = $panel

        $border.Add_MouseLeftButtonUp({
            Invoke-UiSafely {
                $key = $this.Tag
                $script:State.Hidden[$key] = -not $script:State.Hidden[$key]
                $this.Opacity = if ($script:State.Hidden[$key]) { 0.4 } else { 1 }
                Update-Graph
            }
        })
        [void]$script:Ui.TilesGrid.Children.Add($border)
        $script:State.Tiles[$s.Key] = @{ Value = $value; Line1 = $line1; Line2 = $line2 }
        $script:State.History[$s.Key] = New-Object System.Collections.Generic.List[object]
    }
}

function Add-Sample {
    param([string]$Key, [datetime]$Time, $Ms)
    $list = $script:State.History[$Key]
    if ($null -eq $list) { return }
    $list.Add([pscustomobject]@{ T = $Time; Ms = $Ms })
}

function Get-Window {
    # Samples from the last N seconds
    param([string]$Key, [int]$Seconds)
    $from = (Get-Date).AddSeconds(-$Seconds)
    $list = $script:State.History[$Key]
    $i = $list.Count - 1
    while ($i -ge 0 -and $list[$i].T -ge $from) { $i-- }
    if ($i -ge $list.Count - 1) { return @() }
    $list.GetRange($i + 1, $list.Count - $i - 1)
}

function Get-StatusKind {
    param($Series)
    if ($Series.Kind -eq 'Router') {
        if ($script:Shared.Connection.IsWifi) { return 'RouterWifi' } else { return 'RouterWired' }
    }
    $Series.Kind
}

function Update-Stats {
    foreach ($s in $script:Series) {
        # Regions are tested every 5 s, so they get a longer window to have enough samples
        $seconds = if ($s.Kind -eq 'Region') { 120 } else { 60 }
        $stats = Get-SampleStats (Get-Window $s.Key $seconds)
        $script:State.Stats[$s.Key]  = $stats
        $script:State.Status[$s.Key] = Get-TargetStatus $stats (Get-StatusKind $s)
        $script:State.Normal[$s.Key] = $stats.Median
    }
}

function Update-Tiles {
    foreach ($s in $script:Series) {
        $tile = $script:State.Tiles[$s.Key]
        $st = $script:State.Stats[$s.Key]
        $status = $script:State.Status[$s.Key]
        if ($s.Key -eq 'Router' -and -not $script:Shared.Connection.Gateway) {
            $tile.Value.Text = 'not found'; $tile.Value.Foreground = $script:LevelColors.none
            $tile.Line1.Text = 'No router detected'; $tile.Line2.Text = ''
            continue
        }
        if (-not $st -or $st.Count -eq 0) {
            $tile.Value.Text = '--'; $tile.Line1.Text = 'waiting...'; $tile.Line2.Text = ''
            continue
        }
        $tile.Value.Text = if ($null -eq $st.Last) { 'lost' } else { Format-Ms $st.Last }
        $tile.Value.Foreground = $script:LevelColors[$status]
        $jitter = if ($null -ne $st.Jitter) { '{0:0.#} ms' -f $st.Jitter } else { '--' }
        $tile.Line1.Text = "normal $(Format-Ms $st.Median)"
        $loss = "jitter $jitter · loss {0:0.#}%" -f $st.LossPct
        if ($s.Kind -eq 'Region' -and $script:State.RegionVia[$s.Key] -eq 'Steam') { $loss += ' · via Steam' }
        $tile.Line2.Text = $loss
    }
}

# ------------------------------------------------------------------
#  Graph
# ------------------------------------------------------------------

function New-PointGeometry {
    # Lines through the samples, broken at lost pings and gaps (pauses)
    param($Samples, [scriptblock]$ToX, [scriptblock]$ToY, [double]$MaxGap)
    $geometry = New-Object System.Windows.Media.StreamGeometry
    $ctx = $geometry.Open()
    $open = $false; $lastT = $null
    foreach ($p in $Samples) {
        if ($null -eq $p.Ms -or ($lastT -and ($p.T - $lastT).TotalSeconds -gt $MaxGap)) { $open = $false }
        if ($null -ne $p.Ms) {
            $pt = New-Object System.Windows.Point((& $toX $p.T), (& $toY $p.Ms))
            if ($open) { $ctx.LineTo($pt, $true, $true) } else { $ctx.BeginFigure($pt, $false, $false); $open = $true }
        }
        $lastT = $p.T
    }
    $ctx.Close()
    $geometry.Freeze()
    $geometry
}

function Add-CanvasText {
    param([string]$Text, [double]$Left, [double]$Top, [string]$Color = $script:Colors.Faint, [double]$Size = 11)
    $t = New-Text $Text $Color $Size
    $t.TextWrapping = 'NoWrap'
    [System.Windows.Controls.Canvas]::SetLeft($t, $Left)
    [System.Windows.Controls.Canvas]::SetTop($t, $Top)
    [void]$script:Ui.GraphCanvas.Children.Add($t)
}

function Update-Graph {
    $canvas = $script:Ui.GraphCanvas
    $canvas.Children.Clear()
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
    if ($w -lt 100 -or $h -lt 60) { return }

    $windowSeconds = 120
    $now = Get-Date
    $from = $now.AddSeconds(-$windowSeconds)
    $left = 44.0; $top = 14.0; $bottom = 18.0
    $plotW = $w - $left - 4; $plotH = $h - $top - $bottom

    # Scale: fits the visible lines' usual values; rare spikes are clipped at the top
    $peaks = foreach ($s in $script:Series) {
        if ($script:State.Hidden[$s.Key]) { continue }
        $st = $script:State.Stats[$s.Key]
        if ($st -and $null -ne $st.P95) { $st.P95 }
    }
    $need = (@($peaks) + 0 | Measure-Object -Maximum).Maximum * 1.25
    $max = 20
    foreach ($step in 20, 50, 100, 150, 200, 300, 500, 1000, 2000) { $max = $step; if ($step -ge $need) { break } }

    $toX = { param($t) $left + ($t - $from).TotalSeconds / $windowSeconds * $plotW }.GetNewClosure()
    $toY = { param($ms) $top + $plotH - ([Math]::Min($ms, $max) / $max) * $plotH }.GetNewClosure()

    # Test periods, shaded. Labels alternate between two rows so tests run close together don't overlap.
    $row = 0
    foreach ($span in $script:State.Spans) {
        $end = if ($span.End) { $span.End } else { $now }
        if ($end -lt $from) { continue }
        $x1 = [Math]::Max($left, (& $toX $span.Start)); $x2 = & $toX $end
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = [Math]::Max(2, $x2 - $x1); $rect.Height = $plotH
        $rect.Fill = '#1F4CA6FF'
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x1)
        [System.Windows.Controls.Canvas]::SetTop($rect, $top)
        [void]$canvas.Children.Add($rect)
        Add-CanvasText $span.Name ($x1 + 4) ($top + 2 + 15 * ($row % 2)) '#4CA6FF'
        $row++
    }

    # Grid lines and labels
    foreach ($i in 0..4) {
        $value = $max * $i / 4
        $y = & $toY $value
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $left; $line.X2 = $left + $plotW; $line.Y1 = $y; $line.Y2 = $y
        $line.Stroke = $script:Colors.Grid; $line.StrokeThickness = 1
        [void]$canvas.Children.Add($line)
        Add-CanvasText ('{0:0} ms' -f $value) 0 ($y - 8)
    }
    Add-CanvasText '2 min ago' $left ($h - 15)
    Add-CanvasText '1 min ago' ($left + $plotW / 2 - 24) ($h - 15)
    Add-CanvasText 'now' ($left + $plotW - 22) ($h - 15)

    # One line per target, and red ticks at the bottom for lost pings
    $lostGeometry = New-Object System.Windows.Media.StreamGeometry
    $lostCtx = $lostGeometry.Open()
    foreach ($s in $script:Series) {
        if ($script:State.Hidden[$s.Key]) { continue }
        $samples = Get-Window $s.Key ($windowSeconds + 2)
        if ($samples.Count -eq 0) { continue }
        $gap = if ($s.Kind -eq 'Region') { 12 } else { 2.5 }
        $path = New-Object System.Windows.Shapes.Path
        $path.Data = New-PointGeometry $samples $toX $toY $gap
        $path.Stroke = $s.Color
        $path.StrokeThickness = if ($s.Kind -eq 'Region') { 1.6 } else { 1.4 }
        $path.StrokeLineJoin = 'Round'
        [void]$canvas.Children.Add($path)
        foreach ($p in $samples) {
            if ($null -ne $p.Ms -or $p.T -lt $from) { continue }
            $x = & $toX $p.T
            $lostCtx.BeginFigure((New-Object System.Windows.Point($x, ($top + $plotH))), $false, $false)
            $lostCtx.LineTo((New-Object System.Windows.Point($x, ($top + $plotH - 8))), $true, $false)
        }
    }
    $lostCtx.Close()
    $lostPath = New-Object System.Windows.Shapes.Path
    $lostPath.Data = $lostGeometry
    $lostPath.Stroke = $script:Colors.Lost
    $lostPath.StrokeThickness = 2
    [void]$canvas.Children.Add($lostPath)
}

# ------------------------------------------------------------------
#  Events, verdict, header, Wi-Fi
# ------------------------------------------------------------------

function Add-Event {
    param([string]$Level, [string]$Text, [string]$Type, [int]$CooldownSeconds = 0)
    # The same kind of event is shown at most once per cooldown, so a bad minute doesn't flood the list
    if ($Type -and $CooldownSeconds -gt 0) {
        $last = $script:State.LastEvent[$Type]
        if ($last -and ((Get-Date) - $last).TotalSeconds -lt $CooldownSeconds) { return }
        $script:State.LastEvent[$Type] = Get-Date
    }
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = '0,0,0,6'
    $time = New-Text (Get-Date).ToString('HH:mm:ss') $script:Colors.Faint 12 -Margin '0,0,8,0'
    $dot = New-Dot $script:LevelColors[$Level] 7 '0,5,8,0'
    $dot.VerticalAlignment = 'Top'
    [System.Windows.Controls.DockPanel]::SetDock($time, 'Left')
    [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
    [void]$row.Children.Add($time)
    [void]$row.Children.Add($dot)
    [void]$row.Children.Add((New-Text $Text $script:Colors.Text 12))
    $script:Ui.EventsPanel.Children.Insert(0, $row)
    while ($script:Ui.EventsPanel.Children.Count -gt 200) { $script:Ui.EventsPanel.Children.RemoveAt(200) }
}

function Set-Verdict {
    param([hashtable]$Verdict)
    $script:Ui.VerdictDot.Fill = $script:LevelColors[$Verdict.Level]
    $script:Ui.VerdictTitle.Text = $Verdict.Title
    $script:Ui.VerdictDetail.Text = $Verdict.Detail
}

function Update-Verdict {
    $elapsed = ((Get-Date) - $script:State.Started).TotalSeconds
    if ($script:Shared.Paused) {
        Set-Verdict @{ Level = 'none'; Title = 'Paused'; Detail = 'The live monitor is paused. Press Resume to continue measuring.' }
        return
    }
    if ($elapsed -lt 30) {
        Set-Verdict @{ Level = 'none'; Title = 'Measuring...'; Detail = ('First verdict in {0:0} seconds. It updates every 10 seconds after that, and only changes once a new pattern holds.' -f (30 - $elapsed)) }
        return
    }
    if ($script:State.Tick % 10 -ne 0 -and $script:State.Verdict) { return }

    $internetKeys = @($script:Targets.Internet | ForEach-Object { $_.Key })
    $names = @{}; foreach ($s in $script:Series) { $names[$s.Key] = $s.Name }
    $new = Get-Verdict -Status $script:State.Status -Stats $script:State.Stats -IsWifi ([bool]$script:Shared.Connection.IsWifi) `
                       -HasRouter ([bool]$script:Shared.Connection.Gateway) -InternetKeys $internetKeys -Regions $script:Targets.Regions -Names $names

    # Change only when the new verdict is seen twice in a row (20 s), so one spike doesn't flip it
    $current = $script:State.Verdict
    if (-not $current -or $new.Key -eq $current.Key) {
        $script:State.Verdict = $new; $script:State.PendingVerdict = $null
    } elseif ($script:State.PendingVerdict -and $script:State.PendingVerdict.Key -eq $new.Key) {
        $script:State.Verdict = $new; $script:State.PendingVerdict = $null
        Add-Event $new.Level "Verdict: $($new.Title)."
    } else {
        $script:State.PendingVerdict = $new
    }
    Set-Verdict $script:State.Verdict
}

function Update-Header {
    $c = $script:Shared.Connection
    if (-not $c.Found) { $script:Ui.ConnText.Text = 'No network connection found'; return }
    $kind = if ($c.IsWifi) { 'Wi-Fi' } else { 'Cable (Ethernet)' }
    $script:Ui.ConnText.Text = "$kind  ·  $($c.AdapterName)  ·  router $($c.Gateway)  ·  live: pings every second, game regions every 5 seconds"
}

function Update-Wifi {
    $c = $script:Shared.Connection
    $w = $script:Shared.Wifi
    if (-not $c.IsWifi) { $script:Ui.WifiStrip.Visibility = 'Collapsed'; return }
    $script:Ui.WifiStrip.Visibility = 'Visible'
    if (-not $w) { $script:Ui.WifiText.Text = 'Wi-Fi: reading signal...'; return }
    if ($w.Hidden -or -not $w.Signal) {
        $script:Ui.WifiText.Text = "Wi-Fi details are hidden by Windows. To see signal strength here, allow Location for desktop apps (Settings > Privacy & security > Location). Link speed: $(Format-Speed $c.LinkSpeedBps)"
        return
    }

    # Stability: how much the signal moved over the last 30 seconds
    if (-not $script:State.WifiHistory) { $script:State.WifiHistory = New-Object System.Collections.Generic.List[object] }
    $wh = $script:State.WifiHistory
    if ($script:Shared.WifiTime -ne $script:State.LastWifiTime) {
        $script:State.LastWifiTime = $script:Shared.WifiTime
        $wh.Add([pscustomobject]@{ T = Get-Date; Signal = $w.Signal })
        while ($wh.Count -gt 0 -and $wh[0].T -lt (Get-Date).AddSeconds(-30)) { $wh.RemoveAt(0) }
        $prev = $script:State.LastWifi
        if ($prev -and $prev.Signal -ge 50 -and $w.Signal -lt 50) { Add-Event 'warn' "Wi-Fi signal dropped to $($w.Signal)%." 'wifisignal' 30 }
        if ($prev -and $prev.Band -and $w.Band -and $prev.Band -ne $w.Band) { Add-Event 'info' "Wi-Fi switched from $($prev.Band) to $($w.Band)." }
        $script:State.LastWifi = $w
    }
    $range = ($wh | Measure-Object Signal -Minimum -Maximum)
    $stable = if ($wh.Count -ge 3 -and ($range.Maximum - $range.Minimum) -gt 15) { 'unstable' } else { 'stable' }
    $quality = if ($w.Signal -ge 70) { 'good' } elseif ($w.Signal -ge 50) { 'borderline' } else { 'weak' }

    $text = "Wi-Fi  ·  signal $($w.Signal)% ($quality, $stable)  ·  $($w.Band)  ·  channel $($w.Channel)  ·  $($w.RadioType)  ·  $($w.ReceiveMbps) Mbps link"
    if ($w.Band -match '^2\.4' -and $w.Signal -lt 70) { $text += "`nTip: 2.4 GHz with this signal is a common cause of lag - use 5 GHz, move closer, or use a cable." }
    elseif ($w.Signal -lt 50) { $text += "`nTip: weak signal - move closer to the router or use a cable." }
    $script:Ui.WifiText.Text = $text
    $script:Ui.WifiText.Foreground = if ($quality -eq 'good' -and $stable -eq 'stable') { $script:Colors.Text } else { $script:LevelColors.warn }
}

# ------------------------------------------------------------------
#  Reading the background threads
# ------------------------------------------------------------------

function Receive-Measurements {
    $internetKeys = @($script:Targets.Internet | ForEach-Object { $_.Key })
    $round = $null
    while ($script:Shared.Rounds.TryDequeue([ref]$round)) {
        foreach ($key in $round.Ms.Keys) { Add-Sample $key $round.Time $round.Ms[$key] }
        $found = Get-RoundEvent -Round $round -Normal $script:State.Normal -IsWifi ([bool]$script:Shared.Connection.IsWifi) -InternetKeys $internetKeys
        if ($found) { Add-Event $found.Level $found.Text $found.Type 10 }
    }

    $sample = $null
    while ($script:Shared.RegionSamples.TryDequeue([ref]$sample)) {
        Add-Sample $sample.Key $sample.Time $sample.Ms
        $name = ($script:Series | Where-Object { $_.Key -eq $sample.Key }).Name
        if ($null -eq $sample.Ms) {
            $script:State.RegionFails[$sample.Key] = 1 + [int]$script:State.RegionFails[$sample.Key]
            if ($script:State.RegionFails[$sample.Key] -eq 2) { Add-Event 'warn' "$name isn't answering (2 tests in a row)." "region-$($sample.Key)" 60 }
        } else {
            if ([int]$script:State.RegionFails[$sample.Key] -ge 2) { Add-Event 'info' "$name is answering again." }
            $script:State.RegionFails[$sample.Key] = 0
            $script:State.RegionVia[$sample.Key] = $sample.Via
        }
    }

    $note = $null
    while ($script:Shared.Notes.TryDequeue([ref]$note)) { Add-Event $note.Level $note.Text }

    # Keep 10 minutes of history
    $cutoff = (Get-Date).AddMinutes(-10)
    foreach ($list in $script:State.History.Values) {
        $n = 0
        while ($n -lt $list.Count -and $list[$n].T -lt $cutoff) { $n++ }
        if ($n -gt 0) { $list.RemoveRange(0, $n) }
    }
}

# ------------------------------------------------------------------
#  Tests
# ------------------------------------------------------------------

$script:TestDefinitions = @{
    Details = @{ Name = 'Connection Details'; Command = 'Invoke-ConnectionDetailsTest' }
    Dns     = @{ Name = 'DNS Test';           Command = 'Invoke-DnsTest' }
    Route   = @{ Name = 'Route Check';        Command = 'Invoke-RouteCheck' }
    Load    = @{ Name = 'Lag Under Load';     Command = 'Invoke-LoadTest' }
}

function Set-TestButtons {
    param([bool]$Enabled)
    foreach ($b in 'BtnDetails', 'BtnDns', 'BtnRoute', 'BtnLoad') { $script:Ui[$b].IsEnabled = $Enabled }
}

function Start-Test {
    param([string]$Id)
    if ($script:State.Test) { return }
    $def = $script:TestDefinitions[$Id]
    $plan = Get-PlanMbps
    $arguments = switch ($Id) {
        'Details' { @{ BaselineErrors = $script:State.BaselineErrors; PlanMbps = $plan } }
        'Dns'     { @{ Targets = $script:Targets } }
        'Route'   { @{ Shared = $script:Shared } }
        'Load'    { @{ Shared = $script:Shared; Root = $script:Root; Targets = $script:Targets; PlanMbps = $plan } }
    }

    Set-TestButtons $false
    $script:Ui.ResultsHint.Visibility = 'Collapsed'
    $running = New-Text "$($def.Name) - running..." $script:LevelColors.info 13 'SemiBold' '0,0,0,10'
    $script:Ui.ResultsPanel.Children.Insert(0, $running)

    $span = [pscustomobject]@{ Name = $def.Name; Start = Get-Date; End = $null }
    $script:State.Spans.Add($span)
    $script:State.Test = @{
        Id = $Id; Name = $def.Name; Started = Get-Date; Span = $span; Running = $running
        Job = Start-Background -Root $script:Root -Command $def.Command -Arguments $arguments
    }
    Add-Event 'info' "Started $($def.Name)."
    Set-DoctorBusy $true
}

function Set-DoctorBusy {
    # Tells Krimz's Toolkit (if the page is shown there) that a test is running
    param([bool]$Busy)
    if ($script:State.OnBusy) { try { & $script:State.OnBusy $Busy } catch { } }
}

function Update-Test {
    $t = $script:State.Test
    if (-not $t) { return }
    $elapsed = (Get-Date) - $t.Started
    $t.Running.Text = '{0} - running... {1:m\:ss}' -f $t.Name, $elapsed
    if (-not $t.Job.Handle.IsCompleted) { return }

    $result = $null
    try {
        $output = $t.Job.PowerShell.EndInvoke($t.Job.Handle)
        $result = @($output) | Where-Object { $_ -and $_.PSObject.Properties['Verdict'] } | Select-Object -Last 1
        if (-not $result -and $t.Job.PowerShell.Streams.Error.Count) { throw $t.Job.PowerShell.Streams.Error[0].Exception }
    } catch {
        $result = New-TestResult $t.Name 'info' "The test couldn't finish: $($_.Exception.Message)"
    }
    if (-not $result) { $result = New-TestResult $t.Name 'info' "The test finished without a result." }
    try { $t.Job.PowerShell.Dispose(); $t.Job.Runspace.Dispose() } catch { }

    $t.Span.End = Get-Date
    $script:Ui.ResultsPanel.Children.Remove($t.Running)
    $script:Ui.ResultsPanel.Children.Insert(0, (New-ResultCard $result))
    $script:State.Test = $null
    Set-TestButtons $true
    Set-DoctorBusy $false
    Add-Event $result.Level "$($result.Name): $($result.Verdict)"
}

function New-ResultCard {
    param($Result)
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '0,0,0,14'

    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    [void]$head.Children.Add((New-Dot $script:LevelColors[$Result.Level] 9))
    [void]$head.Children.Add((New-Text $Result.Name.ToUpper() $script:Colors.Muted 11 'SemiBold'))
    [void]$head.Children.Add((New-Text ('  ·  ' + (Get-Date).ToString('HH:mm')) $script:Colors.Faint 11))
    [void]$panel.Children.Add($head)
    [void]$panel.Children.Add((New-Text $Result.Verdict $script:Colors.Text 14 'SemiBold' '0,3,0,0'))

    foreach ($fix in $Result.Fixes) { [void]$panel.Children.Add((New-Text "-  $fix" $script:Colors.Text 12 -Margin '8,3,0,0')) }
    if ($Result.Details.Count) {
        $details = New-Object System.Windows.Controls.TextBox
        $details.Text = ($Result.Details -join "`r`n")
        $details.IsReadOnly = $true
        $details.Background = 'Transparent'
        $details.BorderThickness = 0
        $details.Foreground = $script:Colors.Muted
        $details.FontSize = 12
        $details.Margin = '-2,6,0,0'
        $details.TextWrapping = 'Wrap'
        if ($Result.Name -eq 'Route Check') { $details.FontFamily = 'Cascadia Mono, Consolas'; $details.TextWrapping = 'NoWrap'; $details.HorizontalScrollBarVisibility = 'Auto' }
        [void]$panel.Children.Add($details)
    }
    $panel
}

# ------------------------------------------------------------------
#  Page, monitor and window
# ------------------------------------------------------------------

function Invoke-Tick {
    $script:State.Tick++
    Receive-Measurements
    Update-Stats
    Update-Tiles
    Update-Header
    Update-Wifi
    Update-Graph
    Update-Verdict
    Update-Test
}

function Update-Paused {
    # The monitor measures unless the Pause button stops it
    $script:Shared.Paused = $script:State.UserPaused
}

function Stop-Everything {
    if (-not $script:Shared) { return }   # the monitor never started
    $script:Shared.Stop = $true
    if ($script:Timer) { $script:Timer.Stop() }
    try { if ($script:Shared.TestProcess -and -not $script:Shared.TestProcess.HasExited) { $script:Shared.TestProcess.Kill() } } catch { }
    foreach ($job in $script:State.Jobs) { Stop-Background $job }
    if ($script:State.Test) { Stop-Background $script:State.Test.Job }
}

function New-DoctorPage {
    <#
        Builds the page (ui\Page.xaml) and wires up its buttons. Used by the
        standalone window below and by Krimz's Toolkit (modules\Page.ps1).
        Nothing is measured until Start-Monitor.
    #>
    param([string]$Root, [string]$Version, $Targets, [scriptblock]$OnBusy)

    $script:Root = $Root
    $script:Targets = $Targets
    $script:Series = Get-SeriesList
    $script:State.OnBusy = $OnBusy

    [xml]$xaml = Get-Content (Join-Path $Root 'ui\Page.xaml') -Raw -Encoding UTF8
    $page = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:Ui.Page = $page
    $xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
        $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) { $script:Ui[$name] = $page.FindName($name) }
    }
    $script:Ui.VersionText.Text = "v$Version"
    New-Tiles

    $script:Ui.PauseButton.Add_Click({
        Invoke-UiSafely {
            $script:State.UserPaused = -not $script:State.UserPaused
            Update-Paused
            $script:Ui.PauseButton.Content = if ($script:State.UserPaused) { 'Resume' } else { 'Pause' }
            Add-Event 'info' $(if ($script:State.UserPaused) { 'Live monitor paused.' } else { 'Live monitor resumed.' })
            Update-Verdict
        }
    })
    $script:Ui.BtnDetails.Add_Click({ Invoke-UiSafely { Start-Test 'Details' } })
    $script:Ui.BtnDns.Add_Click({     Invoke-UiSafely { Start-Test 'Dns' } })
    $script:Ui.BtnRoute.Add_Click({   Invoke-UiSafely { Start-Test 'Route' } })
    $script:Ui.BtnLoad.Add_Click({    Invoke-UiSafely { Start-Test 'Load' } })
    $script:Ui.GraphCanvas.Add_SizeChanged({ Invoke-UiSafely { Update-Graph } })
    $page
}

function Start-Monitor {
    # Finds the router and starts the live monitor (once)
    if ($script:Shared) { return }
    $connection = Get-ConnectionInfo
    $script:Shared = New-SharedState $script:Targets $connection
    Update-Paused
    $script:State.Started = Get-Date
    $script:State.BaselineErrors = Get-AdapterErrorCount $connection.InterfaceIndex
    Update-Header

    foreach ($loop in 'Invoke-PingLoop', 'Invoke-RegionLoop', 'Invoke-NetworkLoop') {
        $script:State.Jobs += Start-Background -Root $script:Root -Command $loop -Arguments @{ Shared = $script:Shared }
    }
    if ($connection.Found) {
        Add-Event 'info' "Live monitor started. Router $($connection.Gateway) found."
    } else {
        Add-Event 'bad' 'Live monitor started, but no router was found - is the network connected?'
    }

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:Timer.Add_Tick({ Invoke-UiSafely { Invoke-Tick } })
    $script:Timer.Start()
}

function Show-DoctorWindow {
    # The standalone window: the monitor starts straight away.
    # -NoShow builds and starts everything without opening the window (used for automated checks)
    param([string]$Root, [string]$Version, $Targets, [switch]$NoShow)

    Enable-DpiAwareness
    # The shared look (Theme.xaml) becomes the application's resources. Krimz's Toolkit does this itself.
    [xml]$themeXaml = Get-Content (Join-Path $Root 'ui\Theme.xaml') -Raw -Encoding UTF8
    $app = [System.Windows.Application]::Current
    if (-not $app) { $app = New-Object System.Windows.Application }
    $app.ShutdownMode = 'OnExplicitShutdown'
    $app.Resources = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $themeXaml))

    [xml]$xaml = Get-Content (Join-Path $Root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:Ui.Window = $window
    $window.Content = New-DoctorPage -Root $Root -Version $Version -Targets $Targets

    # Dark title bar to match the window (Windows 10 2004+ / Windows 11)
    $window.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:Ui.Window).Handle
            $on = 1
            $native = Get-NativeMethods
            [void]$native::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)
        } catch { }
    })

    Start-Monitor
    $window.Add_Closed({ Stop-Everything })

    if ($NoShow) { return $window }
    [void]$window.ShowDialog()
}
