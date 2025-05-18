. '.\Powershell Bidi.ps1'

$DebugPreference = 'Continue'

$CapabilitiesSplat = @{
    UserDataDir = 'D:\The Testing Folder\Edge\TestUserData2'
    StartupUrl = [uri]::EscapeUriString("file:///$($PSScriptRoot.Replace('\', '/'))/Sample iframe/Parent.html")
}
$Capabilities = New-CdpCapabilities @CapabilitiesSplat
$Session = Start-CdpBrowser -CdpCapabilities $Capabilities -BrowserType Edge -ContinueSession

$Session | Invoke-BiDiSetActiveFrame -Index -1 | Invoke-BiDiQuerySelectorAll -Selector '[id=iframeLastName]' | Invoke-BidiClickCurrentElement | Invoke-BiDiKeyActions -Value 'iframe'
$Session.CdpFrameNodes | Format-Table

# $Session | Close-BiDiBrowser
