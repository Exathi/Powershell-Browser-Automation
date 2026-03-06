class CdpPage {
	$TargetId
	$Url
	$Title
	$SessionId
	$ProcessId
	CdpPage() {}
	CdpPage($TargetId, $Url, $Title) {
		$this.TargetId = $TargetId
		$this.Url = $Url
		$this.Title = $Title
	}
	CdpPage($TargetId, $Url, $Title, $SessionId) {
		$this.SessionId = $SessionId
		$this.TargetId = $TargetId
		$this.Url = $Url
		$this.Title = $Title
	}
	[bool]$IsNavigating = $false
	[int]$LoadEventFired = 0
	[int]$FrameStoppedLoading = 0
	[int]$FrameStartedLoading = 0
	$EventTimeline = [System.Collections.Generic.List[object]]::new()
	[int]$DocumentNode
	# [int[]]$SelectorNode
	$BoxModel
	$Frames = [System.Collections.Generic.Dictionary[string, object]]::new()
	$RuntimeUniqueId
	$ObjectId
}

class CdpPipeBrowser {
	[System.IO.Pipes.AnonymousPipeServerStream]$PipeWriter
	[System.IO.Pipes.AnonymousPipeServerStream]$PipeReader
	[System.Diagnostics.Process]$Process
	$Targets = [System.Collections.Generic.List[CdpPage]]::new()
	$ErrorResponses = [System.Collections.Generic.List[object]]::new()
	$CommandResponses = [System.Collections.Generic.List[object]]::new()
	$EventTimeline = [System.Collections.Generic.List[object]]::new()
	$LastCommandId = 0
	CdpPipeBrowser() {}
	CdpPipeBrowser($OutPipe, $InPipe, $Process) {
		$this.PipeWriter = $OutPipe
		$this.PipeReader = $InPipe
		$this.Process = $Process
	}
	[void]SendCommand([hashtable]$CdpCommand) { $this.SendCommand($CdpCommand, $null, 1024) }
	[void]SendCommand([hashtable]$CdpCommand, [CdpPage]$CdpPage) { $this.SendCommand($CdpCommand, $CdpPage, 1024) }
	[void]SendCommand([hashtable]$CdpCommand, [CdpPage]$CdpPage, [int]$BufferSize) {
		if ($this.Process.HasExited) { throw 'Browser is closed.' }
		if (!$this.PipeWriter.IsConnected -or !$this.PipeReader.IsConnected) { throw 'Pipes are not connected.' }

		$CdpCommand.id = $this.IncrementCommandId()
		$JsonCommand = $CdpCommand | ConvertTo-Json -Depth 10 -Compress
		$CommandBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonCommand) + 0 # The message must end in a null char.
		$this.PipeWriter.Write($CommandBytes, 0, $CommandBytes.Length)
		# $this.PipeWriter.WriteByte(0)
		$this.PipeWriter.Flush()

