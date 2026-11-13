# Codex hook when the agent wants to finish: check, test and format must pass.
# Exit 2 sends the failure back as the next thing to fix. A second stop in a row
# is let through, so the agent never loops.
Set-Location (Join-Path $PSScriptRoot '..\..')
$payload = [Console]::In.ReadToEnd()
if ($payload -match '"stop_hook_active"\s*:\s*true') { '{}'; exit 0 }
foreach ($step in @(@('check'), @('test'), @('format', '--check', 'src', 'test', 'dev'))) {
  $out = & gleam @step 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    $tail = ($out -split "`n" | Select-Object -Last 60) -join "`n"
    [Console]::Error.Write("gleam $($step -join ' ') failed:`n$tail")
    exit 2
  }
}
'{}'
exit 0
