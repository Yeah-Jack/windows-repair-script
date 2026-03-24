#Requires -RunAsAdministrator
<#
.SYNOPSIS
		Windows Health Check and Repair Script
.DESCRIPTION
		Runs DISM, SFC, and Disk Checks with robust logging, locale-independent checks, and proper output encoding.
#>

[CmdletBinding()]
param(
		[switch]$AutoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging Setup ────────────────────────────────────────────────────────────
$LogDir  = "$env:SystemRoot\Logs\HealthCheck"
$LogFile = Join-Path $LogDir "HealthCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
		param(
				[string]$Message,
				[ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info'
		)
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$logEntry  = "[$timestamp] [$Level] $Message"
		
		$color = switch ($Level) {
				'Success' { 'Green' }
				'Warning' { 'Yellow' }
				'Error'   { 'Red' }
				Default   { 'Cyan' }
		}

		Add-Content -Path $LogFile -Value $logEntry
		Write-Host $logEntry -ForegroundColor $color
}

# ── Helper: Run SFC Safely with Correct Encoding ─────────────────────────────
function Invoke-Sfc {
		Write-Log "Running: System File Checker (sfc /scannow)" -Level Info
		
		# SFC outputs UTF-16LE. Changing console encoding allows PS to read it natively.
		$oldEncoding = [Console]::OutputEncoding
		[Console]::OutputEncoding = [System.Text.Encoding]::Unicode
		
		try {
				$output = & sfc.exe /scannow 2>&1
				$outputText = ($output | Out-String).Trim()
				
				Write-Verbose "[SFC] Output:`n$outputText"
				Add-Content -Path $LogFile -Value "SFC Output:`n$outputText"
				
				return $outputText
		}
		catch {
				Write-Log "SFC command failed: $_" -Level Error
				return $null
		}
		finally {
				[Console]::OutputEncoding = $oldEncoding
		}
}

# ── State Tracking ───────────────────────────────────────────────────────────
$repairsMade   = $false
$restartNeeded = $false

# ════════════════════════════════════════════════════════════════════════════
# STEP 1 — DISM Component Store
# ════════════════════════════════════════════════════════════════════════════
Write-Log "STEP 1: Scanning component store with DISM..." -Level Info

try {
		# Repair-WindowsImage returns an object, eliminating the need for Regex text matching
		$dismScan = Repair-WindowsImage -Online -ScanHealth
		Add-Content -Path $LogFile -Value "DISM ScanHealth State: $($dismScan.ImageHealthState)"

		if ($dismScan.ImageHealthState -eq 'Healthy') {
				Write-Log 'Component store is healthy.' -Level Success
		}
		elseif ($dismScan.ImageHealthState -eq 'Repairable') {
				Write-Log 'Corruption detected — attempting RestoreHealth...' -Level Warning
				
				$dismRestore = Repair-WindowsImage -Online -RestoreHealth
				Add-Content -Path $LogFile -Value "DISM RestoreHealth State: $($dismRestore.ImageHealthState)"

				if ($dismRestore.ImageHealthState -eq 'Healthy') {
						Write-Log 'Component store repaired successfully.' -Level Success
						$repairsMade = $true
				}
				else {
						Write-Log 'DISM RestoreHealth did not complete cleanly. Review the log.' -Level Error
				}
		}
		else {
				Write-Log "DISM returned state: $($dismScan.ImageHealthState). Manual intervention may be required." -Level Warning
		}
} catch {
		Write-Log "DISM operation failed: $_" -Level Error
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — System File Checker (SFC)
# ════════════════════════════════════════════════════════════════════════════
Write-Log 'STEP 2: Scanning System Files (SFC)...' -Level Info

$sfcOutput = Invoke-Sfc

# Checking $LASTEXITCODE is safer than string matching, but we combine both for context
if ($LASTEXITCODE -eq 0 -and $sfcOutput -notmatch 'successfully repaired') {
		Write-Log 'No system file integrity violations found.' -Level Success
}
elseif ($sfcOutput -match 'corrupt files and successfully repaired') {
		Write-Log 'Corrupt system files were found and repaired.' -Level Warning
		$repairsMade = $true
}
else {
		Write-Log 'SFC found errors it could not fix, or returned an unexpected state.' -Level Error
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 — Disk Health (Using Native Cmdlets)
# ════════════════════════════════════════════════════════════════════════════
$driveLetter = $env:SystemDrive.TrimEnd(':')
Write-Log "STEP 3: Scanning disk $env:SystemDrive with Repair-Volume..." -Level Info

try {
		# Returns 'NoErrorsFound' or 'ErrorsFound' — completely locale-independent
		$volScan = Repair-Volume -DriveLetter $driveLetter -Scan

		if ($volScan -eq 'NoErrorsFound') {
				Write-Log 'No file system errors detected.' -Level Success
		}
		else {
				Write-Log 'File system errors detected — scheduling repair on next boot.' -Level Warning
				
				# OfflineScanAndFix automatically flags the drive for repair on the next reboot
				Repair-Volume -DriveLetter $driveLetter -OfflineScanAndFix | Out-Null
				
				$repairsMade   = $true
				$restartNeeded = $true
		}
} catch {
		Write-Log "Disk scan failed: $_" -Level Error
}

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
Write-Log '' -Level Info
Write-Log 'Health check complete.' -Level Info
Write-Log "Full log saved to: $LogFile"  -Level Info

if ($repairsMade)   { Write-Log 'Repairs were made to your system.' -Level Warning }
if (-not $repairsMade -and -not $restartNeeded) {
		Write-Log 'System appears healthy — no repairs needed.' -Level Success
}

if ($restartNeeded) {
		Write-Log 'A restart is required to complete repairs.' -Level Warning
		if ($AutoRestart) {
				Restart-Computer -Force
		}
		else {
				$answer = Read-Host 'Restart now? (Y/N)'
				if ($answer -match '^Y$') { Restart-Computer -Force }
				else { Write-Log 'Please restart as soon as possible.' -Level Warning }
		}
}