		$this.ProcessAllResponses($BufferSize, $false, $CdpPage)
	}
	[string]ReceiveRawResponse() { return $this.ReceiveRawResponse(1024, $true) }
	[string]ReceiveRawResponse([int]$BufferSize, [bool]$SendNull) {
		# We send a null char to the pipe so PipeReader.Read() does not hang indefinitely on an empty pipe.
		if ($SendNull) {
			$this.PipeWriter.WriteByte(0)
			$this.PipeWriter.Flush()
		}

		$Buffer = [byte[]]::new($BufferSize)
		$StringBuilder = [System.Text.StringBuilder]::new()

		$EndIsNotNull = $true
		do {
			$BytesRead = $this.PipeReader.Read($Buffer, 0, $Buffer.Length)
			$null = $StringBuilder.Append([System.Text.Encoding]::UTF8.GetString($Buffer, 0, $BytesRead))

			$EndIsNotNull = if ($StringBuilder.Length -gt 0) { $StringBuilder.ToString($StringBuilder.Length - 1, 1) -ne "`0" } else { $true }
		} while ($StringBuilder.Length -eq 0 -or $EndIsNotNull)

		return $StringBuilder.ToString()
	}
	[void]ProcessEvent($JsonResponse) {
		# If there is a sessionId there will be a target added by Target.targetCreated
		$SessionId = $JsonResponse.sessionId
		$CurrentPage = if ($SessionId) { $this.Targets.Find({ param($Page) $Page.SessionId -eq $SessionId }) }

		switch ($JsonResponse.method) {
			'Target.targetCreated' {
				# setAutoAttach is setup to filter out everything except pages so everything is a valid attached page.
				$Target = $JsonResponse.params.targetInfo
				$this.Targets.Add([CdpPage]::new($Target.targetId, $Target.Url, $Target.Title, $JsonResponse.params.sessionId))
				break
			}
			'Target.attachedToTarget' {
				$Target = ($this.Targets.Find({ param($Page) $Page.TargetId -eq $JsonResponse.params.targetInfo.targetId }))
				$Target.sessionId = $JsonResponse.params.sessionId
				break
			}
			'Target.detachedFromTarget' {
				$CurrentPage.sessionId = $null
				break
			}
			'Target.targetInfoChanged' {
				$Target = $JsonResponse.params.targetInfo
				$UpdateTarget = $this.Targets.Find({ param($Page) $Page.TargetId -eq $Target.targetId })
				$UpdateTarget.Url = $Target.Url
				$UpdateTarget.Title = $Target.Title
				$UpdateTarget.ProcessId = $Target.pid
				break
			}
			'Target.targetDestroyed' {
				$null = $this.Targets.Remove($this.Targets.Find({ param($Page) $Page.TargetId -eq $JsonResponse.params.targetId }))
				break
			}
			'DOM.documentUpdated' {
				$CurrentPage.DocumentNode = $null
			}
			'Page.frameStartedLoading' {
				$CurrentPage.FrameStartedLoading++
			}
			'Page.frameStoppedLoading' {
				$CurrentPage.FrameStoppedLoading++
			}
			'Page.loadEventFired' {
				$CurrentPage.LoadEventFired++
			}
			'Page.frameAttached' {
				$CurrentPage.Frames.Add($JsonResponse.params.frameId, @{
						frameId = $JsonResponse.params.frameId
						parentFrameId = $JsonResponse.params.parentFrameId
						sessionId = $JsonResponse.sessionId
						uniqueId = ''
					}
				)
			}
			'Page.frameDetached' {
				$Target = $this.Targets.Find({ param($Page) $JsonResponse.params.parentFrameId -in $Page.Frames.Keys })
				$null = $Target.Frames.Remove($JsonResponse.params.frameId)
			}
			'Runtime.executionContextCreated' {
				$TargetId = $JsonResponse.params.context.auxData.frameId
				if ($CurrentPage.TargetId -eq $TargetId) {
					$CurrentPage.RuntimeUniqueId = $JsonResponse.params.context.uniqueId
				} elseif ($TargetId -in $CurrentPage.Frames.Keys) {
					$CurrentPage.Frames[$TargetId].uniqueId = $JsonResponse.params.context.uniqueId
				}
			}
			'Runtime.executionContextsCleared' {
				$CurrentPage.Frames.Clear()
				$CurrentPage.RuntimeUniqueId = $null
			}
			{ $null -ne $SessionId } { $CurrentPage.EventTimeline.Add($JsonResponse) }
		}
	}
	[void]ProcessCommand($JsonResponse) {
		$this.CommandResponses.Add($JsonResponse)
		$CurrentPage = $this.Targets.Find({ param($Page) $Page.SessionId -eq $JsonResponse.sessionId })
		$DocumentNode = $JsonResponse.result.root.nodeId
		# $SelectorNode = $JsonResponse.result.nodeIds
		$BoxModel = $JsonResponse.result.model
		$ObjectId = if ($JsonResponse.result.result.subtype -eq 'node') {
			$JsonResponse.result.result.objectId
		}

		if ($DocumentNode) { $CurrentPage.DocumentNode = $DocumentNode }
		# if ($SelectorNode) { $CurrentPage.SelectorNode = $SelectorNode }
		if ($BoxModel) { $CurrentPage.BoxModel = $BoxModel }
		if ($ObjectId) { $CurrentPage.ObjectId = $ObjectId }
	}
	[object]ProcessResponse() { return $this.ProcessResponse(1024, $true) }
	[object]ProcessResponse([int]$BufferSize, [bool]$SendNull) {
		$RawResponse = $this.ReceiveRawResponse($BufferSize, $SendNull)
		$SplitResponse = @(($RawResponse -split "`0").Where({ "`0" -ne $_ }) | ConvertFrom-Json)
		$NoEventsToProcessCount = 0

		$SplitResponse.ForEach({
				switch ($_) {
					{ $_.error.code -eq '-32700' } { $NoEventsToProcessCount++; break }
					{ $_.error.code -ne '-32700' } { $this.EventTimeline.Add($_) }
					{ $null -ne $_.error -and $_.error.code -ne '-32700' } { $this.ErrorResponses.Add($_) }
					{ $null -ne $_.method -and $null -eq $_.error } { $this.ProcessEvent($_) }
					{ $null -ne $_.id } { $this.ProcessCommand($_) }
				}
			}
		)

		return @{ Messages = $SplitResponse; NullCount = $NoEventsToProcessCount }
	}
	[void]ProcessAllResponses() { $this.ProcessAllResponses(1024, $true, $null) }
	[void]ProcessAllResponses([int]$BufferSize, [bool]$SendNull, [CdpPage]$Page) {
		$NoEventsToProcessCount = 0
		$ProcessedMessage = $null
		$LoadEventFired = $Page.LoadEventFired

		do {
			$ProcessedMessage = $this.ProcessResponse($BufferSize, $SendNull)
			$NoEventsToProcessCount += $ProcessedMessage.NullCount

			# Make sure to process everything else if there are actual messages mixed in before exiting do.
			if ($NoEventsToProcessCount -gt 3) { Write-Host 'Stopping ProcessResponse. More than 3 null events received. (id)' -ForegroundColor Cyan; return }
		} while ($this.LastCommandId -notin $ProcessedMessage.Messages.id)

		# If there is a page navigating, we want to wait by default for loading events immediately after receving the id.
		if ($Page.IsNavigating) {
			while ($LoadEventFired -eq $Page.LoadEventFired -or $Page.FrameStartedLoading -ne $Page.FrameStoppedLoading) {
				$ProcessedMessage = $this.ProcessResponse($BufferSize, $SendNull)
				$NoEventsToProcessCount += $ProcessedMessage.NullCount

				if ($NoEventsToProcessCount -gt 3) { Write-Host 'Stopping ProcessResponse. More than 3 null events received. (navigating)' -ForegroundColor Cyan; return }
			}
			$Page.IsNavigating = $false
		}
	}
	[void]CloseBrowser() {
		$this.PipeWriter.Dispose()
		$this.PipeReader.Dispose()
		$this.Process.Dispose()
		$this.Targets.Clear()
	}
	[int]IncrementCommandId() {
		$this.LastCommandId++
		return $this.LastCommandId
	}
}

