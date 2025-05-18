# Automate a browser without external binaries
# Only supports one session for firefox.

# References
# https://chromedevtools.github.io/devtools-protocol/
# https://w3c.github.io/webdriver-bidi/

# https://github.com/SeleniumHQ/selenium/issues/13762
# There is no way to reconnect to a session at this time.
# If the websocket aborts, there will be a session left hanging and the user will be met with a maximum number of sessions allowed error on next session.new
# Therefore, the session will be cleaned up on each function's end block so you are able to pipe each function before the session is closed.
# Cdp does not have this issue.

# Note - ReceiveAsync and SendAsync can run in parallel. They just can't be called multiple times while running.

enum BiDiMethodId {
    # Session
    SessionStatus
    SessionNew
    SessionEnd

    # Browser
    BrowserClose

    # BrowsingContext
    BrowsingContextGetTree
    BrowsingContextLocateNodes
    BrowsingContextNavigate
    BrowsingContextPrint

    # Script
    ScriptEvaluate

    # Input
    InputPerformActions
    InputReleaseActions
}

enum CdpMethodId {
    # Cdp equivalents
    TargetGetTargets = [BiDiMethodId]::BrowsingContextGetTree + 9000
    TargetAttachToTarget = [BiDiMethodId]::BrowsingContextGetTree + 9100
    DomGetDocument = [BiDiMethodId]::BrowsingContextLocateNodes + 9000
    DomQuerySelectorAll = [BiDiMethodId]::BrowsingContextLocateNodes + 9100
    DomGetBoxModel = [BiDiMethodId]::BrowsingContextLocateNodes + 9200
    PageEnable = [BiDiMethodId]::BrowsingContextNavigate + 9000
    PageDisable = [BiDiMethodId]::BrowsingContextNavigate + 9100
    InputDispatchMouseEvent = [BiDiMethodId]::InputPerformActions + 9000
    InputDispatchKeyEvent = [BiDiMethodId]::InputPerformActions + 9100
    InputDispatchKeyEventUp = [BiDiMethodId]::InputPerformActions + 9200
}

class BiDiMethod {
    # Maybe todo add static method to generate the json object instead of in the begin blocks of each function.
    # Session
    static [string]$SessionStatus = 'session.status'
    static [string]$SessionNew = 'session.new'
    static [string]$SessionEnd = 'session.end'

    # Browser
    static [string]$BrowserClose = 'browser.close'

    # BrowsingContext
    static [string]$BrowsingContextGetTree = 'browsingContext.getTree'
    static [string]$BrowsingContextLocateNodes = 'browsingContext.locateNodes'
    static [string]$BrowsingContextNavigate = 'browsingContext.navigate'
    static [string]$BrowsingContextPrint = 'browsingContext.print'

    # Script
    static [string]$ScriptEvaluate = 'script.evaluate'

    # Input
    static [string]$InputPerformActions = 'input.performActions'
    static [string]$InputReleaseActions = 'input.releaseActions'
}

class BiDiKeyHelper {
    # https://w3c.github.io/webdriver/#keyboard-actions
    static [char]$Backspace = 0xE003
    static [char]$Enter = 0xE006
    static [int]CharToWindowsVirtualKeyCode([char]$Char) {
        $Code = switch ([int]$Char) {
            ([int][BiDiKeyHelper]::Backspace) { 0x08 }
            ([int][BiDiKeyHelper]::Enter) { 0x0D }
            Default { 0 }
        }
        return $Code
    }
}

class BiDiSession {
    BiDiSession($WebSocket) {
        $this.WebSocket = $WebSocket
    }

    [void]AddResponse($RawJsonResponse) {
        try {
            $JsonResponse = ConvertFrom-Json -InputObject $RawJsonResponse
        } catch {
            $JsonResponse = @{
                id = -1
                result = "MALFORMED RESPONSE: $RawJsonResponse"
            }
        }

        # The below are roughly Bidi and Cdp equivalents that share variable names.
        $ResponseId = $JsonResponse.id
        switch ($ResponseId) {
            $null { $this.Events.Add($JsonResponse) }

            # Shared method id between Bidi and Cdp.
            # Do not keep data in response because it can be a large pdf.
            $([int][BiDiMethodId]::BrowsingContextPrint) {
                if ($null -ne $JsonResponse.result.data) {
                    $this.PrintData.Enqueue($JsonResponse.result.data)
                    $JsonResponse.result.data = 'Data is not kept in memory. Sent to queue $this.PrintData.'
                }
                $this.Responses.Add($JsonResponse)
            }

            $([int][BiDiMethodId]::BrowsingContextLocateNodes) {
                $this.Responses.Add($JsonResponse)
                $this.ElementList = $JsonResponse.result.nodes
                $this.CurrentElement = $JsonResponse.result.nodes[0].sharedId
            }

            $([int][CdpMethodId]::DomQuerySelectorAll) {
                $this.Responses.Add($JsonResponse)
                $this.ElementList = $JsonResponse.result.nodeIds
                $this.CurrentElement = $JsonResponse.result.nodeIds[0]
            }

            $([int][BiDiMethodId]::BrowsingContextGetTree) {
                $this.Responses.Add($JsonResponse)
                $Contexts = $JsonResponse.result.contexts
                if ($null -eq $Contexts.Count) { $Contexts = @($Contexts) }

                $StaleTargets = $this.Tabs | ForEach-Object {
                    if ($_.context -notin $Contexts.context) { $_ }
                }

                $StaleTargets | ForEach-Object {
                    # Write-Host "removing stale target: $($_.context)" -ForegroundColor DarkRed
                    $null = $this.Tabs.Remove($_)
                }

                $Contexts | ForEach-Object {
                    if ($_.context -notin $this.Tabs.context) {
                        $this.Tabs.Add($_)
                    }
                }
            }

            $([int][CdpMethodId]::TargetGetTargets) {
                $this.Responses.Add($JsonResponse)
                $Contexts = $JsonResponse.result.targetInfos | Where-Object { $_.type -eq 'page' }
                if ($null -eq $Contexts.Count) { $Contexts = @($Contexts) }

                $StaleTargets = $this.Tabs | ForEach-Object {
                    if ($_.targetId -notin $Contexts.targetId) { $_ }
                }

                $StaleTargets | ForEach-Object {
                    # Write-Host "removing stale target: $($_.targetId)" -ForegroundColor DarkRed
                    $null = $this.Tabs.Remove($_)
                }

                $Contexts | ForEach-Object {
                    if ($_.targetId -notin $this.Tabs.targetId) {
                        $this.Tabs.Add($_)
                    }
                }
            }

            $([int][BiDiMethodId]::SessionNew) {
                $this.Responses.Add($JsonResponse)
                $this.SessionId = $JsonResponse.result.sessionId
            }

            $([int][CdpMethodId]::TargetAttachToTarget) {
                $this.Responses.Add($JsonResponse)
                $this.SessionId = $JsonResponse.result.sessionId
                # While we can attach to each page's respective websocket, we would have to handle multiple websockets...
                # Or close the current connection and attach to the new one.
                # Also to consider - save the sessionid with the attached target rather than reattaching and creating a new sessionid.
            }

            Default { $this.Responses.Add($JsonResponse) }
        }

        # Firefox eventually aborts the websocket if the Message returns an error.
        # This leaves the session hanging.
        # We cannot reconnect with the session.
        # We have to end the session if or before the websocket aborts.
        # Cdp does not have this issue or return $JsonResponse.type.
        # jar:file:///C:/Program%20Files/Mozilla%20Firefox/omni.ja!/chrome/remote/content/webdriver-bidi/NewSessionHandler.sys.mjs
        # related https://bugzilla.mozilla.org/show_bug.cgi?id=1838269
        if ($JsonResponse.type -eq 'error') {
            $null = Remove-BiDiSession -BiDiSession $this
            Write-Warning 'BiDiSession: Session removed due to bidi response error. Check Responses for details.'
            Write-Warning $RawJsonResponse
        }
    }

