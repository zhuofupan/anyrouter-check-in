param(
	[string]$ConfigPath = '',
	[string]$EnvironmentName = 'production',
	[string]$DefaultCommitMessage = 'chore: sync AnyRouter check-in config',
	[switch]$DryRun,
	[switch]$NoPush,
	[switch]$NoWorkflow
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..')
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
	$ConfigPath = Join-Path $RepoRoot 'CONFIG.local.json'
} elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
	$ConfigPath = Join-Path $RepoRoot $ConfigPath
}

$ExampleConfigPath = Join-Path $RepoRoot 'CONFIG.local.example.json'

function Test-JsonProperty {
	param(
		[object]$Object,
		[string]$Name
	)

	if ($null -eq $Object) {
		return $false
	}

	return $null -ne $Object.PSObject.Properties[$Name]
}

function Convert-ToCompactJson {
	param([object]$Value)

	return ConvertTo-Json -InputObject $Value -Depth 50 -Compress
}

function Invoke-Checked {
	param(
		[string]$File,
		[string[]]$Arguments
	)

	Write-Host "> $File $($Arguments -join ' ')"
	& $File @Arguments
	if ($LASTEXITCODE -ne 0) {
		throw "Command failed: $File $($Arguments -join ' ')"
	}
}

function Set-GitHubEnvironmentSecret {
	param(
		[string]$Name,
		[string]$Value,
		[string]$Repo,
		[string]$Environment
	)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		Write-Host "[skip] $Name is empty"
		return
	}

	if ($DryRun) {
		Write-Host "[dry-run] Would update $Name in environment '$Environment'"
		return
	}

	Write-Host "[secret] Updating $Name in environment '$Environment'"
	& gh secret set $Name --env $Environment --repo $Repo --body $Value
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to set GitHub secret: $Name"
	}
}

foreach ($command in @('git', 'gh')) {
	if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
		throw "Missing required command: $command"
	}
}

Invoke-Checked gh @('auth', 'status')

if (-not (Test-Path -LiteralPath $ConfigPath)) {
	if (Test-Path -LiteralPath $ExampleConfigPath) {
		Copy-Item -LiteralPath $ExampleConfigPath -Destination $ConfigPath
	}

	throw "Created CONFIG.local.json. Edit it with your real session and api_user, then run this script again."
}

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$ConfigText = Get-Content -Raw -LiteralPath $ConfigPath
if ($ConfigText -match 'PASTE_SESSION_COOKIE_HERE|PASTE_NEW_API_USER_HERE') {
	throw "CONFIG.local.json still contains placeholder values. Replace them before syncing secrets."
}

if (-not (Test-JsonProperty $Config 'accounts')) {
	throw 'CONFIG.local.json must contain accounts.'
}

if (-not ($Config.accounts -is [array])) {
	throw 'accounts must be a JSON array.'
}

if ($Config.accounts.Count -eq 0) {
	throw 'accounts cannot be empty.'
}

for ($index = 0; $index -lt $Config.accounts.Count; $index++) {
	$Account = $Config.accounts[$index]
	if (-not (Test-JsonProperty $Account 'cookies')) {
		throw "accounts[$index] is missing cookies."
	}
	if ((-not (Test-JsonProperty $Account 'api_user')) -or [string]::IsNullOrWhiteSpace([string]$Account.api_user)) {
		throw "accounts[$index] is missing api_user."
	}
}

$Repo = (& gh repo view --json nameWithOwner --jq '.nameWithOwner').Trim()
if ([string]::IsNullOrWhiteSpace($Repo) -or $Repo -notmatch '/') {
	throw 'Unable to detect GitHub repository. Check git remote origin.'
}

Write-Host "[repo] $Repo"
if ($DryRun) {
	Write-Host "[dry-run] Would create or update environment '$EnvironmentName'"
} else {
	Invoke-Checked gh @('api', '-X', 'PUT', "repos/$Repo/environments/$EnvironmentName")
}

$AccountsJson = Convert-ToCompactJson $Config.accounts
Set-GitHubEnvironmentSecret -Name 'ANYROUTER_ACCOUNTS' -Value $AccountsJson -Repo $Repo -Environment $EnvironmentName

if (Test-JsonProperty $Config 'providers') {
	$ProvidersJson = Convert-ToCompactJson $Config.providers
	Set-GitHubEnvironmentSecret -Name 'PROVIDERS' -Value $ProvidersJson -Repo $Repo -Environment $EnvironmentName
} else {
	Write-Host '[info] providers is missing; PROVIDERS was not changed.'
}

if (Test-JsonProperty $Config 'notifications') {
	foreach ($property in $Config.notifications.PSObject.Properties) {
		Set-GitHubEnvironmentSecret -Name $property.Name -Value ([string]$property.Value) -Repo $Repo -Environment $EnvironmentName
	}
}

if (Test-JsonProperty $Config 'extra_secrets') {
	foreach ($property in $Config.extra_secrets.PSObject.Properties) {
		Set-GitHubEnvironmentSecret -Name $property.Name -Value ([string]$property.Value) -Repo $Repo -Environment $EnvironmentName
	}
}

if ($DryRun) {
	Write-Host '[dry-run] Git commit, push, and workflow trigger skipped.'
	Write-Host '[done] Dry run completed.'
	return
}

$CommitMessage = $DefaultCommitMessage
if ((Test-JsonProperty $Config 'commit_message') -and -not [string]::IsNullOrWhiteSpace([string]$Config.commit_message)) {
	$CommitMessage = [string]$Config.commit_message
}

Invoke-Checked git @('add', '-A')
& git diff --cached --quiet
$HasStagedChanges = $LASTEXITCODE -eq 1
if ($LASTEXITCODE -notin @(0, 1)) {
	throw 'Unable to inspect staged git changes.'
}

if ($HasStagedChanges) {
	Invoke-Checked git @('commit', '-m', $CommitMessage)
} else {
	Write-Host '[git] No repository file changes to commit.'
}

$Branch = (& git branch --show-current).Trim()
if ([string]::IsNullOrWhiteSpace($Branch)) {
	throw 'Unable to detect current git branch.'
}

if (-not $NoPush) {
	& git rev-parse --abbrev-ref --symbolic-full-name '@{u}' *> $null
	if ($LASTEXITCODE -eq 0) {
		Invoke-Checked git @('push')
	} else {
		Invoke-Checked git @('push', '-u', 'origin', $Branch)
	}
} else {
	Write-Host '[git] Push skipped because -NoPush was specified.'
}

$ShouldRunWorkflow = -not $NoWorkflow
if (Test-JsonProperty $Config 'run_workflow_after_push') {
	$ShouldRunWorkflow = [bool]$Config.run_workflow_after_push
}
if ($NoWorkflow) {
	$ShouldRunWorkflow = $false
}

if ($ShouldRunWorkflow) {
	Invoke-Checked gh @('workflow', 'run', 'checkin.yml', '--repo', $Repo, '--ref', $Branch)
	Write-Host '[workflow] checkin.yml has been triggered.'
} else {
	Write-Host '[workflow] Trigger skipped.'
}

Write-Host '[done] GitHub configuration synced.'
