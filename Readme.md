# Powershell Browser Automation

Automate Chrome, Edge, and Firefox through Cdp and BiDi commands through a .net websocket.

The goal is light browser automation without external dependencies.

Only a small subset of commands and respective params are implemented from the Cdp and BiDi specifications. For everything else, <i>there's javascript</i>.

This as an over engineered demo. (If there is a next version, WebSocket.ReceiveAsync would run in its own runspace.)


## ✨ Features
- Interchangeable function calls between browsers.
- Automate the browser without installing external dependencies.

## 📡 Getting Started
1. Edge should have Startup Boost disabled or else a lingering process will prevent usage of some command line args.
2. Provide a User Data folder (The browser will automatically create the folder if it doesn't exist.)


    ### Example
    ``` Powershell
    . '.\Powershell Bidi.ps1'

    $CapabilitiesSplat = @{
        UserDataDir = 'D:\The Testing Folder\Edge\User Data'
        StartupUrl = 'about:blank'
        Headless = $false
        NoFirstRun = $true
    }

    $Capabilities = New-CdpCapabilities @CapabilitiesSplat
    $Session = Start-CdpBrowser -CdpCapabilities $Capabilities -BrowserType Edge

    # The `$Session` object must be passed to each Invoke-Bidi* function.
    # It contains the websocket used to send commands to the browser.
    $null = $Session | Invoke-BiDiNavigate -Url 'https://www.github.com/'
    ```


## ❓ How does it work
- Chrome and Edge connect via Cdp. Firefox by BiDi.

- When a browser is launched with `--remote-debugging-port=0`
    - The browser chooses a free port to use.
    - Cdp: A file named `DevToolsActivePort` created/overwritten in the provided User Data folder.
    - Firefox: A file named `WebDriverBiDiServer.json` is created in the provided Profile folder.
        - These files contain the localhost port for a websocket to connect to.
        - These files are NOT created/overwritten if launched with a port other than 0.

- Control of browers is simply sending json messages according to Cdp and BiDi specifications.

    https://chromedevtools.github.io/devtools-protocol/

    https://w3c.github.io/webdriver-bidi/

- Messages are sent and received round trip via `Invoke-BiDiMessage` or one sided `Send-BiDiMessage` and `Receive-BiDiMessage`

    - One message is sent with an id. One message is received with the same id.
    - Events are received and sent to `$BiDiSession.Events`. Events do not have an id.
    - `BiDiSession.Responses` contains responses from the websocket.
    - Messages are only processed during a function call.

- A `[BiDiSession]` object is piped between each function. This object holds the websocket, responses, events, selected element, tabs, and sent messages (if `$DebugPreference` is set to `'Continue'`).


## 📝 Notes
- Objects are passed by reference by default in powershell functions.

- If the websocket is closed or aborted without removing the BiDi Session, there is no way to reconnect with the session. Therefore all functions will remove the BiDi Session in the end block.

- To prevent the above behavior use the switch `-ContinueSession` with `Start-CdpBrowser` and `Start-FirefoxBrowser` or set `$Session.ReleaseSession = $false` before calling functions.

- `--remote-debugging-pipe` requires fds 3 and 4 to be open. I lack c# knowledge to fill `lpReserved2` with a proper packed struct. Maybe someone can give it a try. https://www.codeproject.com/Tips/5307593/Automate-Chrome-Edge-using-VBA