class CdpTargetCommand {
	static [hashtable]createTarget($Url) {
		return @{
			id = 0
			method = 'Target.createTarget'
			params = @{
				url = $Url
			}
		}
	}
	static [hashtable]getTargets() {
		return @{
			id = 0
			method = 'Target.getTargets'
		}
	}
	static [hashtable]attachToTarget([string]$TargetId) {
		return @{
			id = 0
			method = 'Target.attachToTarget'
			params = @{
				targetId = $TargetId
				flatten = $true
			}
		}
	}
	static [hashtable]setAutoAttach() {
		return @{
			id = 0
			method = 'Target.setAutoAttach'
			params = @{
				autoAttach = $true
				waitForDebuggerOnStart = $false
				filter = @(
					@{
						type = 'service_worker'
						exclude = $true
					},
					@{
						type = 'worker'
						exclude = $true
					},
					@{
						type = 'browser'
						exclude = $true
					},
					@{
						type = 'tab'
						exclude = $true
					},
					@{
						type = 'other'
						exclude = $true
					},
					@{
						type = 'background_page'
						exclude = $true
					},
					@{}
				)
				flatten = $true
			}
		}
	}
	static [hashtable]setDiscoverTargets() {
		return @{
			id = 0
			method = 'Target.setDiscoverTargets'
			params = @{
				discover = $true
				filter = @(
					@{
						type = 'service_worker'
						exclude = $true
					},
					@{
						type = 'worker'
						exclude = $true
					},
					@{
						type = 'browser'
						exclude = $true
					},
					@{
						type = 'tab'
						exclude = $true
					},
					@{
						type = 'other'
						exclude = $true
					},
					@{
						type = 'background_page'
						exclude = $true
					},
					@{}
				)
			}
		}
	}
}

class CdpBrowserCommand {
	static [hashtable]close() {
		return @{
			id = 0
			method = 'Browser.close'
		}
	}
}

class CdpPageCommand {
	static [hashtable]navigate($SessionId, $Url) {
		return @{
			id = 0
			method = 'Page.navigate'
			sessionId = $SessionId
			params = @{
				url = $Url
			}
		}
	}
	static [hashtable]enable($SessionId) {
		return @{
			id = 0
			method = 'Page.enable'
			sessionId = $SessionId
		}
	}
}

