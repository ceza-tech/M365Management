<#
.SYNOPSIS
    Installs local git hooks for this repo.
    Run once after cloning: pwsh ./scripts/Install-GitHooks.ps1

.DESCRIPTION
    Copies hooks from scripts/hooks/ into .git/hooks/ and makes them executable.
    Git hooks are not committed — this script is the install mechanism.
#>

$hooksSource = Join-Path $PSScriptRoot 'hooks'
$hooksDest   = Join-Path (Split-Path $PSScriptRoot -Parent) '.git' 'hooks'

if (-not (Test-Path $hooksSource)) {
    Write-Host "No hooks found in $hooksSource" -ForegroundColor Yellow
    exit 0
}

foreach ($hook in Get-ChildItem $hooksSource) {
    $dest = Join-Path $hooksDest $hook.Name
    Copy-Item $hook.FullName $dest -Force
    if ($IsLinux -or $IsMacOS) {
        chmod +x $dest
    }
    Write-Host "  ✅ Installed: $($hook.Name)" -ForegroundColor Green
}

Write-Host "`n🎉 Git hooks installed. Direct pushes to main are now blocked locally." -ForegroundColor Green
Write-Host "   Use 'git push --no-verify' to bypass in an emergency." -ForegroundColor White
