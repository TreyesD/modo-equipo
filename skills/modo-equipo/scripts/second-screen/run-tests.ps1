param(
    [string]$Root = (Get-Location).Path,
    [string]$StateDir = (Join-Path $env:USERPROFILE '.claude\modo-equipo'),
    [switch]$NoPause
)
# Detects the test suites under -Root, runs them one after another and writes:
#   <StateDir>\tests-last.log   human-readable output (UTF-8)
#   <StateDir>\tests-last.json  machine-readable status: running | done, one entry per suite
# Override detection with <Root>\.modo-equipo-tests.json:
#   [ { "name": "api", "dir": "services/api", "cmd": "npm test" } ]
$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Test runner'
New-Item -ItemType Directory -Force $StateDir | Out-Null
$log  = Join-Path $StateDir 'tests-last.log'
$json = Join-Path $StateDir 'tests-last.json'
$Root = (Resolve-Path $Root).Path

# All output files are UTF-8 without BOM: Windows PowerShell 5.1 writes a BOM for
# UTF-8, and strict JSON parsers reject it.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-State($status, $results) {
    $text = [pscustomobject]@{
        status  = $status
        root    = $Root
        updated = (Get-Date -Format s)
        suites  = @($results)
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($json, $text, $Utf8NoBom)
}

function Set-Log($text) { [System.IO.File]::WriteAllText($log, "$text`r`n", $Utf8NoBom) }
function Add-Log($text) { [System.IO.File]::AppendAllText($log, "$text`r`n", $Utf8NoBom) }

function Find-Suites($root) {
    $override = Join-Path $root '.modo-equipo-tests.json'
    if (Test-Path $override) {
        # Parentheses force enumeration: Windows PowerShell 5.1 ConvertFrom-Json emits a JSON
        # array as one object, which breaks ForEach-Object when there are 2+ suites.
        return @((Get-Content $override -Raw | ConvertFrom-Json) | ForEach-Object {
            @{ Name = $_.name; Dir = (Join-Path $root $_.dir); Cmd = $_.cmd }
        })
    }
    $skip = '\\(node_modules|\.git|\.venv|venv|dist|build|downloads|__pycache__)(\\|$)'
    $suites = @()
    $dirs = @(Get-Item $root) + @(Get-ChildItem $root -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skip })
    foreach ($d in $dirs) {
        $p = $d.FullName
        $name = $d.Name
        $pkg = Join-Path $p 'package.json'
        if (Test-Path $pkg) {
            $j = Get-Content $pkg -Raw | ConvertFrom-Json
            if ($j.scripts -and $j.scripts.test -and $j.scripts.test -notmatch 'no test specified') {
                $isBun = (Test-Path (Join-Path $p 'bun.lock')) -or (Test-Path (Join-Path $p 'bun.lockb')) -or ($j.scripts.test -match '^bun ')
                $cmd = 'npm test'
                if ($isBun) { $cmd = 'bun run test' }
                $suites += @{ Name = $name; Dir = $p; Cmd = $cmd }
                continue
            }
        }
        if (Test-Path (Join-Path $p 'go.mod')) { $suites += @{ Name = $name; Dir = $p; Cmd = 'go test ./...' }; continue }
        if (Test-Path (Join-Path $p 'Cargo.toml')) { $suites += @{ Name = $name; Dir = $p; Cmd = 'cargo test' }; continue }
        # Point pytest at tests/ when it exists, so vendored third-party tests are not collected.
        $hasTestsDir = (Test-Path (Join-Path $p 'tests')) -and (Get-ChildItem (Join-Path $p 'tests') -Filter 'test_*.py' -ErrorAction SilentlyContinue)
        if ($hasTestsDir) { $suites += @{ Name = $name; Dir = $p; Cmd = 'python -m pytest -q tests' } }
        elseif (Test-Path (Join-Path $p 'pytest.ini')) { $suites += @{ Name = $name; Dir = $p; Cmd = 'python -m pytest -q' } }
    }
    return $suites
}

Set-Log "Run started $(Get-Date -Format s) in $Root"
$suites = @(Find-Suites $Root)
$results = @()
Write-State 'running' $results

if ($suites.Count -eq 0) {
    Write-Host 'No test suites detected. Add .modo-equipo-tests.json to define them.' -ForegroundColor Yellow
}

foreach ($s in $suites) {
    Write-Host "`n=== $($s.Name) ($($s.Cmd)) ===" -ForegroundColor Cyan
    $exe = ($s.Cmd -split ' ')[0]
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        $msg = "MISSING TOOL: $exe is not installed or not on PATH"
        Write-Host $msg -ForegroundColor Red
        Add-Log "=== $($s.Name) ===`n$msg"
        $results += [pscustomobject]@{ name = $s.Name; cmd = $s.Cmd; result = 'missing-tool'; exitCode = $null }
        Write-State 'running' $results
        continue
    }
    Add-Log "`n=== $($s.Name) ($($s.Cmd)) ==="
    Push-Location $s.Dir
    cmd /c "$($s.Cmd) 2>&1" | ForEach-Object { Add-Log "$_"; $_ }
    $code = $LASTEXITCODE
    Pop-Location
    $res = 'failed'
    if ($code -eq 0) { $res = 'passed' }
    $results += [pscustomobject]@{ name = $s.Name; cmd = $s.Cmd; result = $res; exitCode = $code }
    Write-State 'running' $results
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Yellow
$table = $results | Format-Table name, result, exitCode -AutoSize | Out-String
Add-Log $table
Write-Host $table
Write-State 'done' $results

$bad = @($results | Where-Object { $_.result -ne 'passed' }).Count
if ($results.Count -eq 0) { $Host.UI.RawUI.WindowTitle = 'Tests: none found' }
elseif ($bad -eq 0) { $Host.UI.RawUI.WindowTitle = 'Tests: ALL OK' }
else { $Host.UI.RawUI.WindowTitle = "Tests: $bad FAILED" }
if (-not $NoPause) { Read-Host 'Done. Press Enter to close' }
