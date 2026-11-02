param(
	[ValidateSet('cancellation', 'unit')][string] $Suite = 'cancellation',
	[ValidateSet('amd64', 'arm64')][string] $Architecture,
	[string] $Executable,
	[string] $GitExecutable
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PE offsets and machine values: Microsoft's PE/COFF format specification.
function Get-PeMachine([byte[]] $Bytes) {
	if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) { throw 'Invalid DOS header' }
	$offset = [BitConverter]::ToUInt32($Bytes, 0x3c)
	if ($offset -lt 64 -or $offset -gt $Bytes.Length - 6) { throw 'Invalid PE offset' }
	if ([BitConverter]::ToUInt32($Bytes, $offset) -ne 0x4550) { throw 'Invalid PE signature' }
	return [BitConverter]::ToUInt16($Bytes, $offset + 4)
}

function Assert-NativeTarget([string] $Architecture, [bool] $WindowsHost, [string] $OsArchitecture, [int] $Machine) {
	$machines = @{ amd64 = 0x8664; arm64 = 0xaa64 }
	$osNames = @{ amd64 = 'X64'; arm64 = 'Arm64' }
	if (-not $machines.ContainsKey($Architecture) -or -not $WindowsHost -or $OsArchitecture -cne $osNames[$Architecture] -or $Machine -ne $machines[$Architecture]) {
		throw "Wrong native target: requested=$Architecture Windows=$WindowsHost OS=$OsArchitecture PE=$Machine"
	}
}

function Assert-CancellationEvidence([int] $ExitCode, [string] $StandardOutput, [string] $StandardError) {
	$expected = "1/5 embedding_http.test.sendWithDeadline cancels and joins a blocked transport...OK`n2/5 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP headers...OK`n3/5 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP body...OK`n4/5 embedding_http.test.StdHttpTransport cancellation closes and joins held TLS handshake...OK`n5/5 embedding_http.test.StdHttpTransport send errors close the connection before response headers...OK`nAll 5 tests passed."
	if ($ExitCode -ne 0 -or $StandardOutput -cne '' -or $StandardError.Replace("`r`n", "`n").TrimEnd([char[]] "`n") -cne $expected) {
		throw "Cancellation evidence failed: exit=$ExitCode; require all five passing cases"
	}
}

function ConvertFrom-UnitEvidence([int] $ExitCode, [string] $StandardOutput, [string] $StandardError, [Collections.IDictionary] $ExpectedDiagnostics = @{}) {
	if ($ExitCode -ne 0 -or $StandardOutput -cne '') { throw 'Aggregate unit process failed or wrote unexpected stdout' }
	$text = $StandardError.Replace("`r`n", "`n").TrimEnd([char[]] "`n")
	$footerOffset = $text.LastIndexOf("`n")
	if ($footerOffset -lt 0) { throw 'Missing aggregate unit progress' }
	$footer = $text.Substring($footerOffset + 1)
	$progress = $text.Substring(0, $footerOffset + 1)
	$summary = [regex]::Match($footer, '^([0-9]+) passed; ([0-9]+) skipped; 0 failed\.$')
	if ($summary.Success) {
		$passed = [int]::Parse($summary.Groups[1].Value)
		$skipped = [int]::Parse($summary.Groups[2].Value)
	} else {
		$summary = [regex]::Match($footer, '^All ([0-9]+) tests passed\.$')
		if (-not $summary.Success) { throw 'Missing successful aggregate unit summary' }
		$passed = [int]::Parse($summary.Groups[1].Value)
		$skipped = 0
	}
	$total = [long] $passed + [long] $skipped
	if ($passed -le 0 -or $total -gt $progress.Length) { throw 'Aggregate unit progress is incomplete' }
	$observedPassed = 0
	$observedSkipped = 0
	$guardPassed = 0
	$cursor = 0
	$seenDiagnostics = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$clean = [Text.StringBuilder]::new()
	$prefix = [regex]::new('\G([0-9]+)/([0-9]+) ([^\n]+?)\.\.\.')
	$status = [regex]::new('\G(OK|SKIP)\n')
	for ($index = 0; $index -lt $total; $index++) {
		$entry = $prefix.Match($progress, $cursor)
		if (-not $entry.Success -or [int]::Parse($entry.Groups[1].Value) -ne $index + 1 -or [int]::Parse($entry.Groups[2].Value) -ne $total) {
			throw 'Invalid aggregate unit progress sequence'
		}
		$cursor += $entry.Length
		$name = $entry.Groups[3].Value
		$hasDiagnostic = $ExpectedDiagnostics.Contains($name)
		if ($hasDiagnostic) {
			$diagnostic = [string] $ExpectedDiagnostics[$name]
			if (-not $diagnostic -or $cursor + $diagnostic.Length -gt $progress.Length -or [string]::CompareOrdinal($progress, $cursor, $diagnostic, 0, $diagnostic.Length) -ne 0 -or -not $seenDiagnostics.Add($name)) { throw 'Expected unit diagnostic is missing, changed, or duplicated' }
			$cursor += $diagnostic.Length
		}
		$outcome = $status.Match($progress, $cursor)
		if (-not $outcome.Success -or ($hasDiagnostic -and $outcome.Groups[1].Value -cne 'OK')) { throw 'Unexpected unit output or skipped diagnostic fixture' }
		$cursor += $outcome.Length
		$null = $clean.Append($entry.Value).Append($outcome.Value)
		if ($outcome.Groups[1].Value -ceq 'OK') {
			$observedPassed++
			if ($name -ceq 'all_tests.test.correctness suite retains runtime safety and allocator leak checks') { $guardPassed++ }
		} else { $observedSkipped++ }
	}
	foreach ($expectedName in $ExpectedDiagnostics.Keys) {
		if (-not $seenDiagnostics.Contains($expectedName)) { throw 'Expected diagnostic fixture was not exercised with its exact name' }
	}
	if ($cursor -ne $progress.Length -or $observedPassed -ne $passed -or $observedSkipped -ne $skipped -or $guardPassed -ne 1) { throw 'Aggregate unit counts, diagnostics, or runtime-safety guard do not match' }
	$null = $clean.Append($footer).Append("`n")
	return [pscustomobject]@{ Passed = $passed; Skipped = $skipped; Total = $total; Transcript = $clean.ToString() }
}

