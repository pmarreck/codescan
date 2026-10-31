param([string] $Amd64Executable, [string] $Arm64Executable)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../scripts/ci-test-windows.ps1"

function Expect-Rejection([scriptblock] $Operation) {
	try { & $Operation } catch { return }
	throw 'Expected rejection, but the operation succeeded'
}

$machines = @{ amd64 = 0x8664; arm64 = 0xaa64 }
$osNames = @{ amd64 = 'X64'; arm64 = 'Arm64' }
$executables = @{ amd64 = $Amd64Executable; arm64 = $Arm64Executable }
foreach ($architecture in @('amd64', 'arm64')) {
	if ($executables[$architecture]) {
		if ((Get-PeMachine ([IO.File]::ReadAllBytes($executables[$architecture]))) -ne $machines[$architecture]) { throw 'Real PE machine mismatch' }
	}
	$bytes = [byte[]]::new(128)
	$bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[0x3c] = 0x40
	$bytes[0x40] = 0x50; $bytes[0x41] = 0x45
	$bytes[0x44] = $machines[$architecture] -band 0xff
	$bytes[0x45] = $machines[$architecture] -shr 8
	if ((Get-PeMachine $bytes) -ne $machines[$architecture]) { throw 'Wrong PE machine' }
	foreach ($os in @('X64', 'Arm64', 'X86', 'Unknown')) {
		foreach ($windowsHost in @($true, $false)) {
			foreach ($machine in @(0x8664, 0xaa64, 0xa641, 0)) {
				if ($windowsHost -and $os -eq $osNames[$architecture] -and $machine -eq $machines[$architecture]) {
					Assert-NativeTarget $architecture $windowsHost $os $machine
				} else {
					Expect-Rejection { Assert-NativeTarget $architecture $windowsHost $os $machine }
				}
			}
		}
	}
	foreach ($corruption in @('dos', 'signature', 'offset', 'truncated')) {
		$bad = $bytes.Clone()
		switch ($corruption) {
			dos { $bad[0] = 0 }
			signature { $bad[0x41] = 0 }
			offset { $bad[0x3c] = 0xff; $bad[0x3f] = 0xff }
			truncated { $bad = [byte[]]::new(2) }
		}
		Expect-Rejection { Get-PeMachine $bad }
	}
}
$valid = "1/4 embedding_http.test.sendWithDeadline cancels and joins a blocked transport...OK`n2/4 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP headers...OK`n3/4 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP body...OK`n4/4 embedding_http.test.StdHttpTransport cancellation closes and joins held TLS handshake...OK`nAll 4 tests passed.`n"
Assert-CancellationEvidence 0 '' $valid
Assert-CancellationEvidence 0 '' $valid.Replace("`n", "`r`n")
foreach ($invalid in @('', 'All 0 tests passed.', 'All 4 tests passed.', $valid.Replace('...OK', '...SKIP'), $valid.Replace('All 4', 'All 1'), "$valid`nextra")) {
	Expect-Rejection { Assert-CancellationEvidence 0 '' $invalid }
}
Expect-Rejection { Assert-CancellationEvidence 42 '' $valid }
Expect-Rejection { Assert-CancellationEvidence 0 'unexpected' $valid }