class CdpDomCommand {
	static [hashtable]disable($SessionId) {
		return @{
			id = 0
			method = 'DOM.disable'
			sessionId = $SessionId
		}
	}
	static [hashtable]enable($SessionId) {
		return @{
			id = 0
			method = 'DOM.enable'
			sessionId = $SessionId
		}
	}
	static [hashtable]getDocument($SessionId) {
		# Implicitly enables the DOM domain events for the current target.
		return @{
			id = 0
			method = 'DOM.getDocument'
			sessionId = $SessionId
			params = @{
				depth = 1
				pierce = $false
			}
		}
	}
	static [hashtable]getBoxModel($SessionId) {
		return @{
			id = 0
			method = 'DOM.getBoxModel'
			sessionId = $SessionId
			params = @{} #nodeId or objectId
		}
	}
	static [hashtable]querySelectorAll($SessionId, $Selector) {
		return @{
			id = 0
			method = 'DOM.querySelectorAll'
			sessionId = $SessionId
			params = @{
				nodeId = 0
				selector = $Selector
			}
		}
	}
	static [hashtable]describeNode($SessionId) {
		return @{
			id = 0
			method = 'DOM.describeNode'
			sessionId = $SessionId
			params = @{
				nodeId = 0
				depth = 1
			}
		}
	}
}

class CdpInputCommand {
	static [hashtable]dispatchKeyEvent($SessionId, $Text) {
		return @{
			id = 0
			method = 'Input.dispatchKeyEvent'
			sessionId = $SessionId
			params = @{
				type = 'char'
				text = $Text
			}
		}
	}
	static [hashtable]dispatchMouseEvent($SessionId, $Type, $Button) {
		return @{
			id = 0
			method = 'Input.dispatchMouseEvent'
			sessionId = $SessionId
			params = @{
				type = $Type
				button = $Button
				clickCount = 1
				x = 0
				y = 0
			}
		}
	}
}

class CdpRuntimeCommand {
	static [hashtable]disable($SessionId) {
		return @{
			id = 0
			method = 'Runtime.disable'
			sessionId = $SessionId
		}
	}
	static [hashtable]enable($SessionId) {
		return @{
			id = 0
			method = 'Runtime.enable'
			sessionId = $SessionId
		}
	}
	static [hashtable]evaluate($SessionId, $Expression, [bool]$Await) {
		return @{
			id = 0
			method = 'Runtime.evaluate'
			sessionId = $SessionId
			params = @{
				expression = $Expression
				awaitPromise = $Await
			}
		}
	}
}



function Start-CdpPipeBrowser {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[ValidateScript({ Test-Path $_ -PathType Container })]
		[string]$UserDataDir,
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$BrowserExecutablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
		[string]$Url = 'about:blank',
		[switch]$Headless,
		[switch]$EnableAutomation
	)

	$PipeWriter = [System.IO.Pipes.AnonymousPipeServerStream]::new([System.IO.Pipes.PipeDirection]::Out, [System.IO.HandleInheritability]::Inheritable)
	$PipeReader = [System.IO.Pipes.AnonymousPipeServerStream]::new([System.IO.Pipes.PipeDirection]::In, [System.IO.HandleInheritability]::Inheritable)
	$ReadHandle = $PipeWriter.GetClientHandleAsString();
	$WriteHandle = $PipeReader.GetClientHandleAsString();

	$BrowserArgs = @(
		('--user-data-dir="{0}"' -f $UserDataDir)
		'--no-first-run'
		'--remote-debugging-pipe'
		('--remote-debugging-io-pipes={0},{1}' -f $ReadHandle, $WriteHandle)
		$Url
		if ($Headless) { '--headless' }
		if ($EnableAutomation) { '--enable-automation' }
	) | Where-Object { $_ -ne '' -and $_ -ne $null }

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $BrowserExecutablePath
	$StartInfo.Arguments = $BrowserArgs
	$StartInfo.UseShellExecute = $false

	$ChromeProcess = [System.Diagnostics.Process]::Start($StartInfo)
	$PipeWriter.DisposeLocalCopyOfClientHandle()
	$PipeReader.DisposeLocalCopyOfClientHandle()

	$Browser = [CdpPipeBrowser]::new($PipeWriter, $PipeReader, $ChromeProcess)

	$Command = [CdpTargetCommand]::setDiscoverTargets()
	$Browser.SendCommand($Command)

	$Command = [CdpTargetCommand]::setAutoAttach()
	$Browser.SendCommand($Command)

	$Command = [CdpPageCommand]::enable($Browser.Targets[0].SessionId)
	$Browser.SendCommand($Command)

	$Command = [CdpRuntimeCommand]::enable($Browser.Targets[0].SessionId)
	$Browser.SendCommand($Command)

	$Browser
}