function Assert-NativeTestEvidence([ValidateSet('cancellation', 'unit')][string] $Suite, [int] $ExitCode, [string] $StandardOutput, [string] $StandardError, [Collections.IDictionary] $ExpectedDiagnostics = @{}) {
	if ($Suite -ceq 'unit') { return ConvertFrom-UnitEvidence $ExitCode $StandardOutput $StandardError $ExpectedDiagnostics }
	else { Assert-CancellationEvidence $ExitCode $StandardOutput $StandardError }
}

function Set-UnitGitEnvironment($Environment, [string] $GitDirectory, [string] $PrivateRoot) {
	$Environment['PATH'] = $GitDirectory
	$Environment['GIT_CONFIG_NOSYSTEM'] = '1'
	$Environment['GIT_CONFIG_GLOBAL'] = "$PrivateRoot/gitconfig"
	$Environment['GIT_TERMINAL_PROMPT'] = '0'
}

function Complete-CancellationProcess($Process, [scriptblock] $TimeoutDiagnostics, [int] $WaitMilliseconds = 30000, [int] $ReapMilliseconds = 5000) {
	$stdoutTask = $Process.StandardOutput.ReadToEndAsync()
	$stderrTask = $Process.StandardError.ReadToEndAsync()
	$timedOut = -not $Process.WaitForExit($WaitMilliseconds)
	$diagnostics = ''
	if ($timedOut) {
		if ($TimeoutDiagnostics) {
			try { $diagnostics = & $TimeoutDiagnostics $Process } catch { $diagnostics = "Stack capture failed: $($_.Exception.Message)" }
		}
		try { $Process.Kill($true) } catch {
			# Exiting during stack capture must retain the timeout verdict and
			# buffered evidence, not replace them with an already-exited error.
			if (-not $Process.HasExited) { throw }
		}
		if (-not $Process.WaitForExit($ReapMilliseconds)) { throw 'Cancellation process tree did not exit after termination' }
	}
	return [pscustomobject]@{
		TimedOut = $timedOut
		Diagnostics = $diagnostics
		ExitCode = $Process.ExitCode
		StandardOutput = $stdoutTask.GetAwaiter().GetResult()
		StandardError = $stderrTask.GetAwaiter().GetResult()
	}
}

function New-CdbStartInfo([string] $Debugger, [int] $TargetId, [string] $Symbols, [string] $WorkDirectory) {
	$info = [Diagnostics.ProcessStartInfo]::new($Debugger)
	$info.UseShellExecute = $false
	$info.RedirectStandardOutput = $true
	$info.RedirectStandardError = $true
	$info.WorkingDirectory = $WorkDirectory
	$info.Environment.Clear()
	foreach ($name in @('SystemRoot', 'WINDIR', 'SystemDrive')) {
		$value = [Environment]::GetEnvironmentVariable($name)
		if ($value) { $info.Environment[$name] = $value }
	}
	$info.Environment['_NT_SYMBOL_PATH'] = $Symbols
	$info.Environment['_NT_ALT_SYMBOL_PATH'] = ''
	$info.Environment['DBGHELP_HOMEDIR'] = $WorkDirectory
	foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR')) { $info.Environment[$name] = $WorkDirectory }
	foreach ($argument in @('-pv', '-p', [string] $TargetId, '-y', $Symbols, '-c', '~* k; qd')) { $info.ArgumentList.Add($argument) }
	return $info
}

function Complete-StackCapture($Process) {
	# SDK startup/attachment has its own failure-only budget. This cannot
	# change the cancellation process's already-recorded timeout verdict.
	return Complete-CancellationProcess $Process -WaitMilliseconds 10000 -ReapMilliseconds 1000
}

