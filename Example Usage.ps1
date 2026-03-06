. .\PipeBrowser.ps1

$Browser = Start-CdpPipeBrowser -UserDataDir 'D:\The Testing Folder\Edge\TestUserData'

$FirstTab = $Browser.Targets[0]
Invoke-CdpPageNavigate -Browser $Browser -Url 'https://www.google.com' -CdpPage $FirstTab
Invoke-CdpClickElement -Browser $Browser -Selector 'document.querySelectorAll("[name=q]")[0]' -CdpPage $FirstTab -Click 1
# Check processed messages.
# $Browser.EventTimeline | Select-Object -Property 'id', 'method', 'error', 'sessionId', 'result', 'params' | Format-Table -AutoSize


$NewPage = New-CdpPage -Browser $Browser
Invoke-CdpPageNavigate -Browser $Browser -Url 'https://the-internet.herokuapp.com/inputs' -CdpPage $NewPage
Invoke-CdpClickElement -Browser $Browser -Selector 'document.querySelector("#content input[type=number]")' -Click 1 -CdpPage $NewPage
Invoke-CdpSendKeys -Browser $Browser -Keys '123' -CdpPage $NewPage
Invoke-CdpClickElement -Browser $Browser -Selector 'document.querySelector("#content input[type=number]")' -Click 3 -CdpPage $NewPage
Invoke-CdpSendKeys -Browser $Browser -Keys '321' -CdpPage $NewPage
# $Browser.EventTimeline | Select-Object -Property 'id', 'method', 'error', 'sessionId', 'result', 'params' -Last 10 | Format-Table -AutoSize

# Stop-CdpPipeBrowser -Browser $Browser
