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
$valid = "1/2 embedding_http.test.sendWithDeadline cancels and joins a blocked transport...OK`n2/2 embedding_http.test.StdHttpTransport cancellation closes and joins held HTTP and TLS exchanges...OK`nAll 2 tests passed.`n"
Assert-CancellationEvidence 0 '' $valid
Assert-CancellationEvidence 0 '' $valid.Replace("`n", "`r`n")
foreach ($invalid in @('', 'All 0 tests passed.', 'All 2 tests passed.', $valid.Replace('...OK', '...SKIP'), $valid.Replace('All 2', 'All 1'), "$valid`nextra")) {
	Expect-Rejection { Assert-CancellationEvidence 0 '' $invalid }
}
Expect-Rejection { Assert-CancellationEvidence 42 '' $valid }
Expect-Rejection { Assert-CancellationEvidence 0 'unexpected' $valid }
Write-Output 'Windows architecture, PE corruption, and test evidence controls passed'
