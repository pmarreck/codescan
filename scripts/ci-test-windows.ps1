param(
	[ValidateSet('amd64', 'arm64')][string] $Architecture,
	[string] $Executable
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
	$expected = "1/4 embedding_http.test.sendWithDeadline cancels and joins a blocked transport...OK`n2/4 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP headers...OK`n3/4 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP body...OK`n4/4 embedding_http.test.StdHttpTransport cancellation closes and joins held TLS handshake...OK`nAll 4 tests passed."
	if ($ExitCode -ne 0 -or $StandardOutput -cne '' -or $StandardError.Replace("`r`n", "`n").TrimEnd([char[]] "`n") -cne $expected) {
		throw "Cancellation evidence failed: exit=$ExitCode; require all four passing cases"
	}
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

function Get-CancellationStacks([int] $TargetId, [string] $Architecture, [string] $Symbols, [string] $WorkDirectory) {
	$debugArchitecture = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
	$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
	$debugger = Join-Path $programFiles "Windows Kits/10/Debuggers/$debugArchitecture/cdb.exe"
	if (-not (Test-Path -LiteralPath $debugger -PathType Leaf)) { return "Stack capture unavailable: missing SDK debugger $debugger" }
	if (-not (Test-Path -LiteralPath (Join-Path $Symbols 'codescan-cancellation-tests.pdb') -PathType Leaf)) { return 'Stack capture unavailable: missing matching PDB' }
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
Write-Output "Native Windows runner: OS=$osArchitecture; PF=mswin-$Architecture; PE=$machine"

$fixture = Join-Path $env:RUNNER_TEMP ("codescan-cancellation-" + [Guid]::NewGuid().ToString('N'))
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
	foreach ($name in @('SystemRoot', 'WINDIR', 'SystemDrive')) {
		$value = [Environment]::GetEnvironmentVariable($name)
		if ($value) { $start.Environment[$name] = $value }
	}
	foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR')) {
		$path = Join-Path $fixture $name
		$null = New-Item -ItemType Directory -Path $path
		$start.Environment[$name] = $path
	}
	$process.StartInfo = $start
	$started = $process.Start()
	if (-not $started) { throw 'Cancellation process did not start' }
	$result = Complete-CancellationProcess $process -ReapMilliseconds 3000 -TimeoutDiagnostics {
		param($Target)
		Get-CancellationStacks $Target.Id $Architecture $binary.DirectoryName $fixture
	}
	if ($result.Diagnostics) { Write-Output $result.Diagnostics }
	Write-Output $result.StandardOutput
	Write-Output $result.StandardError
	if ($result.TimedOut) { throw 'Cancellation process exceeded 30 seconds; buffered test progress is shown above' }
	Assert-CancellationEvidence $result.ExitCode $result.StandardOutput $result.StandardError
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
