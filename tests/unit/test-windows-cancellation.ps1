param([string] $Amd64Executable, [string] $Arm64Executable, [string] $NativeUnitExecutable)
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
$valid = "1/5 embedding_http.test.sendWithDeadline cancels and joins a blocked transport...OK`n2/5 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP headers...OK`n3/5 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP body...OK`n4/5 embedding_http.test.StdHttpTransport cancellation closes and joins held TLS handshake...OK`n5/5 embedding_http.test.StdHttpTransport send errors close the connection before response headers...OK`nAll 5 tests passed.`n"
Assert-CancellationEvidence 0 '' $valid
Assert-CancellationEvidence 0 '' $valid.Replace("`n", "`r`n")
foreach ($invalid in @('', 'All 0 tests passed.', 'All 5 tests passed.', $valid.Replace('...OK', '...SKIP'), $valid.Replace('All 5', 'All 1'), "$valid`nextra")) {
	Expect-Rejection { Assert-CancellationEvidence 0 '' $invalid }
}
Expect-Rejection { Assert-CancellationEvidence 42 '' $valid }
Expect-Rejection { Assert-CancellationEvidence 0 'unexpected' $valid }

$unitGuard = 'all_tests.test.correctness suite retains runtime safety and allocator leak checks'
$unitValid = "1/3 $unitGuard...OK`n2/3 fixture.test.unavailable...SKIP`n3/3 fixture.test.complete...OK`n2 passed; 1 skipped; 0 failed.`n"
foreach ($transcript in @($unitValid, $unitValid.Replace("`n", "`r`n"))) {
	$counts = ConvertFrom-UnitEvidence 0 '' $transcript
	if ($counts.Passed -ne 2 -or $counts.Skipped -ne 1 -or $counts.Total -ne 3) { throw 'Unit evidence lost the actual counts' }
}
$unitAllPass = $unitValid.Replace('...SKIP', '...OK').Replace('2 passed; 1 skipped; 0 failed.', 'All 3 tests passed.')
$counts = ConvertFrom-UnitEvidence 0 '' $unitAllPass
if ($counts.Passed -ne 3 -or $counts.Skipped -ne 0 -or $counts.Total -ne 3) { throw 'All-pass evidence lost its counts' }
$diagnostics = @{ 'fixture.test.complete' = "controlled SQLite diagnostic`n" }
$unitDiagnostic = $unitValid.Replace('fixture.test.complete...OK', "fixture.test.complete...controlled SQLite diagnostic`nOK")
foreach ($transcript in @($unitDiagnostic, $unitDiagnostic.Replace("`n", "`r`n"))) {
	$counts = ConvertFrom-UnitEvidence 0 '' $transcript $diagnostics
	if ($counts.Transcript -cne $unitValid -or $counts.Passed -ne 2 -or $counts.Skipped -ne 1) { throw 'Expected diagnostics were not asserted and removed from the clean transcript' }
}
foreach ($invalid in @(
	$unitValid,
	$unitDiagnostic.Replace('controlled SQLite diagnostic', 'changed diagnostic'),
	$unitDiagnostic.Replace("diagnostic`nOK", "diagnostic`nextra`nOK"),
	$unitDiagnostic.Replace("diagnostic`nOK", "diagnostic`nSKIP").Replace('2 passed; 1 skipped', '1 passed; 2 skipped'),
	$unitDiagnostic.Replace('fixture.test.complete', 'fixture.test.unknown')
	$unitDiagnostic.Replace('fixture.test.complete', 'FIXTURE.test.complete')
)) { Expect-Rejection { ConvertFrom-UnitEvidence 0 '' $invalid $diagnostics } }
Expect-Rejection { ConvertFrom-UnitEvidence 0 '' $unitDiagnostic }
Expect-Rejection { ConvertFrom-UnitEvidence 0 '' $unitDiagnostic (@{ 'fixture.test.complete' = "controlled SQLite diagnostic`n"; 'fixture.test.stale' = "unused`n" }) }
$missing = $unitValid.Replace("2/3 fixture.test.unavailable...SKIP`n", '')
$duplicate = $unitValid.Replace('3/3 fixture.test.complete', "2/3 fixture.test.unavailable...SKIP`n3/3 fixture.test.complete")
foreach ($invalid in @(
	'', '2 passed; 1 skipped; 0 failed.', $valid, $missing, $duplicate,
	$unitValid.Replace('2/3', '3/3'), $unitValid.Replace('2/3', '2/4'),
	$unitValid.Replace('...OK', '...FAIL'),
	$unitValid.Replace('2 passed', '1 passed'),
	$unitValid.Replace('0 failed', '1 failed'),
	$unitValid.Replace('2 passed', '2147483648 passed'),
	$unitValid.Replace($unitGuard, 'fixture.test.wrong-product'),
	$unitValid.Replace("$unitGuard...OK", "$unitGuard...SKIP").Replace('2 passed; 1 skipped', '1 passed; 2 skipped'),
	"$unitValid`nextra"
)) {
	Expect-Rejection { ConvertFrom-UnitEvidence 0 '' $invalid }
}
Expect-Rejection { ConvertFrom-UnitEvidence 42 '' $unitValid }
Expect-Rejection { ConvertFrom-UnitEvidence 0 'unexpected' $unitValid }
$null = Assert-NativeTestEvidence 'unit' 0 '' $unitValid
Assert-NativeTestEvidence 'cancellation' 0 '' $valid
foreach ($command in @((Get-Command Assert-NativeTestEvidence), (Get-Command "$PSScriptRoot/../../scripts/ci-test-windows.ps1"))) {
	$choices = @($command.Parameters['Suite'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues } | Sort-Object)
	if (($choices -join ',') -cne 'cancellation,unit') { throw 'A native test suite lacks an explicit evidence control' }
}
Expect-Rejection { Assert-NativeTestEvidence 'unit' 0 '' $valid }
Expect-Rejection { Assert-NativeTestEvidence 'cancellation' 0 '' $unitValid }
Expect-Rejection { Assert-NativeTestEvidence 'unknown' 0 '' $unitValid }
$gitEnvironment = @{ PATH = 'ambient-tools'; HOME = 'private-home' }
Set-UnitGitEnvironment $gitEnvironment 'C:/pinned git/cmd' 'C:/private fixture'
if ($gitEnvironment.PATH -cne 'C:/pinned git/cmd' -or $gitEnvironment.HOME -cne 'private-home' -or $gitEnvironment.GIT_CONFIG_NOSYSTEM -cne '1' -or $gitEnvironment.GIT_TERMINAL_PROMPT -cne '0' -or $gitEnvironment.GIT_CONFIG_GLOBAL -cne 'C:/private fixture/gitconfig') { throw 'Git test environment depends on ambient tools or configuration' }

