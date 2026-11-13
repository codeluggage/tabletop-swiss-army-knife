# Codex hook after a file edit: type-check the project.
# Exit 2 sends the errors back to the agent, so it fixes them before going on.
Set-Location (Join-Path $PSScriptRoot '..\..')
$out = gleam check 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { [Console]::Error.Write("gleam check failed:`n$out"); exit 2 }
exit 0
