<#
    The Connection Doctor tab in Krimz's Toolkit. The toolkit loads this file
    in its own private module and calls the functions below. The page is the
    same one the standalone window shows (ui\Page.xaml, built by Ui.ps1).

    The live monitor starts when the toolkit opens and keeps measuring
    whichever tab is selected. A running test carries on in the background
    too (the tab shows the working dot). Everything stops when the toolkit
    closes. Read-only, like the standalone tool.
#>

foreach ($module in 'Network', 'Monitor', 'Judge', 'Tests', 'Ui') {
    . (Join-Path $PSScriptRoot "$module.ps1")
}

function Start-ToolPrefetch {
    # Finding the router and adapter takes a second or two (the first network query is slow), so the
    # toolkit starts it in the background while its window opens. New-ToolPage picks the result up.
    param([string]$Root)
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($file)
        . $file
        $connection = Get-ConnectionInfo
        [pscustomobject]@{ Connection = $connection; BaselineErrors = (Get-AdapterErrorCount $connection.InterfaceIndex) }
    }).AddArgument((Join-Path $Root 'modules\Network.ps1'))
    [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function New-ToolPage {
    param([string]$Root, [hashtable]$Shell)
    # The version is the one in ConnectionDoctor.ps1 (read from the file, nothing is run)
    $version = if ((Get-Content (Join-Path $Root 'ConnectionDoctor.ps1') -Raw) -match "\`$script:Version = '([^']+)'") { $Matches[1] }
    $targets = Import-PowerShellDataFile (Join-Path $Root 'targets.psd1')
    $page = New-DoctorPage -Root $Root -Version $version -Targets $targets -OnBusy $Shell.SetBusy

    $found = $null
    if ($Shell.Prefetch) {
        try { $found = @($Shell.Prefetch.PowerShell.EndInvoke($Shell.Prefetch.Handle))[0] } catch { $found = $null }
        try { $Shell.Prefetch.PowerShell.Dispose() } catch { }
        $Shell.Prefetch = $null
    }
    if ($found -and $found.Connection) { Start-Monitor -Connection $found.Connection -BaselineErrors $found.BaselineErrors }
    else { Start-Monitor }
    $page
}

function Close-ToolPage { Stop-Everything }