if ($NativeUnitExecutable) {
	$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codescan-unit-evidence-' + [Guid]::NewGuid().ToString('N'))
	$null = New-Item -ItemType Directory -Path $fixture
	$nativeProcess = [Diagnostics.Process]::new()
	$nativeStarted = $false
	try {
		$nativeInfo = [Diagnostics.ProcessStartInfo]::new($NativeUnitExecutable)
		$nativeInfo.WorkingDirectory = $fixture
		$nativeInfo.UseShellExecute = $false
		$nativeInfo.RedirectStandardOutput = $true
		$nativeInfo.RedirectStandardError = $true
		$nativeProcess.StartInfo = $nativeInfo
		$nativeStarted = $nativeProcess.Start()
		if (-not $nativeStarted) { throw 'Native report fixture did not start' }
		$nativeResult = Complete-CancellationProcess $nativeProcess
		if ($nativeResult.TimedOut) { throw 'Native report fixture exceeded its process bound' }
		$expectedDiagnostics = Get-Content -Raw -LiteralPath "$PSScriptRoot/expected-unit-diagnostics.json" | ConvertFrom-Json -AsHashtable
		try { $null = ConvertFrom-UnitEvidence $nativeResult.ExitCode $nativeResult.StandardOutput $nativeResult.StandardError $expectedDiagnostics } catch {
			$rows = $nativeResult.StandardError.Replace("`r`n", "`n").TrimEnd([char[]] "`n").Split("`n")
			$unexpected = @(for ($index = 0; $index -lt $rows.Count - 1; $index++) {
				if ($rows[$index] -notmatch '^[0-9]+/[0-9]+ .+\.\.\.(OK|SKIP)$') { [pscustomobject]@{ Row = $index; Text = $rows[$index] } }
			})
			Write-Output ([pscustomobject]@{ Exit = $nativeResult.ExitCode; Rows = $rows.Count; Footer = $rows[-1]; Unexpected = $unexpected } | ConvertTo-Json -Depth 5 -Compress)
			throw
		}
	} finally {
		if ($nativeStarted -and -not $nativeProcess.HasExited) { $nativeProcess.Kill($true); $null = $nativeProcess.WaitForExit(5000) }
		$nativeProcess.Dispose()
		Remove-Item -LiteralPath $fixture -Recurse -Force
	}
}

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
if (($debugInfo.ArgumentList -join '|') -cne '-pv|-p|4242|-y|C:/symbols with spaces|-c|~* k; qd') { throw 'Debugger must attach noninvasively to the owned PID and use qd, not the ARM64-unsupported detach-on-exit flag' }
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

$unitMatch = [regex]::Match($workflow, '(?m)^      - name: Execute native aggregate unit tests\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<body>(?:          [^\n]*(?:\n|$))+)')
if (-not $unitMatch.Success) { throw 'Missing native aggregate unit workflow body' }
$unitBody = [regex]::Replace($unitMatch.Groups['body'].Value, '(?m)^ {10}', '')
$unitBody = $unitBody.Replace('${{ matrix.arch }}', 'arm64').Replace('./scripts/ci-test-windows.ps1', 'Invoke-RecordedUnit')
function Invoke-RecordedUnit([string] $Suite, [string] $Architecture, [string] $Executable, [string] $GitExecutable) {
	if ($Suite -cne 'unit' -or $Architecture -cne 'arm64' -or $Executable -cne './unit/codescan-unit-tests.exe' -or $GitExecutable -cne './git-tools/cmd/git.exe') { throw 'Wrong native unit request' }
	$script:unitCalls++
	if ($script:unitFails) { throw 'controlled unit failure' }
}
function Assert-UnitWorkflow([string] $Body) {
	foreach ($script:unitFails in @($false, $true)) {
		$script:unitCalls = 0
		$threw = $false
		try { & ([scriptblock]::Create($Body)) | Out-Null } catch {
			if ($_.Exception.Message -cne 'controlled unit failure') { throw }
			$threw = $true
		}
		if ($script:unitCalls -ne 1 -or $threw -ne $script:unitFails) { throw 'Native unit workflow omitted, duplicated, or hid a failure' }
	}
}
Assert-UnitWorkflow $unitBody
Expect-Rejection { Assert-UnitWorkflow '' }
Expect-Rejection { Assert-UnitWorkflow "$unitBody`n$unitBody" }
Expect-Rejection { Assert-UnitWorkflow $unitBody.Replace('-GitExecutable "./git-tools/cmd/git.exe"', '') }
$unitSwallowed = "try { $unitBody } catch {}"
Expect-Rejection { Assert-UnitWorkflow $unitSwallowed }
Write-Output 'Windows architecture, PE corruption, and test evidence controls passed'
