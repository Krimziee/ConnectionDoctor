#Requires -Version 5.1
<#
    Connection Doctor
    Watches your connection live and explains in plain words where lag comes
    from: your Wi-Fi or cable, your ISP, or the route to the game servers.

    THIS TOOL MAKES NO CHANGES TO THE PC. It only measures: pings, short TCP
    connections, DNS lookups, a route trace, and (only when you click
    Lag Under Load) a test download that is thrown away. Fixes are shown as
    text for the user to do themselves. Anyone changing this script must keep it that way.

    No admin rights are needed.
#>

$ErrorActionPreference = 'Stop'
$script:Version = '0.1.0'

try {
    foreach ($module in 'Network', 'Monitor', 'Judge', 'Tests', 'Ui') {
        . (Join-Path $PSScriptRoot "modules\$module.ps1")
    }
    $targets = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'targets.psd1')
    Show-DoctorWindow -Root $PSScriptRoot -Version $script:Version -Targets $targets
} catch {
    # The launcher hides the console, so errors must be shown in a message box
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("Connection Doctor could not start:`n$($_.Exception.Message)", 'Connection Doctor', 'OK', 'Error') | Out-Null
}