function Stop-CdpPipeBrowser {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[CdpPipeBrowser]$Browser
	)

	$Command = [CdpBrowserCommand]::close()
	$Browser.SendCommand($Command)
	$Browser.CloseBrowser()
}

function New-CdpPage {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[CdpPipeBrowser]$Browser,
		[string]$Url = 'about:blank'
	)
	$Command = [CdpTargetCommand]::createTarget($Url)
	$Browser.SendCommand($Command)

	$NewPage = $Browser.Targets[-1]

	$Command = [CdpPageCommand]::enable($NewPage.SessionId)
	$Browser.SendCommand($Command)

	$Command = [CdpRuntimeCommand]::enable($NewPage.SessionId)
	$Browser.SendCommand($Command)

	$NewPage
}

function Invoke-CdpPageNavigate {
	<#
		.SYNOPSIS
		Navigates and automatically waits for the page to load with LoadEventFired and FrameStoppedLoading
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[CdpPipeBrowser]$Browser,
		[Parameter(Mandatory)]
		[string]$Url,
		[Parameter(Mandatory)]
		[CdpPage]$CdpPage
	)
	$Command = [CdpPageCommand]::navigate($CdpPage.SessionId, $Url)
	$CdpPage.IsNavigating = $true
	$Browser.SendCommand($Command, $CdpPage)

	$Command = [CdpRuntimeCommand]::enable($CdpPage.SessionId)
	$Browser.SendCommand($Command)
}

function Invoke-CdpClickElement {
	<#
		.SYNOPSIS
		Finds and interacts with element
		.PARAMETER Selector
		Javascript that returns ONE node object
		For example:
		document.querySelectorAll('[name=q]')[0]
		.PARAMETER Click
		Number of times to left click the mouse
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[CdpPipeBrowser]$Browser,
		[Parameter(Mandatory)]
		[string]$Selector,
		[Parameter(Mandatory)]
		[CdpPage]$CdpPage,
		[Parameter(ParameterSetName = 'Click')]
		[int]$Click = 0,
		[Parameter(ParameterSetName = 'Click')]
		[int]$CenterOffsetX = 0,
		[Parameter(ParameterSetName = 'Click')]
		[int]$CenterOffsetY = 0
	)

	if ($Click -gt 0) {
		$Command = [CdpRuntimeCommand]::evaluate($CdpPage.SessionId, $Selector, $false)
		$Browser.SendCommand($Command)

		$Command = [CdpDomCommand]::getDocument($CdpPage.SessionId)
		$Browser.SendCommand($Command, $CdpPage)

		if (!$CdpPage.ObjectId) { throw 'selector not found' }

		$Command = [CdpDomCommand]::getBoxModel($CdpPage.SessionId)
		$Command.params.objectId = $CdpPage.ObjectId
		$Browser.SendCommand($Command)

		if ($null -eq $CdpPage.BoxModel -or ($CdpPage.BoxModel.content[0] -eq 0 -and $CdpPage.BoxModel.content[1] -eq 0)) {
			throw 'selector object has no dimensions'
			#Write-Host "X:$($CdpPage.BoxModel.content[0]) Y:$($CdpPage.BoxModel.content[1])" -ForegroundColor DarkBlue
		}

		$Command = [CdpInputCommand]::dispatchMouseEvent($CdpPage.SessionId, 'mousePressed', 'left')
		$Command.params.clickCount = $Click
		$Command.params.X = $CdpPage.BoxModel.content[0] + ($CdpPage.BoxModel.width / 2) + $CenterOffsetX
		$Command.params.Y = $CdpPage.BoxModel.content[1] + ($CdpPage.BoxModel.height / 2) + $CenterOffsetY
		$Browser.SendCommand($Command, $CdpPage)
		$Command.params.type = 'mouseReleased'
		$Browser.SendCommand($Command, $CdpPage)
	}
}

function Invoke-CdpSendKeys {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[CdpPipeBrowser]$Browser,
		[Parameter(Mandatory)]
		[string]$Keys,
		[Parameter(Mandatory)]
		[CdpPage]$CdpPage
	)

	$Keys.ToCharArray() | ForEach-Object {
		$Command = [CdpInputCommand]::dispatchKeyEvent($CdpPage.SessionId, $_)
		$Browser.SendCommand($Command, $CdpPage)
	}
}