function Get-CancellationStacks([int] $TargetId, [string] $Architecture, [string] $Symbols, [string] $WorkDirectory, [string] $PdbName = 'codescan-cancellation-tests.pdb') {
	$debugArchitecture = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
	$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
	$debugger = Join-Path $programFiles "Windows Kits/10/Debuggers/$debugArchitecture/cdb.exe"
	if (-not (Test-Path -LiteralPath $debugger -PathType Leaf)) { return "Stack capture unavailable: missing SDK debugger $debugger" }
	if (-not (Test-Path -LiteralPath (Join-Path $Symbols $PdbName) -PathType Leaf)) { return 'Stack capture unavailable: missing matching PDB' }
	$debugProcess = [Diagnostics.Process]::new()
	$debugStarted = $false
	try {
		$debugProcess.StartInfo = New-CdbStartInfo $debugger $TargetId $Symbols $WorkDirectory
		$debugStarted = $debugProcess.Start()
		if (-not $debugStarted) { throw 'SDK debugger did not start' }
		$trace = Complete-StackCapture $debugProcess
		return "SDK stack capture: exit=$($trace.ExitCode) timedOut=$($trace.TimedOut)`n$($trace.StandardOutput)`n$($trace.StandardError)"
	} finally {
		if ($debugStarted -and -not $debugProcess.HasExited) { $debugProcess.Kill($true); $null = $debugProcess.WaitForExit(500) }
		$debugProcess.Dispose()
	}
}

# Dot-sourcing exposes the pure controls without launching any process.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or -not $env:RUNNER_TEMP) {
	throw 'Native execution requires a disposable Windows CI runner'
}
$binary = Get-Item -LiteralPath $Executable
if ($binary.PSIsContainer -or ($binary.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Require a regular executable' }
$osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$machine = Get-PeMachine ([IO.File]::ReadAllBytes($binary.FullName))
Assert-NativeTarget $Architecture $IsWindows $osArchitecture $machine
if ($Suite -ceq 'unit') {
	$gitBinary = Get-Item -LiteralPath $GitExecutable
	if ($gitBinary.PSIsContainer -or ($gitBinary.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Require a regular pinned Git executable' }
	Assert-NativeTarget $Architecture $IsWindows $osArchitecture (Get-PeMachine ([IO.File]::ReadAllBytes($gitBinary.FullName)))
	Write-Output "Native Windows unit runner: OS=$osArchitecture; PF=mswin-$Architecture; PE=$machine"
}
else { Write-Output "Native Windows runner: OS=$osArchitecture; PF=mswin-$Architecture; PE=$machine" }

$fixture = Join-Path $env:RUNNER_TEMP ("codescan-$Suite-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$process = [Diagnostics.Process]::new()
$started = $false
try {
	$start = [Diagnostics.ProcessStartInfo]::new($binary.FullName)
	$start.WorkingDirectory = $fixture
	$start.UseShellExecute = $false
	$start.RedirectStandardOutput = $true
	$start.RedirectStandardError = $true
	$start.Environment.Clear()
	$start.Environment['OLLAMA_URL'] = 'http://127.0.0.1:1'
	foreach ($name in @('SystemRoot', 'WINDIR', 'SystemDrive')) {
		$value = [Environment]::GetEnvironmentVariable($name)
		if ($value) { $start.Environment[$name] = $value }
	}
	foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR')) {
		$path = Join-Path $fixture $name
		$null = New-Item -ItemType Directory -Path $path
		$start.Environment[$name] = $path
	}
	if ($Suite -ceq 'unit') { Set-UnitGitEnvironment $start.Environment $gitBinary.DirectoryName $fixture }
	$process.StartInfo = $start
	$started = $process.Start()
	if (-not $started) { throw "Native $Suite process did not start" }
	$result = Complete-CancellationProcess $process -ReapMilliseconds 3000 -TimeoutDiagnostics {
		param($Target)
		Get-CancellationStacks $Target.Id $Architecture $binary.DirectoryName $fixture ($binary.BaseName + '.pdb')
	}
	if ($result.Diagnostics) { Write-Output $result.Diagnostics }
	try {
		if ($result.TimedOut) { throw "Native $Suite process exceeded 30 seconds; buffered test progress follows" }
		$expectedDiagnostics = if ($Suite -ceq 'unit') { Get-Content -Raw -LiteralPath "$PSScriptRoot/../tests/unit/expected-unit-diagnostics.json" | ConvertFrom-Json -AsHashtable } else { @{} }
		$evidence = Assert-NativeTestEvidence $Suite $result.ExitCode $result.StandardOutput $result.StandardError $expectedDiagnostics
	} catch {
		Write-Output $result.StandardOutput
		Write-Output $result.StandardError
		throw
	}
	if ($Suite -ceq 'unit') { Write-Output $evidence.Transcript }
	else { Write-Output $result.StandardError }
} finally {
	try {
		if ($started -and -not $process.HasExited) {
			$process.Kill($true)
			if (-not $process.WaitForExit(5000)) { throw 'Cancellation process tree did not exit after termination' }
		}
	} finally {
		$process.Dispose()
		Remove-Item -LiteralPath $fixture -Recurse -Force
	}
}