    hidden [void]SetActiveTab([int]$Index) {
        $ContextName = if ($this.IsCdp()) { 'targetId' } else { 'context' }
        $this.BrowserContext = $this.Tabs[$Index].$ContextName
    }

    hidden [void]SetActiveTab([string]$Url) {
        $ContextName = if ($this.IsCdp()) { 'targetId' } else { 'context' }
        $this.BrowserContext = (Where-Object -InputObject $this.Tabs -FilterScript { $_.url -eq $Url })[0].$ContextName
    }

    hidden [void]SetActiveIframe([int]$Index) {
        # $ContextName = if ($this.IsCdp()) { 'targetId' } else { 'context' }
        $this.BrowserContext = (Where-Object -InputObject $this.Tabs -FilterScript { $_.context -eq $this.BrowserContext })[0].Children[$Index].Context
    }

    hidden [object]SavePdf([string]$FullName) {
        try {
            $Data = $this.PrintData.Dequeue()
            $Bytes = [Convert]::FromBase64String($Data)
            if (!$FullName.EndsWith('.pdf')) { $FullName = "$($FullName.pdf)" }
            [System.IO.File]::WriteAllBytes($FullName, $Bytes)
        } catch {
            Write-Error $Error[0]
            return $null
        }
        return $FullName
    }

    [bool]IsCdp() {
        return $this.WebSocketUrl.IndexOf('devtools') -gt 0
    }

    [string]$WebSocketUrl
    [System.Net.WebSockets.ClientWebSocket]$WebSocket
    # [System.Net.WebSockets.ClientWebSocket]$CdpBrowserWebSocket # Unused
    [System.Collections.Generic.List[object]]$Messages = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[object]]$Responses = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[object]]$Events = [System.Collections.Generic.List[object]]::new()
    [string]$SessionId # one session for firefox (unused). One session per Cdp tab. (used) If empty for cdp, will default to the websocket's tab.
    [string]$BrowserContext # Firefox's Cdp sessionId equivalent (used). TargetId is stored here but sessionId is used for Cdp commands. (unused)
    [System.Collections.Generic.List[object]]$Tabs = [System.Collections.Generic.List[object]]::new()
    [bool]$ReleaseSession = $true # enables removing session at the end of each Invoke-BiDi* function
    [string[]]$ElementList
    [string]$CurrentElement
    [int]$IframeContextElement
    [object]$CdpFrameNodes
    [System.Collections.Generic.Queue[object]]$PrintData = [System.Collections.Generic.Queue[object]]::new()
}

function New-BiDiWebSocket {
    <#
        .SYNOPSIS
        Creates a new BidiSession given a WebSocketUrl or
        attempts to reconnect to the $BidiSession.WebSocketUrl
    #>
    [CmdletBinding(DefaultParameterSetName = 'NoBiDiSession')]
    [OutputType([BiDiSession])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'BiDiSession')]
        [BiDiSession]$BiDiSession,

        [Parameter(ParameterSetName = 'NoBiDiSession')]
        [string]$WebSocketUrl #= 'ws://127.0.0.1:9222/session'
    )

    process {
        $WebSocket = [System.Net.WebSockets.ClientWebSocket]::new()

        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
            if ($BiDiSession.WebSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                Write-Verbose 'WebSocket is still open. Did not create a new WebSocket'
                return $BiDiSession
            }

            # If we're passing a BiDiSession to this then we assume the websocket needs to reconnect and is not open.
            $BiDiSession.WebSocket.Dispose()
            $BiDiSession.WebSocket = $WebSocket

            if ($null -eq $BiDiSession.WebSocketUrl) {
                if ($WebSocketUrl.Length -eq 0) { throw 'Provide a WebSocketUrl' }
                $BiDiSession.WebSocketUrl = $WebSocketUrl
            }

            # Reconnect to a cdp websocket if current one does not exist.
            if ($BiDiSession.WebSocketUrl -and $BiDiSession.IsCdp()) {
                $regex = $BiDiSession.WebSocketUrl | Select-String -Pattern '(?in)(?:ws://)(?<websocketurl>localhost:\d+|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+)'
                $BaseLocalHost = $regex.Matches[0].Groups['websocketurl'].Value
                $AvailableConnections = Invoke-RestMethod -Uri "$($BaseLocalHost)/json"
                if ($BiDiSession.WebSocketUrl -notin $AvailableConnections.webSocketDebuggerUrl) {
                    $BiDiSession.WebSocketUrl = ($AvailableConnections | Where-Object { ($_.type -eq 'page') })[0].webSocketDebuggerUrl
                    Write-Warning "Previous Cdp websocket not found.
                    Attempting to attach: $($BiDiSession.WebSocketUrl)
                    targetId: $($BiDiSession.targetId)
                    url: $($BiDiSession.url)"
                    $BiDiSession.SessionId = $null
                }
            }

            $Task = $BiDiSession.WebSocket.ConnectAsync($BiDiSession.WebSocketUrl, [System.Threading.CancellationToken]::None)
        } else {
            $BiDiSession = [BiDiSession]::new($WebSocket)
            $Task = $BiDiSession.WebSocket.ConnectAsync($WebSocketUrl, [System.Threading.CancellationToken]::None)
        }

        if ($Task.IsFaulted -or !$Task) {
            throw 'Failed to connect to WebSocket'
        }

        $null = $Task.GetAwaiter().GetResult()
        if ($BiDiSession.WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw 'Failed to connect to WebSocket. WebSocket is not open.'
        }

        $BiDiSession
    }
}

function New-BiDiSession {
    <#
        .SYNOPSIS
        Creates a new bidi session and sets the default tab.

        Cdp does not need to set a default tab since the webocket is the default tab unless sessionId is specified.

        .PARAMETER ContinueSession
        This skips removing the BiDi session in the end block of each function.

        .PARAMETER IgnoreTab
        This skips setting the active tab.
    #>
    [CmdletBinding(DefaultParameterSetName = 'NoBiDiSession')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'BiDiSession')]
        [BiDiSession]$BiDiSession,

        [switch]$ContinueSession,

        [switch]$IgnoreTab
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::SessionNew
            method = [BiDiMethod]::SessionNew
            params = @{
                capabilities = @{
                    webDriverUrl = $true # not required by launching firefox with remote debugging port. Required for chrome/edge launched by webdrivers.
                }
            }
        } | ConvertTo-Json -Compress
    }

    process {
        # Do not overwrite session. Session must be removed first.
        if ($BiDiSession.SessionId.Length -gt 0) { return } # $BiDiSession }

        if ($BiDiSession.IsCdp()) {
            # if we're calling a new session for some reason, we don't want to overwrite the active tab.
            # $null = Invoke-BiDiSetActiveTab -BiDiSession $BiDiSession
            return # $BiDiSession
        } else {
            $null = New-BiDiWebSocket -BiDiSession $BiDiSession
        }

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $BidiMessage
        if (!$IgnoreTab -and $BiDiSession.BrowserContext.Length -eq 0) {
            $BiDiSession.ReleaseSession = $false # set to false so Invoke-BiDiSetActiveTab doesn't release session at the end block.
            $null = Invoke-BiDiSetActiveTab -BiDiSession $BiDiSession
        }

        $BiDiSession.ReleaseSession = !$ContinueSession
    }
}

