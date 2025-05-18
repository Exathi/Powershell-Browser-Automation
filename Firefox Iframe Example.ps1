. '.\Powershell Bidi.ps1'

$DebugPreference = 'Continue'

$CapabilitiesSplat = @{
    ProfileName = 'Test-Automation'
    StartupUrl = [uri]::EscapeUriString("file:///$($PSScriptRoot.Replace('\', '/'))/Sample iframe/Parent.html")
}
$Capabilities = New-FirefoxCapabilities @CapabilitiesSplat
$Session = Start-FirefoxBrowser -FirefoxCapabilities $Capabilities -ContinueSession

$Session | Invoke-BiDiSetActiveFrame -Index -1 | Invoke-BiDiQuerySelectorAll -Selector '[id=iframeLastName]' | Invoke-BidiClickCurrentElement | Invoke-BiDiKeyActions -Value 'iframe'
$Session.Tabs[0].children

# $Session | Close-BiDiBrowser
