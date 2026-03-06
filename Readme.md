# Powershell Browser Automation

Automate any Chromium browser with Powershell with `--remote-debugging-pipe` and `--remote-debugging-io-pipe`. I still couldn't find any examples in 2026 that made use of these switches with dotnet without tapping into WinApi functions like this amazing repo https://github.com/PerditionC/VBAChromeDevProtocol/

The goal is light browser automation without external dependencies and be a potential step up from VBA. Only a small subset of Cdp commands are implemented.

Currently this is all blocking. Events are only processed after each call to `$Browser.SendCommand()` or `$Browser.ProcessAllResponses()`.

`AnonymousPipeServerStream.Write()` requires a null byte to be sent at the end of the string to signal end of write.

`AnonymousPipeServerStream.Read()` locks the terminal on reading an empty pipe. For a workaround, send a null byte before reading to prevent the terminal from freezing if manually reading from the pipe.`

## Commands

Start-CdpPipeBrowser - Launch browser

Stop-CdpPipeBrowser - Close browser

New-CdpPage - Create new page/tab

Invoke-CdpPageNavigate - Navigate page and waits for page load. (Late loading frames may still be missed.)

Invoke-CdpClickElement - Find element with javascript selector and click element via DOM

Invoke-CdpSendKeys - Sends keys to browser

## Notes

Pages and frames are by default autoattached. The event `Target.targetCreated` creates a new `[CdpPage]` into `$Browser.Targets` when processed.

Some events such as `Target.targetCreated` `Target.attachedToTarget` `Target.detachedFromTarget` `Target.targetInfoChanged` are by default turned on to manage active pages. Only pages are attached. Types such as `service_worker` or `background_page` are excluded by default.

Page events are on by default per tab. Javascript is enabled by default.

## Todo/Considerations

Start the anonymous pipes in another runspace for non blocking reads.

Break up the file into smaller pieces.