function Remove-BiDiSession {
    <#
        .SYNOPSIS
        Ends the BiDi session.
        It is important to end the session for firefox so we don't run into maximum number of sessions error as only one BiDi session is supported by firefox.
        There is no way to reconnect to a session.

        If we remove a session, we don't expect it to continue so no BidiSession is piped out.
        Tabs could still be unchanged so we keep it in the BiDiSession object.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::SessionEnd
            method = [BiDiMethod]::SessionEnd
            params = @{}
        } | ConvertTo-Json -Compress
    }

    process {
        if ($BiDiSession.IsCdp()) {
            $BiDiSession.SessionId = $null
            # We don't have to get rid of the elements since the cdp side websocket never closes and remembers these elements.
            # $BiDiSession.ElementList = $null
            # $BiDiSession.CurrentElement = $null
            return # $BiDiSession
        }

        # Ending session triggers socket closure.
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $BidiMessage
        $null = $BiDiSession.WebSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'NormalClosure', [System.Threading.CancellationToken]::None)
        while ($BiDiSession.WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Closed -and $BiDiSession.WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Aborted) {
            Start-Sleep -Seconds 1 # Wait until the WebSocket is actually closed otherwise functions in the downstream might run before the socket is closed.
        }
        $BiDiSession.SessionId = $null
        $BiDiSession.CurrentElement = $null
        $BiDiSession.ElementList = $null
    }
}

function Close-BiDiBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::BrowserClose
            method = [BiDiMethod]::BrowserClose
            params = @{}
        } | ConvertTo-Json -Compress

        $CdpMessage = @{
            id = [BiDiMethodId]::BrowserClose
            method = 'Browser.close'
            params = @{}
        } | ConvertTo-Json -Compress
    }

    process {
        $Message = if ($BiDiSession.IsCdp()) {
            $CdpMessage
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession
            $BidiMessage
        }
        if ($BiDiSession.WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { Write-Warning 'WebSocket not open. Did not close browser or reset $BiDiSession' ; return $BiDiSession }
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $null = Remove-BiDiSession -BiDiSession $BiDiSession

        $null = $BiDiSession.WebSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'NormalClosure', [System.Threading.CancellationToken]::None)

        $BiDiSession.BrowserContext = $null
        $BiDiSession.SessionId = $null
        $BiDiSession.Tabs.Clear() = $null
        $BiDiSession.WebSocketUrl = $null
        $BiDiSession.ElementList = $null
        $BiDiSession.CurrentElement = $null
    }

    end {
        # If the browser is closed, the session should end in the process block.
    }
}

