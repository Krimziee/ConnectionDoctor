<#
    The Connection Doctor tab in Krimz's Toolkit. The toolkit loads this file
    in its own private module and calls the functions below. The page is the
    same one the standalone window shows (ui\Page.xaml, built by Ui.ps1).

    The live monitor only measures while this tab is selected: it starts the
    first time the tab is opened, pauses when another tab is selected and
    resumes when this one is selected again. A running test carries on in the
    background (the tab shows the working dot). Everything stops when the
    toolkit closes. Read-only, like the standalone tool.
#>

foreach ($module in 'Network', 'Monitor', 'Judge', 'Tests', 'Ui') {
    . (Join-Path $PSScriptRoot "$module.ps1")
}

function New-ToolPage {
    param([string]$Root, [hashtable]$Shell)
    # The version is the one in ConnectionDoctor.ps1 (read from the file, nothing is run)
    $version = if ((Get-Content (Join-Path $Root 'ConnectionDoctor.ps1') -Raw) -match "\`$script:Version = '([^']+)'") { $Matches[1] }
    $targets = Import-PowerShellDataFile (Join-Path $Root 'targets.psd1')
    New-DoctorPage -Root $Root -Version $version -Targets $targets -OnBusy $Shell.SetBusy
}

function Enter-ToolPage { Resume-Monitor }

function Exit-ToolPage { Suspend-Monitor }

function Close-ToolPage { Stop-Everything }