# Process ports make timeout/reaping behavior deterministic without sleeps or
# launching a child. Completed tasks model buffered output available at EOF.
foreach ($scenario in @('completed', 'timeout', 'reap-failure', 'diagnostic', 'diagnostic-failure', 'diagnostic-exit', 'debugger-timeout')) {
	$events = [Collections.Generic.List[string]]::new()
	$streams = @()
	foreach ($label in @('stdout', 'stderr')) {
		$stream = [pscustomobject]@{ Events = $events; Label = $label }
		$stream | Add-Member ScriptMethod ReadToEndAsync {
			$this.Events.Add("read:$($this.Label)")
			return [Threading.Tasks.Task]::FromResult([string] "buffered-$($this.Label)")
		}
		$streams += $stream
	}
	$processPort = [pscustomobject]@{
		Events = $events; Completes = ($scenario -eq 'completed'); Reaps = ($scenario -ne 'reap-failure')
		StandardOutput = $streams[0]; StandardError = $streams[1]; ExitCode = 42
		HasExited = ($scenario -eq 'completed'); ExitsDuringKill = ($scenario -eq 'diagnostic-exit')
		ExpectedWait = $(if ($scenario -eq 'debugger-timeout') { 10000 } else { 30000 })
		ExpectedReap = $(if ($scenario -eq 'debugger-timeout') { 1000 } elseif ($scenario -like 'diagnostic*') { 3000 } else { 5000 })
	}
	$processPort | Add-Member ScriptMethod WaitForExit {
		param([int] $Milliseconds)
		$this.Events.Add("wait:$Milliseconds")
		if ($Milliseconds -eq $this.ExpectedWait) { return $this.Completes }
		if ($Milliseconds -eq $this.ExpectedReap) { return $this.Reaps }
		throw 'Unexpected process bound'
	}
	$processPort | Add-Member ScriptMethod Kill {
		param([bool] $EntireTree)
		$this.Events.Add("kill:$EntireTree")
		if ($this.ExitsDuringKill) { $this.HasExited = $true; throw 'process already exited' }
	}
	if ($scenario -eq 'reap-failure') {
		Expect-Rejection { Complete-CancellationProcess $processPort }
	} else {
		if ($scenario -like 'diagnostic*') {
			$processPort | Add-Member NoteProperty DiagnosticFails ($scenario -eq 'diagnostic-failure')
			$result = Complete-CancellationProcess $processPort -ReapMilliseconds 3000 -TimeoutDiagnostics {
				param($Target)
				$Target.Events.Add('diagnostic')
				if ($Target.DiagnosticFails) { throw 'controlled stack capture failure' }
				return 'captured stack'
			}
			if ($scenario -eq 'diagnostic' -and $result.Diagnostics -cne 'captured stack') { throw 'Lost stack capture' }
			if ($scenario -eq 'diagnostic-failure' -and $result.Diagnostics -notlike '*controlled stack capture failure*') { throw 'Lost stack failure diagnostic' }
		} elseif ($scenario -eq 'debugger-timeout') { $result = Complete-StackCapture $processPort }
		else { $result = Complete-CancellationProcess $processPort }
		if ($result.StandardOutput -cne 'buffered-stdout' -or $result.StandardError -cne 'buffered-stderr' -or $result.ExitCode -ne 42 -or $result.TimedOut -ne ($scenario -ne 'completed')) { throw 'Process completion lost buffered evidence or status' }
	}
	$expectedEvents = "read:stdout;read:stderr;wait:$($processPort.ExpectedWait)"
	if ($scenario -like 'diagnostic*') { $expectedEvents += ';diagnostic;kill:True;wait:3000' }
	elseif ($scenario -eq 'debugger-timeout') { $expectedEvents += ';kill:True;wait:1000' }
	elseif ($scenario -ne 'completed') { $expectedEvents += ';kill:True;wait:5000' }
	if (($events -join ';') -cne $expectedEvents) { throw 'Process completion changed the bound or reap ordering' }
}
$debugInfo = New-CdbStartInfo 'C:/debugger/cdb.exe' 4242 'C:/symbols with spaces' 'C:/private scratch'
if ($debugInfo.FileName -cne 'C:/debugger/cdb.exe' -or $debugInfo.WorkingDirectory -cne 'C:/private scratch' -or $debugInfo.UseShellExecute -or -not $debugInfo.RedirectStandardOutput -or -not $debugInfo.RedirectStandardError) { throw 'Wrong debugger process setup' }
if (($debugInfo.ArgumentList -join '|') -cne '-pv|-pd|-p|4242|-y|C:/symbols with spaces|-c|~* k; qd') { throw 'Debugger must attach only to the owned PID, capture all stacks, and detach' }
if ($debugInfo.Environment['_NT_SYMBOL_PATH'] -cne 'C:/symbols with spaces' -or $debugInfo.Environment['DBGHELP_HOMEDIR'] -cne 'C:/private scratch') { throw 'Debugger state escaped private paths' }
if ($debugInfo.Environment['TEMP'] -cne 'C:/private scratch' -or $debugInfo.Environment['USERPROFILE'] -cne 'C:/private scratch') { throw 'Debugger temporary/user state is not private' }

# Execute the workflow's actual loop with a recorded request port. One failed
# process must abort the fixed campaign, not be retried until a later pass.
$workflow = [IO.File]::ReadAllText("$PSScriptRoot/../../.github/workflows/native-windows.yml")
$match = [regex]::Match($workflow, '(?m)^      - name: Execute native cancellation tests\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<body>(?:          [^\n]*(?:\n|$))+)')
if (-not $match.Success) { throw 'Missing bounded native workflow body' }
$body = [regex]::Replace($match.Groups['body'].Value, '(?m)^ {10}', '')
$body = $body.Replace('${{ matrix.arch }}', 'arm64').Replace('./scripts/ci-test-windows.ps1', 'Invoke-RecordedCancellation')
function Invoke-RecordedCancellation([string] $Architecture, [string] $Executable) {
	if ($Architecture -cne 'arm64' -or $Executable -cne './cancellation/codescan-cancellation-tests.exe') { throw 'Wrong native request' }
	$script:iterationCalls++
	if ($script:iterationCalls -eq $script:failIteration) { throw 'controlled cancellation failure' }
}
function Assert-IterationCampaign([string] $Body) {
	foreach ($script:failIteration in @(0, 1, 10, 20)) {
		$script:iterationCalls = 0
		$threw = $false
		try { & ([scriptblock]::Create($Body)) | Out-Null } catch {
			if ($_.Exception.Message -cne 'controlled cancellation failure') { throw }
			$threw = $true
		}
		$expectedCalls = if ($script:failIteration -eq 0) { 20 } else { $script:failIteration }
		if ($script:iterationCalls -ne $expectedCalls -or $threw -ne ($script:failIteration -ne 0)) { throw 'Campaign skipped requests or hid the first failure' }
	}
}
Assert-IterationCampaign $body
Expect-Rejection { Assert-IterationCampaign $body.Replace('1..20', '1..1') }
$swallowed = $body.Replace('Invoke-RecordedCancellation -Architecture "arm64" -Executable "./cancellation/codescan-cancellation-tests.exe"', 'try { Invoke-RecordedCancellation -Architecture "arm64" -Executable "./cancellation/codescan-cancellation-tests.exe" } catch {}')
Expect-Rejection { Assert-IterationCampaign $swallowed }
Write-Output 'Windows architecture, PE corruption, and test evidence controls passed'