function Invoke-BiDiSetActiveTab {
    # https://bugzilla.mozilla.org/show_bug.cgi?id=1876240
    # unloaded tabs will throw error
    <#
        .SYNOPSIS
        Sets the active tab to Cdp: SessionId
        Sets the active tab to Firefox: BrowserContext

        .PARAMETER Index
        Newest tabs are added to the end of the list.

        Note
        Firefox websocket response - newest tab is always index -1
        Cdp websocket response - last activated tab is index 0.

        .PARAMETER Url
        Sets tab by the first fully matching url.

        .PARAMETER Refresh
        Does not set active tab and just refreshes the Tab list.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByIndex')]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(ParameterSetName = 'ByIndex')]
        [int]$Index = -1,

        [Parameter(ParameterSetName = 'ByUrl')]
        [string]$Url,

        [switch]$Refresh
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::BrowsingContextGetTree
            method = [BiDiMethod]::BrowsingContextGetTree
            params = @{}
        } | ConvertTo-Json -Compress

        $CdpMessage = @{
            id = [CdpMethodId]::TargetGetTargets
            method = 'Target.getTargets'
            params = @{}
        } | ConvertTo-Json -Compress

        # Cdp will have a default tab so there's techically no reason to set this
        $CdpMessage2 = @{
            id = [CdpMethodId]::TargetAttachToTarget
            method = 'Target.attachToTarget'
            params = @{
                targetId = $null
                flatten = $true
            }
        }
    }

    process {
        $Message = if ($BiDiSession.IsCdp()) {
            $CdpMessage
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession -IgnoreTab
            $BidiMessage
        }

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message

        if ($Refresh) { return $BiDiSession }

        if ($PSCmdlet.ParameterSetName -eq 'ByUrl') {
            $BiDiSession.SetActiveTab($Url)
        } else {
            $BiDiSession.SetActiveTab($Index)
        }

        if ($BiDiSession.IsCdp()) {
            # attachToTarget creates a new sessionId everytime.
            # todo maybe keep a track of targetId + sessionId and reuse that sessionId.
            $CdpMessage2.params.targetId = $BiDiSession.BrowserContext
            $CdpMessage = $CdpMessage2 | ConvertTo-Json -Compress
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage
        }

        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiSetActiveFrame {
    # https://bugzilla.mozilla.org/show_bug.cgi?id=1876240
    # unloaded tabs will throw error
    <#
        .SYNOPSIS
        Sets active iframe
        Cdp: Iframe is an element.
        Firefox: Iframe is a brower context.

        .PARAMETER Index
        The index of the iframe's DOM if there are multiple DOM
        Defaults to the last found DOM.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByIndex')]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(ParameterSetName = 'ByIndex')]
        [int]$Index = -1

        # [Parameter(ParameterSetName = 'ByUrl')]
        # [string]$Url
    )

    begin {
        $CdpMessage = @{
            id = [CdpMethodId]::DomGetDocument
            method = 'DOM.getDocument'
            params = @{
                depth = -1
                pierce = $true
            }
        }

        function FlattenJson ($json, $iframeDocumentId) {
            [pscustomobject]@{
                id = $json.nodeId
                name = $json.nodeName
                parentId = $json.parentId
                iframeDocumentId = $iframeDocumentId
                documentURL = $json.documentURL
            }
            # Traverse the children before a new iframe
            if ($json.children) {
                $json.children | ForEach-Object { FlattenJson $_ $iframeDocumentId }
            }
            if ($json.contentDocument) {
                $iframeDocumentId = $json.contentDocument.nodeId
                $json.contentDocument | ForEach-Object { FlattenJson $_ $iframeDocumentId }
            }
        }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
            $CdpMessage = $CdpMessage | ConvertTo-Json -Compress
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage

            $DocumentNode = $BiDiSession.Responses[-1].result.root
            $Nodes = FlattenJson $DocumentNode $null
            $BiDiSession.CdpFrameNodes = $Nodes
            $BidiSession.IframeContextElement = ($Nodes | Where-Object { $_.name -eq '#document' })[$Index].id

            return $BiDiSession
        }

        $null = New-BiDiSession -BiDiSession $BiDiSession

        $BiDiSession.BrowserContext = ($BiDiSession.Tabs | Where-Object { $_.context -eq $BiDiSession.BrowserContext })[0].children[$Index].context
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiNavigate {
    <#
        .SYNOPSIS
        Navigates to page.
        If Cdp, will automatically wait for event to finish loading by page events.
        Else relies on BiDi $ReadinessState

        # To consider for Cdp: measure html length to ensure page loaded.
        https://stackoverflow.com/a/61304202/16716929

        .PARAMETER ReadinessState
        Only valid for BiDi. Not used for Cdp.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory)]
        [string]$Url,

        [ValidateSet('none', 'interactive', 'complete')]
        [string]$ReadinessState = 'complete'
    )

    begin {
        if ($Url.StartsWith('about:') -or $Url.StartsWith('chrome://') -or $Url.StartsWith('edge://') -or $Url.StartsWith('file:///')) {
            $HttpsUrl = $Url
        } else {
            $Builder = [System.UriBuilder]::new($Url)
            $Builder.Scheme = [uri]::UriSchemeHttps
            $Builder.port = -1
            $HttpsUrl = $builder.Uri
        }

        $BidiMessage = @{
            id = [BiDiMethodId]::BrowsingContextNavigate
            method = [BiDiMethod]::BrowsingContextNavigate
            params = @{
                context = $null #$BiDiSession.BrowserContext
                url = $HttpsUrl
                wait = $ReadinessState
            }
        }

        $CdpMessage = @{
            id = [BiDiMethodId]::BrowsingContextNavigate
            method = 'Page.navigate'
            params = @{
                url = $HttpsUrl
            }
        }

        $CdpMessagePageEnable = @{
            id = [CdpMethodId]::PageEnable
            method = 'Page.enable'
        } | ConvertTo-Json -Compress

        $CdpMessagePageDisable = @{
            id = [CdpMethodId]::PageDisable
            method = 'Page.disable'
        } | ConvertTo-Json -Compress
    }

    process {
        if ($BiDiSession.IsCdp()) {
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessagePageEnable
            if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
            $Message = $CdpMessage | ConvertTo-Json -Compress
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession
            $Message = $BidiMessage
            $Message.params.context = $BiDiSession.BrowserContext
            $Message = $Message | ConvertTo-Json -Compress
        }

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message

        if ($BiDiSession.IsCdp()) {
            # Start stupid workaround to let key/input actions work while cdp browser is minimized or behind a maximized app.
            # Sending the navigation message again somehow allows key/input actions to perform afterwards while minimized or behind a maximized app.
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
            # End stupid workaround.

            if ($null -ne $JsonResponse.error.message) {
                Write-Warning 'Did not navigate. The tab was likely closed. Please set another active tab.'
                Write-Warning "$($JsonResponse.error.message)"
            } else {
                $null = Receive-BiDiMessage -BiDiSession $BiDiSession -WaitForEvent Page.frameStoppedLoading
            }
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessagePageDisable
        }

        $BiDiSession.IframeContextElement = $null
        $BiDiSession.CdpFrameNodes = $null
        $BiDiSession.CurrentElement = $null
        $BiDiSession.ElementList = $null
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiJavascript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory)]
        [string]$Script,

        [switch]$Await
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::ScriptEvaluate
            method = [BiDiMethod]::ScriptEvaluate
            params = @{
                expression = $Script
                target = @{
                    # context or realm
                    context = $null # $BiDiSession.BrowserContext
                    # realm = 'todo'
                }
                awaitPromise = [bool]$Await # Converts to this if not cast to bool or called by .IsPresent - "IsPresent":  true
                # resultOwnership
                # serializationOptions
                # userActivation
            }
        }

        $CdpMessage = @{
            id = [BiDiMethodId]::ScriptEvaluate
            method = 'Runtime.evaluate'
            params = @{
                expression = $Script
                awaitPromise = [bool]$Await
            }
        }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
            $Message = $CdpMessage | ConvertTo-Json -Compress
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession
            $Message = $BidiMessage
            $Message.params.target.context = $BiDiSession.BrowserContext
            $Message = $Message | ConvertTo-Json -Compress
        }

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiWaitForPage {
    <#
        .SYNOPSIS
        Checks for the html length to stop changing to consider page loaded with javascript.
        Shouldn't be necessary for firefox.

        Adpated from https://stackoverflow.com/a/61304202/16716929
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession
    )

    begin {
        $Script = @'
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function WaitForPage() {
	let timeout = 30000
	const checkDurationMsecs = 1000;
	const maxChecks = timeout / checkDurationMsecs;
	let lastHTMLSize = 0;
	let checkCounts = 1;
	let countStableSizeIterations = 0;
	const minStableSizeIterations = 3;

	while(checkCounts++ <= maxChecks){
		let currentHTMLSize = document.body.innerHTML.length;
		let bodyHTMLSize = document.body.innerHTML.length;
		//console.log('last: ', lastHTMLSize, ' <> curr: ', currentHTMLSize, " body html size: ", bodyHTMLSize);
		if(lastHTMLSize != 0 && currentHTMLSize == lastHTMLSize)
		    countStableSizeIterations++;
		else
		    countStableSizeIterations = 0; //reset the counter

		if(countStableSizeIterations >= minStableSizeIterations) {
		    //console.log("Page rendered fully..");
		    break;
		}
		lastHTMLSize = currentHTMLSize;
		await sleep(1000);
	}
}

WaitForPage()
'@
        $BidiMessage = @{
            id = [BiDiMethodId]::ScriptEvaluate
            method = [BiDiMethod]::ScriptEvaluate
            params = @{
                expression = $Script
                target = @{
                    context = $null # $BiDiSession.BrowserContext
                }
                awaitPromise = $true
            }
        }

        $CdpMessage = @{
            id = [BiDiMethodId]::ScriptEvaluate
            method = 'Runtime.evaluate'
            params = @{
                expression = $Script
                awaitPromise = $true
            }
        }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
            $Message = $CdpMessage | ConvertTo-Json -Compress
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession
            $Message = $BidiMessage
            $Message.params.target.context = $BiDiSession.BrowserContext
            $Message = $Message | ConvertTo-Json -Compress
        }

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiPrint {
    <#
        .SYNOPSIS
        Prints page to pdf

        .PARAMETER PdfFullName
        The fullpath to output the pdf.

        .PARAMETER Background
        This includes the page background if present.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -Path $_ -IsValid -PathType Leaf })]
        [string]$PdfFullName,

        [switch]$Background
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::BrowsingContextPrint
            method = [BiDiMethod]::BrowsingContextPrint
            params = @{
                context = $null # $BiDiSession.BrowserContext
                background = [bool]$Background
            }
        }

        $CdpMessage = @{
            id = [BiDiMethodId]::BrowsingContextPrint
            method = 'Page.printToPDF'
            params = @{
                printBackground = [bool]$Background
            }
        }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
            $Message = $CdpMessage | ConvertTo-Json -Compress
        } else {
            $null = New-BiDiSession -BiDiSession $BiDiSession
            $Message = $BidiMessage
            $Message.params.context = $BiDiSession.BrowserContext
            $Message = $Message | ConvertTo-Json -Compress
        }

        # 2^20 bytes // 1Mb Buffer for pdfs
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message -BufferSize 1048576
        $null = $BiDiSession.SavePdf($PdfFullName)
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiQuerySelectorAll {
    <#
        .SYNOPSIS
        This locates a dom element number and sets the first result as the current element.
        DOM.getDocument is called everytime incase there is javascript that adds to the document.
        Prioritizes IframeContextElement over BrowserContext/parent dom.

        .PARAMETER Selector
        Takes querySelectorAll syntax
        .EXAMPLE
        'div > div'
        .EXAMPLE
        '[name=q]'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory)]
        [string]$Selector,

        [int]$FromIframeNode
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::BrowsingContextLocateNodes
            method = [BiDiMethod]::BrowsingContextLocateNodes
            params = @{
                context = $null # $BiDiSession.BrowserContext # no pipeline in begin block
                locator = @{
                    type = 'css'
                    value = $Selector
                }
            }
        }

        $CdpMessage = @{
            id = [CdpMethodId]::DomGetDocument
            method = 'DOM.getDocument'
            params = @{
                depth = 0 # We don't want to pull everything if we just want the document node id to use querySelectorAll
                pierce = $false
            }
        }

        $CdpMessage2 = @{
            id = [CdpMethodId]::DomQuerySelectorAll
            method = 'DOM.querySelectorAll'
            params = @{
                nodeId = $null
                selector = $Selector
            }
        }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            if ($BidiSession.IframeContextElement) {
                $DocumentNodeId = $BidiSession.IframeContextElement
            } else {
                if ($BidiSession.SessionId) { $CdpMessage.sessionId = $BidiSession.SessionId }
                $CdpMessage = $CdpMessage | ConvertTo-Json -Compress
                $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage
                $DocumentNodeId = $BiDiSession.Responses[-1].result.root.nodeId
            }

            $CdpMessage2.params.nodeId = $DocumentNodeId
            if ($BidiSession.SessionId) { $CdpMessage2.sessionId = $BidiSession.SessionId }
            $CdpMessage2 = $CdpMessage2 | ConvertTo-Json -Compress
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage2

            return $BiDiSession
        }

        $null = New-BiDiSession -BiDiSession $BiDiSession
        $Message = $BidiMessage
        if ($BidiSession.IframeContextElement) {
            $Message.params.context = $BiDiSession.IframeContextElement
        } else {
            $Message.params.context = $BiDiSession.BrowserContext
        }
        $Message = $Message | ConvertTo-Json -Compress
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiKeyActions {
    <#
        .PARAMETER Value
        Most ascii text and staic properties from [BiDiKeyHelper] are valid.

        .EXAMPLE
        The following will result in 'send key'. The 's' is backspaced.
        -Value "send keys$([BiDiKeyHelper]::Backspace)"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory)]
        [string]$Value
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::InputPerformActions
            method = [BiDiMethod]::InputPerformActions
            params = @{
                context = $null # $BiDiSession.BrowserContext # no pipeline in begin block
                actions = @(
                    @{
                        type = 'key'
                        id = 'text'
                        actions = @()
                    }
                )
            }
        }

        $CdpMessageChar = @{
            id = [CdpMethodId]::InputDispatchKeyEvent
            method = 'Input.dispatchKeyEvent'
            params = @{
                type = 'char'
                text = ''
            }
        }

        $CdpMessageKeyCode = @{
            id = [CdpMethodId]::InputDispatchKeyEvent
            method = 'Input.dispatchKeyEvent'
            params = @{
                type = 'rawKeyDown'
                windowsVirtualKeyCode = 0
            }
        }

        $CdpMessageUp = @{
            id = [CdpMethodId]::InputDispatchKeyEvent
            method = 'Input.dispatchKeyEvent'
            params = @{
                type = 'keyUp'
            }
        } | ConvertTo-Json -Compress

        # $CdpMessageScroll = @{
        #     id = 999
        #     method = 'DOM.scrollIntoViewIfNeeded'
        #     params = @{
        #         nodeId = 1
        #     }
        # }
    }

    process {
        if ($BiDiSession.IsCdp()) {
            # Cdp has to send one key message at a time...
            $Value.ToCharArray() | ForEach-Object {
                if ([int]$_ -gt 0xE000) {
                    # 57344
                    $CdpMessageKeyCode.params.windowsVirtualKeyCode = [BiDiKeyHelper]::CharToWindowsVirtualKeyCode($_)
                    if ($BidiSession.SessionId) { $CdpMessageKeyCode.sessionId = $BidiSession.SessionId }
                    $CdpMessage = $CdpMessageKeyCode | ConvertTo-Json -Compress
                } else {
                    if ($BidiSession.SessionId) { $CdpMessageChar.sessionId = $BidiSession.SessionId }
                    $CdpMessageChar.params.text = $_
                    $CdpMessage = $CdpMessageChar | ConvertTo-Json -Compress
                }

                $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage
                $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessageUp
            }

            return $BiDiSession
        }

        $null = New-BiDiSession -BiDiSession $BiDiSession
        $Message = $BidiMessage
        $Message.params.context = $BiDiSession.BrowserContext
        $actions = $Value.ToCharArray().ForEach({
                @{
                    type = 'keyDown'
                    value = "$_"
                }
                @{
                    type = 'keyUp'
                    value = "$_"
                }
            })
        $Message.params.actions[0].actions = $actions
        $Message = ConvertTo-Json -InputObject $Message -Compress -Depth 10

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message

        $ReleaseMessage = @{
            id = [BiDiMethodId]::InputReleaseActions
            method = [BiDiMethod]::InputReleaseActions
            params = @{
                context = $BiDiSession.BrowserContext
            }
        }
        $Message = ConvertTo-Json -InputObject $ReleaseMessage -Compress -Depth 10
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BidiClickCurrentElement {
    <#
        .SYNOPSIS
        This virtually moves the mouse sends a mouse click to the selected element.

        .PARAMETER ClickCount
        The amount of clicks to make. One mouse down and up is one click count.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [BiDiSession]$BiDiSession,

        [ValidateSet(1, 2, 3, 4)]
        [int]$ClickCount = 1
    )

    begin {
        $BidiMessage = @{
            id = [BiDiMethodId]::InputPerformActions
            method = [BiDiMethod]::InputPerformActions
            params = @{
                context = $null # $BiDiSession.BrowserContext # no pipeline in begin block
                actions = @(
                    @{
                        type = 'pointer'
                        id = 'text'
                        # parameters = @() # optional default mouse
                        actions = @()
                    }
                )
            }
        }

        $CdpMessageBox = @{
            id = [CdpMethodId]::DomGetBoxModel
            method = 'DOM.getBoxModel'
            params = @{
                nodeId = $null
            }
        }

        $CdpMessageDown = @{
            id = [CdpMethodId]::InputDispatchMouseEvent
            method = 'Input.dispatchMouseEvent'
            params = @{
                type = 'mousePressed'
                x = $null
                y = $null
                button = 'left'
                clickCount = $ClickCount
                pointerType = 'mouse'
            }
        }

        $CdpMessageUp = @{
            id = [CdpMethodId]::InputDispatchMouseEvent
            method = 'Input.dispatchMouseEvent'
            params = @{
                type = 'mouseReleased'
                x = $null
                y = $null
                button = 'left'
                clickCount = $ClickCount
                pointerType = 'mouse'
            }
        }
    }

    process {
        if ($null -eq $BiDiSession.CurrentElement) {
            throw '$BiDiSession.CurrentElement is empty. No element selected. Removing a session also resets the current element for BiDi.'
        }

        if ($BiDiSession.IsCdp()) {
            # get element coords of current element and click
            if ($BidiSession.SessionId) { $CdpMessageBox.sessionId = $BidiSession.SessionId }
            $CdpMessageBox.params.nodeId = [int]$BiDiSession.CurrentElement
            $CdpMessage = $CdpMessageBox | ConvertTo-Json -Compress
            $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $CdpMessage
            $ElementCoords = $BiDiSession.Responses[-1].result.model.content

            if ($null -eq $ElementCoords) {
                Write-Warning 'Could not get box model for current element. Did not click.'
                return $BiDiSession
            }

            $ElementX = $ElementCoords[0]
            $ElementY = $ElementCoords[1]

            if ($BidiSession.SessionId) { $CdpMessageDown.sessionId = $BidiSession.SessionId }
            $CdpMessageDown.params.x = $ElementX
            $CdpMessageDown.params.y = $ElementY
            $CdpMessageDown = $CdpMessageDown | ConvertTo-Json -Compress

            if ($BidiSession.SessionId) { $CdpMessageUp.sessionId = $BidiSession.SessionId }
            $CdpMessageUp.params.x = $ElementX
            $CdpMessageUp.params.y = $ElementY
            $CdpMessageUp = $CdpMessageUp | ConvertTo-Json -Compress

            $null = $CdpMessageDown, $CdpMessageUp | Invoke-BiDiMessage -BiDiSession $BiDiSession

            return $BiDiSession
        }

        $null = New-BiDiSession -BiDiSession $BiDiSession
        $Message = $BidiMessage
        $Message.params.context = $BiDiSession.BrowserContext

        $MouseActions = @(
            @{
                type = 'pointerMove'
                x = 0
                y = 0
                origin = @{
                    type = 'element'
                    element = @{
                        sharedId = $BiDiSession.CurrentElement
                    }
                }
            }
        )
        $MouseClicks = 1..$ClickCount | ForEach-Object {
            @{
                type = 'pointerDown'
                button = 0
            },
            @{
                type = 'pointerUp'
                button = 0
            }
        }
        $MouseActions += $MouseClicks

        $Message.params.actions[0].actions = $MouseActions
        $Message = ConvertTo-Json -InputObject $Message -Compress -Depth 10

        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message

        $ReleaseMessage = @{
            id = [BiDiMethodId]::InputReleaseActions
            method = [BiDiMethod]::InputReleaseActions
            params = @{
                context = $BiDiSession.BrowserContext
            }
        }
        $Message = ConvertTo-Json -InputObject $ReleaseMessage -Compress -Depth 10
        $null = Invoke-BiDiMessage -BiDiSession $BiDiSession -Message $Message
        $BiDiSession
    }

    end {
        if ($BiDiSession.ReleaseSession) {
            $BiDiSession.ReleaseSession = $false
            $null = Remove-BiDiSession -BiDiSession $BiDiSession
        }
    }
}

