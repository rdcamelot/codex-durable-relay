[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'

function ConvertTo-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPath = [IO.Path]::GetFullPath($script:RootPath)
    if ($fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($rootPath.Length).TrimStart('\', '/') -replace '\\', '/'
    }
    return $fullPath -replace '\\', '/'
}

function Add-Issue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $script:Issues += [pscustomobject]@{ Path = $Path; Category = $Category }
}

try {
    if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
    $script:RootPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path)
    $script:Issues = @()
    $allowedRootNames = @('README.md', 'SECURITY.md', 'LICENSE', '.gitignore', '.gitattributes')
    $allowedSourceNames = @(
        'codex-durable-relay.cjs', 'CodexRelayLifecycle.cs', 'Install-CodexRelay.ps1',
        'Launch-ManagedRelay.ps1', 'Manage-CodexRelay.ps1', 'managed-hosts-lib.ps1',
        'managed-relay-hosts.ps1', 'managed-relay.cjs', 'relay-log.cjs', 'Shutdown-CodexRelay.ps1'
    )
    $allowedScriptNames = @('Build.ps1', 'Check-PublicFiles.ps1', 'Control.ps1', 'Install.ps1', 'Test.ps1')
    $allowedTestNames = @('install-transaction.test.ps1','uninstall-transaction.test.ps1','helper-parent.test.ps1','lifecycle-cleanup.test.ps1','managed-helper-entry.test.ps1','managed-hosts.test.ps1','managed-status.test.ps1','managed-relay.test.cjs','proxy-settings.test.cjs','relay-log.test.cjs','relay-validation.test.cjs','relay.test.cjs')
    $excludedDirectoryNames = @('.git', 'dist', 'build')
    $forbiddenExtensions = @('.exe', '.dll', '.pdb', '.log', '.jsonl', '.bin', '.tmp', '.flag', '.backup', '.bak', '.dmp', '.sqlite', '.sqlite3', '.db', '.zip')
    $forbiddenNames = @('settings.json', 'status.json', 'stop.json')

    $privatePathPattern = '(?i)(?:[A-Z]:[\\/]+Users[\\/]+(?!(?:user(?:name)?|fixture|example|test|\u7528\u6237|<[^>]+>)(?:[\\/]|[\s"''<>|]|$))[^\\/\s"''<>|]+|[A-Z]:[\\/]+Documents and Settings[\\/]+(?!(?:user(?:name)?|fixture|example|test|\u7528\u6237|<[^>]+>)(?:[\\/]|[\s"''<>|]|$))[^\\/\s"''<>|]+|(?-i:[A-Z]):[\\/]+(?!(?:Windows|Program Files(?: \(x86\))?|ProgramData|Users|Documents and Settings)(?:[\\/]|$))[^\\/\s"''<>|]+[\\/]+[^\\/\s"''<>|]+|(?:^|[\s"''=:(])/(?:Users|home|root)/(?!user(?:name)?|fixture|example|test|<[^>]+>)[^\s"''<>]+)'
    $privateSidPattern = '(?i)\bS-1-5-21-(?!111-222-333-(?:1001|9999)\b)\d+-\d+-\d+-\d+\b'
    $literalSessionPattern = '(?i)\b(?:session[_-]?id|sessionid)\b\s*(?:["'']\s*)?(?:[:=]|-)\s*["'']?\d{3,}\b'
    $literalUuidPattern = '(?i)\b(?!00000000-0000-0000-0000-000000000000\b)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    $literalThreadIdPattern = '(?i)\b(?:thread|conversation|request|trace|correlation)[_-]?id\b\s*[:=]\s*["'']?(?!<[^>]+>|(?:example|placeholder|redacted|dummy|test|fixture)\b)[A-Za-z0-9_-]{8,}'
    $credentialPatterns = @(
        [pscustomobject]@{ Category = 'credential_private_key'; Pattern = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' },
        [pscustomobject]@{ Category = 'credential_cloud_key'; Pattern = '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b' },
        [pscustomobject]@{ Category = 'credential_provider_token'; Pattern = '\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|xox[baprs]-[A-Za-z0-9-]+)\b' },
        [pscustomobject]@{ Category = 'credential_bearer'; Pattern = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}' },
        [pscustomobject]@{ Category = 'credential_url'; Pattern = '(?i)https?://[^\s/@:]+:[^\s/@]+@' },
        [pscustomobject]@{ Category = 'credential_assignment'; Pattern = '(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*["'']?(?!<[^>]+>|(?:change(?:me)?|example|placeholder|redacted|dummy|test)\b)[A-Za-z0-9+/_.=-]{8,}' }
    )

    $allFiles = @(Get-ChildItem -LiteralPath $script:RootPath -Recurse -File -Force | Where-Object {
        $relative = ConvertTo-RelativePath $_.FullName
        $parts = $relative -split '/'
        $excludedDirectoryNames -notcontains $parts[0]
    })
    if (Test-Path -LiteralPath (Join-Path $script:RootPath '.git')) {
        Write-Output 'Git metadata found; scanning the working tree against the public-file allowlist.'
        try {
            $gitCommand = Get-Command git.exe -ErrorAction Stop
            $gitPath = $gitCommand.Source
            if (-not $gitPath) { $gitPath = $gitCommand.Path }
            $trackedPaths = @(& $gitPath -C $script:RootPath ls-files --cached -- 2>&1)
            $trackedExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
            if ($trackedExitCode -ne 0) { throw 'git ls-files could not read the index.' }
            foreach ($trackedPath in $trackedPaths) {
                $gitRelative = ([string]$trackedPath).Trim() -replace '\\', '/'
                if (-not $gitRelative) { continue }
                $gitParts = $gitRelative -split '/'
                if ($gitParts[0] -in @('dist', 'build')) {
                    Add-Issue -Path $gitRelative -Category 'tracked_generated_output'
                }
            }
            $ignoredPaths = @(& $gitPath -C $script:RootPath ls-files --others --ignored --exclude-standard -- 2>&1)
            $ignoredExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
            if ($ignoredExitCode -ne 0) { throw 'git ls-files could not read ignored paths.' }
            foreach ($ignoredPath in $ignoredPaths) {
                $gitRelative = ([string]$ignoredPath).Trim() -replace '\\', '/'
                if (-not $gitRelative) { continue }
                $gitParts = $gitRelative -split '/'
                if ($gitParts[0] -in @('dist', 'build')) { continue }
                $extension = [IO.Path]::GetExtension($gitRelative).ToLowerInvariant()
                $leafName = [IO.Path]::GetFileName($gitRelative).ToLowerInvariant()
                $isRuntimeArtifact = ($forbiddenExtensions -contains $extension) -or ($forbiddenNames -contains $leafName) -or ($leafName -match '(?i)(?:-result|-status)\.json$')
                if ($isRuntimeArtifact -and -not @($script:Issues | Where-Object { $_.Path -ieq $gitRelative }).Count) {
                    Add-Issue -Path $gitRelative -Category 'ignored_runtime_artifact'
                }
            }
        } catch {
            Add-Issue -Path '.git' -Category 'git_index_unavailable'
        }
    } else {
        Write-Output 'No Git metadata found; scanning allowlisted source directories and explicit root files.'
    }

    foreach ($file in $allFiles) {
        $relative = ConvertTo-RelativePath $file.FullName
        $relativeLower = $relative.ToLowerInvariant()
        $parts = $relative -split '/'
        $rootName = $parts[0]
        $isAllowed = $false
        if ($parts.Count -eq 1) {
            $isAllowed = ($allowedRootNames -contains $rootName) -or ($rootName -in @('package.json','package-lock.json'))
        } elseif ($parts.Count -eq 2 -and $parts[0] -ieq 'src') {
            $isAllowed = $allowedSourceNames -contains $parts[1]
        } elseif ($parts.Count -eq 2 -and $parts[0] -ieq 'scripts') {
            $isAllowed = $allowedScriptNames -contains $parts[1]
        } elseif ($parts.Count -eq 2 -and $parts[0] -ieq 'tests') {
            $isAllowed = $allowedTestNames -contains $parts[1]
        } elseif ($parts.Count -eq 2 -and $parts[0] -ieq 'docs') {
            $isAllowed = $parts[1] -in @('OPERATIONS.md','TESTING.md')
        } elseif ($parts.Count -eq 3 -and $parts[0] -ieq '.github' -and $parts[1] -ieq 'workflows') {
            $isAllowed = $parts[2] -eq 'check.yml'
        }
        if (-not $isAllowed) {
            Add-Issue -Path $relative -Category 'unrecognized_file'
            continue
        }

        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Add-Issue -Path $relative -Category 'reparse_point'
            continue
        }
        if (($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) -or ($forbiddenNames -contains $file.Name.ToLowerInvariant()) -or ($file.Name -match '(?i)(?:-result|-status)\.json$')) {
            Add-Issue -Path $relative -Category 'runtime_artifact'
            continue
        }

        try {
            $content = [IO.File]::ReadAllText($file.FullName)
        } catch {
            Add-Issue -Path $relative -Category 'unreadable_file'
            continue
        }
        if ($content -match $privatePathPattern) {
            Add-Issue -Path $relative -Category 'private_path'
        }
        if ($content -match $privateSidPattern) {
            Add-Issue -Path $relative -Category 'private_sid'
        }
        if ($content -match $literalSessionPattern) {
            Add-Issue -Path $relative -Category 'literal_session_id'
        }
        if ($content -match $literalUuidPattern) {
            Add-Issue -Path $relative -Category 'literal_uuid'
        }
        if ($content -match $literalThreadIdPattern) {
            Add-Issue -Path $relative -Category 'literal_thread_id'
        }
        foreach ($credential in $credentialPatterns) {
            if ($content -match $credential.Pattern) {
                Add-Issue -Path $relative -Category $credential.Category
            }
        }
    }

    if ($script:Issues.Count -gt 0) {
        foreach ($issue in ($script:Issues | Sort-Object Path, Category)) {
            Write-Output ($issue.Path + ' [' + $issue.Category + ']')
        }
        throw ('Public-file check failed with ' + $script:Issues.Count + ' issue(s).')
    }

    Write-Output 'Public-file check passed: allowlisted files contain no detected runtime artifacts, private identifiers, or credential patterns.'
    Write-Output 'This automated scan is heuristic and is not a confidentiality guarantee.'
    exit 0
} catch {
    Write-Error $_
    exit 1
}
