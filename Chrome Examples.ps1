#
# If not specified with Invoke-BidiSetActiveTab, the active tab will default to the last active tab, then to the websocket's tab .
. '.\Powershell Bidi.ps1'

$CapabilitiesSplat = @{
    UserDataDir = 'D:\The Testing Folder\Chrome\TestUserData'
    StartupUrl = 'about:blank'
}
$Capabilities = New-CdpCapabilities @CapabilitiesSplat
$Session = Start-CdpBrowser -CdpCapabilities $Capabilities -BrowserType Chrome

# Example navigate and send keys.
$null = $Session | Invoke-BiDiNavigate -Url 'https://www.google.com/' | Invoke-BiDiQuerySelectorAll -Selector '[name=q]' | Invoke-BidiClickCurrentElement | Invoke-BiDiKeyActions -Value 'powershell bidi cdp'

# Example javascript await
# Can check dev tools console for "Waiting x seconds..."
$Script = @'
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function Demo() {
    let seconds = 0
    for (let i = 0; i < 3; i++) {
        console.log(`Waiting ${i} seconds...`);
        await sleep(i * 1000);
        seconds += i;
    }
    var q = document.getElementsByName('q');
    q[0].value = 'powershell bidi javascript awaited';
    return seconds;
}

Demo();
'@
$null = $Session | Invoke-BiDiJavascript -Script $Script -Await
$JavascriptResult = $Session.Responses | Where-Object { $_.id -eq $([int][BiDiMethodId]::ScriptEvaluate) }[-1]
Write-Host ('Awaited {0} seconds' -f $JavascriptResult.result.result.value) -ForegroundColor Magenta

Start-Sleep -Seconds 1

# Example clear text box and send keys with special keys. Cdp does not need to grab the element again because there is always a session. It is compatible with firefox commands.
$null = $Session | Invoke-BiDiQuerySelectorAll -Selector '[name=q]' | Invoke-BidiClickCurrentElement -ClickCount 3 | Invoke-BiDiKeyActions -Value "powershell bidi cdp send keys$([BiDiKeyHelper]::Backspace)$([BiDiKeyHelper]::Backspace)$([BiDiKeyHelper]::Backspace)"

# $Session | Close-BiDiBrowser