function Invoke-BiDiMessage {
    <#
        .SYNOPSIS
        Sends and receives the message with the same id.
    #>
    [CmdletBinding(DefaultParameterSetName = 'NoBiDiSession')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BiDiSession')]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory, ParameterSetName = 'NoBiDiSession')]
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,

        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateScript({ $true -eq (ConvertFrom-Json -InputObject $_) })]
        [string]$Message,

        [int]$BufferSize = 1024
    )

    begin {
        $Encoder = [System.Text.UTF8Encoding]::UTF8
        $Buffer = [System.ArraySegment[byte]]::new([byte[]]::new($BufferSize))
        $MemoryStream = [System.IO.MemoryStream]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
            $WebSocket = $BiDiSession.WebSocket
        }

        if ($WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Warning ("WebSocket is not open. Current Message did not send:`n{0}" -f $Message)
            return
        }

        $SentBuffer = [System.ArraySegment[byte]]::new($Encoder.GetBytes($Message))
        $sentTask = $WebSocket.SendAsync($SentBuffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)

        $null = $sentTask.GetAwaiter().GetResult()
        if ($sentTask.IsFaulted -or !$sentTask) {
            Write-Warning ("WebSocket.SendAsync failed for Message:`n{0}" -f $Message)
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession' -and $DebugPreference -eq 'Continue') {
            $BiDiSession.Messages.Add($Message)
        }

        # A Message will always have an id and will always receive the id back.
        # Events do not an id but do have a method property.
        # This runs at least once because $ParsedJson is $null until it loops once.
        $MessageId = ($Message | ConvertFrom-Json).id
        $Responses = while ($ParsedJson.id -ne $MessageId) {
            if ($WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                return
            }

            do {
                $ReceiveTask = $WebSocket.ReceiveAsync($Buffer, [System.Threading.CancellationToken]::None)
                $MemoryStream.Write($Buffer, 0, $ReceiveTask.Result.Count)
            } while (!$ReceiveTask.Result.EndOfMessage -and $null -ne $ReceiveTask.Result.EndOfMessage)

            $RawJsonResponse = $Encoder.GetString($MemoryStream.ToArray())
            $ParsedJson = $RawJsonResponse | ConvertFrom-Json

            if ($RawJsonResponse.Trim().Length -gt 0) {
                if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
                    $BiDiSession.AddResponse($RawJsonResponse)
                } else {
                    $RawJsonResponse
                }
            }

            $MemoryStream.SetLength(0)
            $Buffer.Array.Clear()
        }

        $Responses
    }
}

