[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-ProcessExitCode {
    if ($null -eq $LASTEXITCODE) { return 0 }
    return [int]$LASTEXITCODE
}

function Invoke-CheckedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$Label
    )

    Write-Output ('Running ' + $Label)
    $output = @(& $PowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath 2>&1)
    $exitCode = Get-ProcessExitCode
    $output | ForEach-Object { Write-Output $_ }
    if ($exitCode -ne 0) {
        $joinedOutput = ($output | Out-String)
        if ($joinedOutput -match '(?i)\bEACCES\b|(?:access denied).*(?:listen|bind|socket)|(?:listen|bind|socket).*(?:access denied)') {
            throw ($Label + ' failed because a loopback socket could not be opened; run the isolated test with the required local permission and inspect for another process using the port.')
        }
        throw ($Label + ' failed with exit code ' + $exitCode + '.')
    }
}

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'scripts\Test.ps1 must run under Windows PowerShell 5.1.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'scripts\Test.ps1 requires 64-bit Windows PowerShell.'
    }

    $root = Split-Path -Parent $PSScriptRoot
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw 'The standard Windows PowerShell executable was not found.'
    }

    $nodeCommand = Get-Command node.exe -ErrorAction Stop
    $nodePath = $nodeCommand.Source
    if (-not $nodePath) { $nodePath = $nodeCommand.Path }
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
        throw 'node.exe was not found on PATH.'
    }

    Push-Location -LiteralPath $root
    try {
        $buildPath = Join-Path $root 'scripts\Build.ps1'
        if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) {
            throw 'scripts\Build.ps1 was not found.'
        }
        Invoke-CheckedPowerShell -PowerShellPath $windowsPowerShell -ScriptPath $buildPath -Label 'scripts\Build.ps1'

        $cjsTests = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.test.cjs' -File | Sort-Object Name)
        if ($cjsTests.Count -eq 0) { throw 'No tests/*.test.cjs files were found.' }
        $nodeArguments = @('--test') + @($cjsTests | ForEach-Object { $_.FullName })
        Write-Output ('Running ' + $cjsTests.Count + ' Node test file(s) with node --test')
        $nodeOutput = @(& $nodePath @nodeArguments 2>&1)
        $nodeExitCode = Get-ProcessExitCode
        $nodeOutput | ForEach-Object { Write-Output $_ }
        if ($nodeExitCode -ne 0) {
            $joinedOutput = ($nodeOutput | Out-String)
            if ($joinedOutput -match '(?i)\bEACCES\b|(?:access denied).*(?:listen|bind|socket)|(?:listen|bind|socket).*(?:access denied)') {
                throw 'Node tests failed because a loopback socket could not be opened; run the isolated test with the required local permission and inspect for another process using the port.'
            }
            throw ('Node tests failed with exit code ' + $nodeExitCode + '.')
        }

        $psTests = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.test.ps1' -File | Sort-Object Name)
        if ($psTests.Count -eq 0) { throw 'No tests/*.test.ps1 files were found.' }
        foreach ($test in $psTests) {
            $relative = $test.FullName.Substring($root.Length).TrimStart('\', '/')
            Invoke-CheckedPowerShell -PowerShellPath $windowsPowerShell -ScriptPath $test.FullName -Label $relative
        }
        Write-Output ('All isolated tests and build checks passed (' + $cjsTests.Count + ' Node file(s), ' + $psTests.Count + ' PowerShell file(s)).')
    } finally {
        Pop-Location
    }
} catch {
    Write-Error $_
    exit 1
}