function Send-BiDiMessage {
    <#
        .SYNOPSIS
        Sends message to the websocket.
    #>
    [CmdletBinding(DefaultParameterSetName = 'BiDiSession')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BiDiSession')]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory, ParameterSetName = 'NoBiDiSession')]
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,

        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateScript({ $true -eq (ConvertFrom-Json -InputObject $_) })]
        [string]$Message
    )

    begin {
        $Encoder = [System.Text.UTF8Encoding]::UTF8
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
            $WebSocket = $BiDiSession.WebSocket
        }

        if ($WebSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Warning ("WebSocket is not open. Current Message did not send:`n{0}" -f $Message)
            return
        }

        $Buffer = [System.ArraySegment[byte]]::new($Encoder.GetBytes($Message))
        $null = $WebSocket.SendAsync($Buffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None) # void task
        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession' -and $DebugPreference -eq 'Continue') {
            $BiDiSession.Messages.Add($Message)
        }

    }
}

function Receive-BiDiMessage {
    <#
        .SYNOPSIS
        Processes the ReceiveAsync queue until timeout.

        .PARAMETER Timeout
        Time in milliseconds to wait before sending an empty message to finish ReceiveAsync.

        .PARAMETER WaitForEvent
        Only valid for Cdp
        Waits for the dom event or the frame event to be received.
    #>
    [CmdletBinding(DefaultParameterSetName = 'BiDiSession')]
    [OutputType([BiDiSession])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'BiDiSession')]
        [BiDiSession]$BiDiSession,

        [Parameter(Mandatory, ParameterSetName = 'NoBiDiSession')]
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,

        [int]$BufferSize = 1024,

        [int]$Timeout = 3000,

        [ValidateSet('Page.domContentEventFired', 'Page.frameStoppedLoading')]
        [string]$WaitForEvent
    )

    begin {
        $DummyReceive = $false
        $DummyMessage = @{id = -1; method = 'ReceiveAsync Timeout' } | ConvertTo-Json -Compress
        $Encoder = [System.Text.UTF8Encoding]::UTF8
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
            $WebSocket = $BiDiSession.WebSocket
        }

        $Buffer = [System.ArraySegment[byte]]::new([byte[]]::new($BufferSize))
        $MemoryStream = [System.IO.MemoryStream]::new()

        $Responses = do {
            do {
                $TimeoutCount = 0
                $RawJsonResponse = $null
                $ReceiveTask = $WebSocket.ReceiveAsync($Buffer, [System.Threading.CancellationToken]::None)

                while ($ReceiveTask.Status -eq [System.Threading.Tasks.TaskStatus]::WaitingForActivation -or
                    $ReceiveTask.Status -eq [System.Threading.Tasks.TaskStatus]::WaitingToRun) {
                    Start-Sleep -Milliseconds 100
                    $TimeoutCount += 100
                    if ($TimeoutCount -gt $Timeout) {
                        # Send an empty message to process to free the thread from ReceiveAsync.
                        $DummyBuffer = [System.ArraySegment[byte]]::new($Encoder.GetBytes($DummyMessage))
                        $null = $WebSocket.SendAsync($DummyBuffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)

                        $DummyReceive = $true
                        break
                    }
                }

                try {
                    $null = $ReceiveTask.GetAwaiter().GetResult()
                } catch {
                    Write-Warning 'Receive-BiDiMessage websocket is aborted.'
                    break
                }

                $MemoryStream.Write($Buffer, 0, $ReceiveTask.Result.Count)
            } while (!$ReceiveTask.Result.EndOfMessage -and $null -ne $ReceiveTask.Result.EndOfMessage)

            $RawJsonResponse = $Encoder.GetString($MemoryStream.ToArray())

            if ($RawJsonResponse.Trim().Length -gt 0) {
                if ($PSCmdlet.ParameterSetName -eq 'BiDiSession') {
                    $BiDiSession.AddResponse($RawJsonResponse)

                    if ($BiDiSession.IsCdp()) {
                        $PageEvent = $RawJsonResponse | ConvertFrom-Json
                        if ($PageEvent.method -eq $WaitForEvent) {
                            $DummyReceive = $true
                        }
                    }
                } else {
                    $RawJsonResponse
                }
            }

            $MemoryStream.SetLength(0)
            $Buffer.Array.Clear()

            if ($DummyReceive) { break }
        } until ($null -eq $RawJsonResponse -or ($RawJsonResponse.Trim().Length) -eq 0)

        $Responses
    }
}

class CdpCapabilities {
    [string]$UserDataDir
    [bool]$EnableAutomation = $true
    [bool]$Headless = $false
    [bool]$NoFirstRun = $true
    [ValidateRange(0, 65535)]
    [int]$RemoteDebuggingPort = 0
    [string]$StartupUrl
    CdpCapabilities($UserDataDir) { $this.UserDataDir = $UserDataDir }
    [string[]]ConvertToArgs() {
        return @(
            ('--user-data-dir="{0}"' -f $this.UserDataDir)
            if ($this.EnableAutomation) { '--enable-automation' }
            if ($this.Headless) { '--headless' }
            if ($this.NoFirstRun) { '--no-first-run' }
            ('--remote-debugging-port={0}' -f $this.RemoteDebuggingPort)
            $this.StartupUrl
        ) | Where-Object { $_ -ne '' -and $_ -ne $null }
    }
}

class FirefoxCapabilities {
    [string]$ProfileName
    [string]$UserDataDir
    [bool]$Headless = $false
    [ValidateRange(0, 65535)]
    [int]$RemoteDebuggingPort = 0
    [string]$StartupUrl
    FirefoxCapabilities([string]$ProfileName) { $this.ProfileName = $ProfileName }
    FirefoxCapabilities([System.IO.DirectoryInfo]$UserDataDir) { $this.UserDataDir = $UserDataDir }
    [string[]]ConvertToArgs() {
        return @(
            if ($this.UserDataDir) { '-Profile "{0}"' -f $this.UserDataDir } else { '-P "{0}"' -f $this.ProfileName } # must be -Profile and not -P if $UserDataDir
            if ($this.Headless) { '--headless' }
            ('--remote-debugging-port={0}' -f $this.RemoteDebuggingPort)
            $this.StartupUrl
        ) | Where-Object { $_ -ne '' -and $_ -ne $null }
    }
}

function New-CdpCapabilities {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container -IsValid })]
        [string]$UserDataDir, # = Join-Path -Path "$env:LOCALAPPDATA -ChildPath 'Temp\Guid.User Data'
        [bool]$EnableAutomation = $true,
        [bool]$Headless = $false,
        [bool]$NoFirstRun = $true,
        [string]$StartupUrl
    )

    $CdpCapabilities = [CdpCapabilities]::new($UserDataDir)
    $CdpCapabilities.EnableAutomation = $EnableAutomation
    $CdpCapabilities.Headless = $Headless
    $CdpCapabilities.NoFirstRun = $NoFirstRun
    $CdpCapabilities.StartupUrl = $StartupUrl

    return $CdpCapabilities
}

function New-FirefoxCapabilities {
    <#
        .PARAMETER ProfileName
        Expects profile to be in the default appdata folder.

        .PARAMETER UserDataDir
        Path to the UserDataDir. Firefox will create it if it doesn't exist.
        Will not show up under about:profiles
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByProfile')]
        [string]$ProfileName, # = 'default-release'

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [System.IO.DirectoryInfo]$UserDataDir,
        [bool]$Headless = $false,
        [string]$StartupUrl
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByProfile') {
        $FirefoxCapabilities = [FirefoxCapabilities]::new($ProfileName)
    } else {
        $FirefoxCapabilities = [FirefoxCapabilities]::new($UserDataDir)
    }

    $FirefoxCapabilities.Headless = $Headless
    $FirefoxCapabilities.StartupUrl = $StartupUrl

    return $FirefoxCapabilities
}

function Start-CdpBrowser {
    <#
        .SYNOPSIS
        Starts the browser for automation.

        .PARAMETER BrowserPath
        Provide the FullName .exe of the browser.

        .PARAMETER ContinueSession
        Does not reset the tab from $BiDiSession.SessionId (A blank SessionId defaults to the cdp websocket's tab.)
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'UserType')]
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'UserPath')]
        [CdpCapabilities]$CdpCapabilities,

        [Parameter(ParameterSetName = 'UserType')]
        [ValidateSet('Chrome', 'Edge')]
        [string]$BrowserType,

        [Parameter(ParameterSetName = 'UserPath')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$BrowserPath,

        [switch]$ContinueSession
    )

    begin {
        # Todo dynamic paths
        $BrowserPath = if ($PSCmdlet.ParameterSetName.Contains('UserType')) {
            switch ($BrowserType) {
                Chrome { 'C:\Program Files\Google\Chrome\Application\chrome.exe' }
                Default { 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }
            }
        }

        $TimeBeforeLaunch = (Get-Date).Ticks
    }

    process {
        $UserDataFolder = $CdpCapabilities.UserDataDir

        $BrowserInUse = $false
        if (Test-Path -Path $UserDataFolder -PathType Container) {
            $LockFile = Get-ChildItem -Path $UserDataFolder -Filter 'lockfile'
            if ($LockFile.Count -eq 1) { $BrowserInUse = $true }
        }

        $BrowserArgs = $CdpCapabilities.ConvertToArgs()
        $BrowserProcess = Start-Process -FilePath $BrowserPath -ArgumentList $BrowserArgs -PassThru

        if ($CdpCapabilities.RemoteDebuggingPort -eq 0) {
            $DevToolsPath = Join-Path -Path $UserDataFolder -ChildPath 'DevToolsActivePort'

            while (!(Test-Path -Path $DevToolsPath -PathType Leaf)) {
                if ($BrowserProcess.HasExited -or $null -eq $BrowserProcess) { throw 'Browser did not launch correctly. Please check args.' }
                Start-Sleep -Seconds 1
            }

            $DevToolsFile = Get-Item -Path $DevToolsPath

            while ($DevToolsFile.LastWriteTime.Ticks -lt $TimeBeforeLaunch) {
                if ($BrowserInUse) { break }
                if ($browserProcess.HasExited) { throw 'Browser closed before active port aquired.' }
                Start-Sleep -Seconds 1
                $DevToolsFile = Get-Item -Path $DevToolsPath
            }

            $DevToolsData = Get-DevToolsActivePort -UserDataDir $UserDataFolder
            $AvailableConnections = Invoke-RestMethod -Uri "http://localhost:$($DevToolsData.Port)/json"

            # Only available if launched with port=0
            # We don't need to connect to the browser socket for Browser.close, the page websocket accepts Browser.close but not does not take the other Browser.commands like Browser.getVersion
            # $BrowserWebSocket = 'ws://localhost:{0}{1}' -f $DevToolsData.Port, $DevToolsData.BrowserWebSocket # 12345 # /devtools/browser/21b825af-5d18-4ff9-866e-35e04356814c
            # $CdpBrowserWebSocket = New-BiDiWebSocket -WebSocketUrl $BrowserWebSocket
        } else {
            $AvailableConnections = Invoke-RestMethod -Uri "http://localhost:$($CdpCapabilities.RemoteDebuggingPort)/json"
        }

        if (!$AvailableConnections) { throw 'Could not invoke localhost port' }

        $WebSocketUrl = ($AvailableConnections | Where-Object { ($_.type -eq 'page') })[0].webSocketDebuggerUrl # ws://localhost:12345/devtools/page/AE336CB22722E0B2A2CB4BB87F2292A6
        $BiDiSession = New-BiDiWebSocket -WebSocketUrl $WebSocketUrl
        $BiDiSession.WebSocketUrl = $WebSocketUrl
        # $CdpPipe.CdpBrowserWebSocket = $CdpBrowserWebSocket.WebSocket
        $BiDiSession.ReleaseSession = !$ContinueSession
        $BiDiSession
    }
}

function Start-FirefoxBrowser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Firefox')]
        [FirefoxCapabilities]$FirefoxCapabilities,
        [string]$BrowserPath,
        [switch]$ContinueSession
    )

    begin {
        # Todo dynamic path
        if (!$BrowserPath) { $BrowserPath = 'C:\Program Files\Mozilla Firefox\firefox.exe' }
        $TimeBeforeLaunch = (Get-Date).Ticks
        $BrowserInUse = $false
        $CheckLockFile = $true
    }

    process {
        if ($FirefoxCapabilities.ProfilePath) {
            $FirstProfile = $FirefoxCapabilities.ProfilePath.FullName
            # if it fails, the profile has not been created yet. We will let firefox make it.
            try { Resolve-Path -Path $FirstProfile -ErrorAction Stop } catch { $CheckLockFile = $false }
        } else {
            $ProfileName = $FirefoxCapabilities.ProfileName
            $FirefoxProfileFolders = "$env:APPDATA\Mozilla\Firefox\Profiles"
            $ProfilePaths = Get-ChildItem -Path $FirefoxProfileFolders -Filter "*.$ProfileName"
            if ($ProfilePaths.Count -eq 0) { throw 'Firefox profile does not exist. Create one with "-CreateProfile profile_name" ' }
            $FirstProfile = $ProfilePaths[0].FullName
        }

        if ($CheckLockFile) {
            $LockFilePath = Join-Path -Path $FirstProfile -ChildPath 'parent.lock' # Firefox does not delete parent.lock unlike chromium
            try { Get-Content $LockFilePath -ErrorAction Stop } catch { $BrowserInUse = $true }
        }

        $BrowserArgs = $FirefoxCapabilities.ConvertToArgs()
        $BrowserProcess = Start-Process -FilePath $BrowserPath -ArgumentList $BrowserArgs -PassThru

        $DevToolsPath = Join-Path -Path $FirstProfile -ChildPath 'WebDriverBiDiServer.json'

        while (!(Test-Path -Path $DevToolsPath -PathType Leaf)) {
            if ($BrowserProcess.HasExited -or $null -eq $BrowserProcess) { throw 'Browser did not launch correctly. Please check args.' }
            Start-Sleep -Seconds 1
        }

        $DevTools = Get-Item -Path $DevToolsPath

        while ($DevTools.LastWriteTime.Ticks -lt $TimeBeforeLaunch) {
            if ($BrowserInUse) { break }
            if ($BrowserProcess.HasExited) { throw 'Browser closed before active port aquired.' }
            Start-Sleep -Seconds 1
            $DevTools = Get-Item -Path $DevToolsPath
        }

        $DevToolsContent = Get-Content -Path $DevToolsPath | ConvertFrom-Json
        # {
        #     "ws_host": "127.0.0.1",
        #     "ws_port": 52972
        # }
        # should be put together like so: ws://127.0.0.1:52972/session
        $WebSocketUrl = 'ws://{0}:{1}/session' -f $DevToolsContent.ws_host, $DevToolsContent.ws_port

        $BiDiSession = New-BiDiWebSocket -WebSocketUrl $WebSocketUrl
        $BiDiSession.WebSocketUrl = $WebSocketUrl
        $null = $BiDiSession | New-BiDiSession -ContinueSession:$ContinueSession
        $BiDiSession
    }
}

function Get-DevToolsActivePort {
    <#
        .SYNOPSIS
        Returns the active port and websocket url
        For the provided userdatadir or
        default firefox profile folder location by the provided profile name

        https://chromedevtools.github.io/devtools-protocol/
        Chromium overwrites the file "DevToolsActivePort" in the UserDataDir

        https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/109
        Firefox creates a file "WebDriverBiDiServer.json" in the AppData\Roaming\Mozilla\Firefox\Profiles\abc123.ProfileName folder
        Firefox also deletes this file on browser close unlike Chromium
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'Chromium')]
        [string]$UserDataDir,

        [Parameter(Mandatory, ParameterSetName = 'Firefox')]
        [string]$FirefoxProfileName,

        [Parameter(Mandatory, ParameterSetName = 'FirefoxPath')]
        [string]$FirefoxProfilePath
    )

    $PortFile = if ($PSCmdlet.ParameterSetName.Contains('Chromium')) {
        Join-Path -Path $UserDataDir -ChildPath 'DevToolsActivePort'
    } elseif ($PSCmdlet.ParameterSetName.Contains('FirefoxPath')) {
        Join-Path -Path $FirefoxProfilePath -ChildPath 'WebDriverBiDiServer.json'
    } else {
        $FirefoxProfileFolders = Join-Path -Path $env:APPDATA -ChildPath '\Mozilla\Firefox\Profiles'
        $ProfilePaths = Get-ChildItem -Path $FirefoxProfileFolders -Filter "*.$FirefoxProfileName"
        if ($ProfilePaths.Count -eq 0) { throw 'Firefox profile does not exist. Create one with "-CreateProfile profile_name"' }
        $FirstProfile = $ProfilePaths[0].FullName
        Join-Path -Path $FirstProfile -ChildPath 'WebDriverBiDiServer.json'
    }

    if (Test-Path -Path $PortFile -PathType Leaf) {
        $PortFileInfo = Get-Item -Path $PortFile
        if ($PortFileInfo.Extension -eq '.json') {
            $DevToolsContent = Get-Content -Path $PortFile | ConvertFrom-Json
            # {
            #     "ws_host": "127.0.0.1",
            #     "ws_port": 52972
            # }
            # should be put together like so: ws://127.0.0.1:52972/session
            [PSCustomObject]@{
                Port = $DevToolsContent.ws_port
                BrowserWebSocket = ''
                FirefoxHost = $DevToolsContent.ws_host
            }
        } else {
            # Assume cdp
            $DevToolsContent = Get-Content -Path $PortFile -TotalCount 2
            [PSCustomObject]@{
                Port = $DevToolsContent[0]
                BrowserWebSocket = $DevToolsContent[1]
                FirefoxHost = ''
            }
        }
    }
}
