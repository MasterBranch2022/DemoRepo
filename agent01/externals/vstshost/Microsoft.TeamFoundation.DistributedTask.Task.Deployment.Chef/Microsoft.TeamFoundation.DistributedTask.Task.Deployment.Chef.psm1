function Invoke-Knife
{
    <#
        .SYNOPSIS
        Returns the output of knife command

        .PARAMETER argumets
        Arguments for knife command
    #>
    [CmdletBinding()]
    Param
    (
        [Parameter(mandatory=$true)]
        [string[]]$arguments
    )

    $ErrorActionPreference = 'Stop'
    pushd $global:chefRepo
    try
    {
        $command = "knife "
        $arguments | foreach{ $command += "$_ " }
        $command = $command.Trim()
        Write-verbose "Running knife command: $command" -verbose
        iex $command
    }
    finally
    {
        popd
    }
}

function Initialize-ChefRepo()
{
	[CmdletBinding()]
    Param
    (
		[Parameter(mandatory=$true)]
        $connectedServiceDetails
    )

    $ErrorActionPreference = 'Stop'
    Write-Verbose "Creating Chef Repo" -verbose

    $userName = $connectedServiceDetails.Authorization.Parameters.Username
    Write-Verbose "userName = $userName" -Verbose
    $passwordKey = $connectedServiceDetails.Authorization.Parameters.Password
    $organizationUrl = $connectedServiceDetails.Url
    Write-Verbose "organizationUrl = $organizationUrl" -Verbose
    
    #create temporary chef repo
    $randomGuid=[guid]::NewGuid()
    $tempDirectory = [System.Environment]::GetEnvironmentVariable("temp","Machine")
    $chefRepoPath = Get-TemporaryDirectoryForChef
    $global:chefRepo = "$chefRepoPath"
    New-Item $chefRepoPath -type Directory | Out-Null

    #create knife config directory
    $knifeConfigDirectoryPath = Join-Path -Path $chefRepoPath -ChildPath ".chef"
    New-Item $knifeConfigDirectoryPath -type Directory | Out-Null

    #create knife.rb
    $knifeConfigPath = Join-Path -Path $knifeConfigDirectoryPath -ChildPath "knife.rb"
    New-Item $knifeConfigPath -type File | Out-Null

    #create passwordKey File
    $privateKeyFileName = $userName + ".pem"
    $privateKeyFilePath = Join-Path -Path $knifeConfigDirectoryPath -ChildPath $privateKeyFileName
    New-Item $privateKeyFilePath -type File -value $passwordKey | Out-Null

    Invoke-Knife @("configure --repository '$chefRepoPath' --server-url '$organizationUrl' --user '$userName' --validation-client-name '$userName'  --validation-key '$privateKeyFileName' --config '$knifeConfigPath' --yes") | Out-Null

    Write-Verbose "Chef Repo Created" -verbose
}

function Get-TemporaryDirectoryForChef
{
    [CmdletBinding()]
    Param
    ()

    $ErrorActionPreference = 'Stop'
    $randomGuid=[guid]::NewGuid()
    $tempDirectory = [System.Environment]::GetEnvironmentVariable("temp","Machine")
    return (Join-Path -Path $tempDirectory -ChildPath $randomGuid)
}

function Invoke-GenericMethod
{
    [CmdletBinding()]
	param(
	$instance = $(throw “Please provide an instance on which to invoke the generic method”),
	[string] $methodName = $(throw “Please provide a method name to invoke”),
	[string[]] $typeParameters = $(throw “Please specify the type parameters”),
	[object[]] $methodParameters = $(throw “Please specify the method parameters”)
	)

    $ErrorActionPreference = 'Stop'
	## Determine if the types in $set1 match the types in $set2, replacing generic
	## parameters in $set1 with the types in $genericTypes
	function ParameterTypesMatch([type[]] $set1, [type[]] $set2, [type[]] $genericTypes)
	{
		$typeReplacementIndex = 0
		$currentTypeIndex = 0

		## Exit if the set lengths are different
		if($set1.Count -ne $set2.Count)
		{
			return $false
		}

	## Go through each of the types in the first set
		foreach($type in $set1)
		{
			## If it is a generic parameter, then replace it with a type from
			## the $genericTypes list
			if($type.IsGenericParameter)
			{
				$type = $genericTypes[$typeReplacementIndex]
				$typeReplacementIndex++
			}

			## Check that the current type (i.e.: the original type, or replacement
			## generic type) matches the type from $set2
			if($type -ne $set2[$currentTypeIndex])
			{
				return $false
			}
			$currentTypeIndex++
		}

		return $true
	}

	## Convert the type parameters into actual types
	[type[]] $typedParameters = $typeParameters

	## Determine the type that we will call the generic method on. Initially, assume
	## that it is actually a type itself.
	$type = $instance

	## If it is not, then it is a real object, and we can call its GetType() method
	if($instance -isnot "Type")
	{
		$type = $instance.GetType()
	}

	## Search for the method that:
	## – has the same name
	## – is public
	## – is a generic method
	## – has the same parameter types
	foreach($method in $type.GetMethods())
	{
		# Write-Host $method.Name
		if(($method.Name -eq $methodName) -and
		($method.IsPublic) -and
		($method.IsGenericMethod))
		{
			$parameterTypes = @($method.GetParameters() | % { $_.ParameterType })
			$methodParameterTypes = @($methodParameters | % { $_.GetType() })
			if(ParameterTypesMatch $parameterTypes $methodParameterTypes $typedParameters)
			{
				## Create a closed representation of it
				$newMethod = $method.MakeGenericMethod($typedParameters)

				## Invoke the method
				$newMethod.Invoke($instance, $methodParameters)

				return
			}
		}
	}

	## Return an error if we couldn’t find that method
	throw (Get-LocalizedString -Key "Could not find method: '{0}'" -ArgumentList $methodName)
}

function Wait-ForChefNodeRunsToComplete()
{
	[CmdletBinding()]
    Param
    (
        [Parameter(mandatory=$true)]
        [string]$environmentName,
		[Parameter(mandatory=$true)]
        [int]$runWaitTimeInMinutes,
		[Parameter(mandatory=$true)]
        [int]$pollingIntervalTimeInSeconds
    )

    $ErrorActionPreference = 'Stop'
	$driftInSeconds = 30;
	$attributeUpdateTime = (Get-Date).ToUniversalTime();
	$attributeUpdateTimeWithDrift = $attributeUpdateTime.AddSeconds($driftInSeconds)
	$allNodeRunsCompleted = $false;
	$failureNodesList = @();
	$successNodesList = @();
	$noRunsNodeList = @();
	$nodes = Invoke-Knife @("node list -E $environmentName")
	$nodesCompletionTable = @{};
	foreach($node in $nodes)
	{
		$nodesCompletionTable.Add($node, $false);
	}
	
	Write-Host (Get-LocalizedString -Key "Waiting for runs to complete on all the nodes of the environment: '{0}'" -ArgumentList $environmentName)

	while(Get-ShouldWaitForNodeRuns -attributeUpdateTime $attributeUpdateTime `
          -runWaitTimeInMinutes $runWaitTimeInMinutes -allNodeRunsCompleted $allNodeRunsCompleted)
	{
		$runListFetchAndParse = {
            $runListJson = Invoke-Knife @("runs list -E $environmentName -F json")
		    #TODO: might remove this, added to check E2E failure intermittent
		    Write-Verbose ($runListJson | Out-string) -verbose
            return [Newtonsoft.Json.Linq.JArray]::Parse($runListJson);
        }

        $runArray = Invoke-WithRetry -Command $runListFetchAndParse -RetryDelay 10 -MaxRetries 10 -OperationDetail "fetch/parse run list of chef nodes"

		foreach($run in $runArray.GetEnumerator())
		{
			$nodeName = $run["node_name"].ToString();
			if($nodesCompletionTable.Contains($nodeName) `
			-and (-not $nodesCompletionTable[$nodeName]) `
			-and ([System.DateTime]::Parse($run["start_time"].ToString()) -gt $attributeUpdateTimeWithDrift))
			{
				$runStatus = $run["status"].ToString();
				$runId = $run["run_id"].ToString();

				if($runStatus -eq "failure")
				{
					$runString = Get-DetailedRunHistory $runId
					$runLog = "`n" + ($runString | out-string)
					Write-Error (Get-LocalizedString -Key "Run on node '{0}' has failed. Check logs below: {1}" -ArgumentList $nodeName, $runLog) -EA "Continue"
					$failureNodesList += $nodeName
					$nodesCompletionTable[$nodeName] = $true
				}
				elseif($runStatus -eq "success")
				{
					Write-Host (Get-LocalizedString -Key "Run on node '{0}' has succeeded. run_id: '{1}'" -ArgumentList $nodeName, $runId)
					$successNodesList += $nodeName
					$nodesCompletionTable[$nodeName] = $true
				}
				else
				{
					#InProgress condition which is equivalent to no run on node, no-op
			}
		}
		}

		$allNodeRunsCompleted = $true;
		foreach($isCompleted in $nodesCompletionTable.Values)
		{
			if(-not $isCompleted)
			{
				$allNodeRunsCompleted = $false;
				break;        
			}
		}

		if(-not $allNodeRunsCompleted)
		{
			Start-Sleep -s $pollingIntervalTimeInSeconds
		}
	}

	if($allNodeRunsCompleted)
	{
		Write-Host (Get-LocalizedString -Key "Runs have completed on all the nodes in the environment: '{0}'" -ArgumentList $environmentName)
	}
	else
	{
		foreach($nodeCompletionData in $nodesCompletionTable.GetEnumerator())
		{
			if($nodeCompletionData.Value -eq $false)
			{
				$noRunsNodeList += $nodeCompletionData.Name
			}
		}

		Write-Host (Get-LocalizedString -Key "Runs have not completed on all the nodes in the environment: '{0}'" -ArgumentList $environmentName)
		$noRunsNodeListString = "`n" + ($noRunsNodeList -join "`n")
		Write-Host (Get-LocalizedString -Key "Runs have not completed on the following nodes: {0}" -ArgumentList $noRunsNodeListString)
	}

	if($successNodesList.Count -gt 0)
	{
		$successNodesListString = "`n" + ($successNodesList -join "`n")
		Write-Host (Get-LocalizedString -Key "Runs have completed successfully on the following nodes: {0}" -ArgumentList $successNodesListString)
	}

	if(($failureNodesList.Count -gt 0) -or (-not $allNodeRunsCompleted))
	{
		if($failureNodesList.Count -eq 0)
		{
			Write-Host (Get-LocalizedString -Key "Chef deployment has failed because chef runs have not completed on all the nodes in the environment. However, there were no chef run failures. Consider increasing wait time for chef runs to complete, and check nodes if they are reachable from chef server and able to pull the recipes from the chef server.")
		}
		else
		{
			$failureNodesListString = "`n" + ($failureNodesList -join "`n")
			Write-Host (Get-LocalizedString -Key "Runs have failed on the following nodes: {0}" -ArgumentList $failureNodesListString)
		}

		throw (Get-LocalizedString -Key "Chef deployment has failed on the environment: '{0}'" -ArgumentList $environmentName)
	}
	else
	{
		Write-Host (Get-LocalizedString -Key "Chef deployment has succeeded on the environment: '{0}'"  -ArgumentList $environmentName)
	}
}

function Get-ShouldWaitForNodeRuns
{
    [CmdletBinding()]
	Param
    (
		[Parameter(mandatory=$true)]
        [DateTime]$attributeUpdateTime,
        [Parameter(mandatory=$true)]
        [int]$runWaitTimeInMinutes,
        [Parameter(mandatory=$true)]
        [bool]$allNodeRunsCompleted
    )

    $ErrorActionPreference = 'Stop'
    return ((Get-Date).ToUniversalTime()  `
            -lt $attributeUpdateTime.AddMinutes($runWaitTimeInMinutes)) `
	        -and ($allNodeRunsCompleted -eq $false)
}

function Get-PathToNewtonsoftBinary
{
    [CmdletBinding()]
    Param
    ()

    return '$PSScriptRoot\..\Newtonsoft.Json.dll'
}

function Get-DetailedRunHistory()
{
	[CmdletBinding()]
	Param
    (
		[Parameter(mandatory=$true)]
        [string]$runIdString
    )

	return Invoke-knife @("runs show $runIdString")
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(    
    [Parameter(Mandatory)]
    $Command,
    [Parameter(Mandatory)]
    $RetryDelay = 5,
    [Parameter(Mandatory)]
    $MaxRetries = 5,
    [Parameter(Mandatory)]
    $OperationDetail
    )
    
    $ErrorActionPreference = 'Stop'
    $currentRetry = 0
    $success = $false

    do {
        try
        {
            $result = & $Command
            $success = $true
            return $result
        }
        catch [System.Exception]
        {            
            Write-Verbose ("Failed to execute operation `"$OperationDetail`" during retry: " + $_.Exception.Message) -verbose

            $currentRetry = $currentRetry + 1
            
            if ($currentRetry -gt $MaxRetries)
            {                
                throw $_
            } 
            else 
            {
                Write-Verbose ("Waiting $RetryDelay second(s) before retry attempt #$currentRetry of operation `"$OperationDetail`"") -Verbose
                Start-Sleep -s $RetryDelay
            }
        }
    } while (!$success);
}
# SIG # Begin signature block
# MIInogYJKoZIhvcNAQcCoIInkzCCJ48CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBGzlHJuS8puzGK
# mhZ0RBK2vb9SAGUz2JiA9pipAB1f9aCCDYUwggYDMIID66ADAgECAhMzAAACzfNk
# v/jUTF1RAAAAAALNMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjIwNTEyMjA0NjAyWhcNMjMwNTExMjA0NjAyWjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDrIzsY62MmKrzergm7Ucnu+DuSHdgzRZVCIGi9CalFrhwtiK+3FIDzlOYbs/zz
# HwuLC3hir55wVgHoaC4liQwQ60wVyR17EZPa4BQ28C5ARlxqftdp3H8RrXWbVyvQ
# aUnBQVZM73XDyGV1oUPZGHGWtgdqtBUd60VjnFPICSf8pnFiit6hvSxH5IVWI0iO
# nfqdXYoPWUtVUMmVqW1yBX0NtbQlSHIU6hlPvo9/uqKvkjFUFA2LbC9AWQbJmH+1
# uM0l4nDSKfCqccvdI5l3zjEk9yUSUmh1IQhDFn+5SL2JmnCF0jZEZ4f5HE7ykDP+
# oiA3Q+fhKCseg+0aEHi+DRPZAgMBAAGjggGCMIIBfjAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQU0WymH4CP7s1+yQktEwbcLQuR9Zww
# VAYDVR0RBE0wS6RJMEcxLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEWMBQGA1UEBRMNMjMwMDEyKzQ3MDUzMDAfBgNVHSMEGDAW
# gBRIbmTlUAXTgqoXNzcitW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIw
# MTEtMDctMDguY3JsMGEGCCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDEx
# XzIwMTEtMDctMDguY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIB
# AE7LSuuNObCBWYuttxJAgilXJ92GpyV/fTiyXHZ/9LbzXs/MfKnPwRydlmA2ak0r
# GWLDFh89zAWHFI8t9JLwpd/VRoVE3+WyzTIskdbBnHbf1yjo/+0tpHlnroFJdcDS
# MIsH+T7z3ClY+6WnjSTetpg1Y/pLOLXZpZjYeXQiFwo9G5lzUcSd8YVQNPQAGICl
# 2JRSaCNlzAdIFCF5PNKoXbJtEqDcPZ8oDrM9KdO7TqUE5VqeBe6DggY1sZYnQD+/
# LWlz5D0wCriNgGQ/TWWexMwwnEqlIwfkIcNFxo0QND/6Ya9DTAUykk2SKGSPt0kL
# tHxNEn2GJvcNtfohVY/b0tuyF05eXE3cdtYZbeGoU1xQixPZAlTdtLmeFNly82uB
# VbybAZ4Ut18F//UrugVQ9UUdK1uYmc+2SdRQQCccKwXGOuYgZ1ULW2u5PyfWxzo4
# BR++53OB/tZXQpz4OkgBZeqs9YaYLFfKRlQHVtmQghFHzB5v/WFonxDVlvPxy2go
# a0u9Z+ZlIpvooZRvm6OtXxdAjMBcWBAsnBRr/Oj5s356EDdf2l/sLwLFYE61t+ME
# iNYdy0pXL6gN3DxTVf2qjJxXFkFfjjTisndudHsguEMk8mEtnvwo9fOSKT6oRHhM
# 9sZ4HTg/TTMjUljmN3mBYWAWI5ExdC1inuog0xrKmOWVMIIHejCCBWKgAwIBAgIK
# YQ6Q0gAAAAAAAzANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlm
# aWNhdGUgQXV0aG9yaXR5IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEw
# OTA5WjB+MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYD
# VQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+la
# UKq4BjgaBEm6f8MMHt03a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc
# 6Whe0t+bU7IKLMOv2akrrnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4D
# dato88tt8zpcoRb0RrrgOGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+
# lD3v++MrWhAfTVYoonpy4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nk
# kDstrjNYxbc+/jLTswM9sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6
# A4aN91/w0FK/jJSHvMAhdCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmd
# X4jiJV3TIUs+UsS1Vz8kA/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL
# 5zmhD+kjSbwYuER8ReTBw3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zd
# sGbiwZeBe+3W7UvnSSmnEyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3
# T8HhhUSJxAlMxdSlQy90lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS
# 4NaIjAsCAwEAAaOCAe0wggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRI
# bmTlUAXTgqoXNzcitW2oynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAL
# BgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBD
# uRQFTuHqp8cx0SOJNDBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3JsMF4GCCsGAQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3J0MIGfBgNVHSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1h
# cnljcHMuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkA
# YwB5AF8AcwB0AGEAdABlAG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn
# 8oalmOBUeRou09h0ZyKbC5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7
# v0epo/Np22O/IjWll11lhJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0b
# pdS1HXeUOeLpZMlEPXh6I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/
# KmtYSWMfCWluWpiW5IP0wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvy
# CInWH8MyGOLwxS3OW560STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBp
# mLJZiWhub6e3dMNABQamASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJi
# hsMdYzaXht/a8/jyFqGaJ+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYb
# BL7fQccOKO7eZS/sl/ahXJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbS
# oqKfenoi+kiVH6v7RyOA9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sL
# gOppO6/8MO0ETI7f33VtY5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtX
# cVZOSEXAQsmbdlsKgEhr/Xmfwb1tbWrJUnMTDXpQzTGCGXMwghlvAgEBMIGVMH4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01p
# Y3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTECEzMAAALN82S/+NRMXVEAAAAA
# As0wDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIP2l
# baATeftljq2OqffQWOThF88Vzx4l1vO6iW4TMAr/MEIGCisGAQQBgjcCAQwxNDAy
# oBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20wDQYJKoZIhvcNAQEBBQAEggEAF5VhfhVBu4O5/4RGsz03IG6ONIoQBlPu1RhX
# g9PtZnopPK3v9zFxcx/ykpbz0ZhBTSa1S3M+7w6a5HEhZB0B4eXAPzIKvXgXOLir
# kVKLB7KQGaq2FGeIC20eR6jtgLiuUtltrnTN3STj2qHPixutLopZ+1t+y2kQSngx
# h7Eheh7dBKq9EqpC2rH772lruWsAc2YyvtzgYNl0xw5GwAGQC7u+fapGaGkTviJJ
# XKiYuucT1v5OlHHeB8vsANOTJbXd689tz5GV4+JEaXTOZ3o16w+K9fyl1o3MNUqp
# 9aI7VP+StuPJkELMb4I2M/kTSX4lLGSAT7SpHLjTyiP+gYRvKqGCFv0wghb5Bgor
# BgEEAYI3AwMBMYIW6TCCFuUGCSqGSIb3DQEHAqCCFtYwghbSAgEDMQ8wDQYJYIZI
# AWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGE
# WQoDATAxMA0GCWCGSAFlAwQCAQUABCCrU+WrayB7vd5qJ6EwoaVVA+idX+u+CnHi
# ZobdHZqEpgIGYxFgjErHGBMyMDIyMDkwNjE2MjIzMy4yNjhaMASAAgH0oIHQpIHN
# MIHKMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjoxMkJDLUUzQUUtNzRFQjElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaCCEVQwggcMMIIE9KADAgECAhMzAAABoQGFVZm5VF2KAAEA
# AAGhMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MB4XDTIxMTIwMjE5MDUyNFoXDTIzMDIyODE5MDUyNFowgcoxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVy
# aWNhIE9wZXJhdGlvbnMxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjEyQkMtRTNB
# RS03NEVCMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA2sk8XuVrpJK2McVbhy2FvQRF
# gg/ZJI55x7DisBnXSD22ZS2PpeaLywzX/gRDECgGUCNw1/dZdcgg7j/V+7TjwuPG
# URlwP23/apdBSueN/ICJe3FedvF3hDhcHPwPlGyFH1tvejpoPGetsWkL946xuFP6
# a4gKxf3q9VANRzbiBlMqo5coIkj8CtjZxQKYtSQ/lHn+XOO5Ie6VtSo+0Z3IaRXm
# PTHpD0EYmu3BGlGFOLKgoiVXQyaXny7z0/RHbYZUMe+ZXcfgMGX9mvU+7kEUgYfL
# acT3SAw5ColjMIyk6wGNPQNyP44naj7nPD71/rKsasmRDdoeBgNBHY5pOuJ5CLpA
# CtfCuZwCwyzvUjE8aQMECB0Q7WXkwpbwDwhKMtb7Tw+3/nqh6krbrvlwpH0Y1xKV
# /fofX67AdPwYA+QgX9xCywGvE3nzHx2VhCUUzza21zCos0q1EpFb/9xz/2bCacGs
# +TMtkW8nNwIfW0++ngSZMn0+RTfb/ykNB58YUTLOhx4U5jcfi87WHIvrx39A90B9
# Xgo2VmUY6dZjssaT1NpgzBuoHpbybHtSc0QA6O2CKJPydwnG5vDGwW5vOYqIBZbR
# R3nBxRBcK7AxgRZzWBzIXG2q0DQPoGNntpfXwJF9zIyO1JJZKM++Pz+iiKnuY3Hf
# RTwm20m2B/Ti7LXnmDkCAwEAAaOCATYwggEyMB0GA1UdDgQWBBQWvyAy22OO+VUM
# iomUsOO5dP3MqTAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0G
# CSqGSIb3DQEBCwUAA4ICAQAgwyMRJX15RuWCnCqyz0kvn9yVmaa8ChIgEr4r2h0w
# UZV7QLPk5GnXLBHovvcOb5hebQlM0x+HNJwiO22cZ7C/kul7IjrN2dVeFl/iMKF1
# CeMy77NPpk+L4xg7WHykP27JiSmq9nPfZv3x79Vptgk3Mmnj74vOiYd1Mi43USC1
# m7c7OKCJhTMMCm8x3T6KcawYYIvgtWGbIaLFi5YM8rsY1JfqjYNZudjCZn9dZaCO
# w/RyaGkM3fq3/dvGPK71C5oNofxudKPg9FCdRWv3CSWh3wd7HysPV+hq7V2Bo5jN
# /oPgIWlbH7qSlzbThbubZyyrwB+TiIxA2FdWCppV7gboW2GrLMoDxTJjYBtgJ5N3
# axHA3GYQl16qUbMzaNRehruSQqUGV2ziTPVHuT5SSrZiJgGCBrMPqZx8v6+YIEmD
# qeIOWdaFPRoVQjN1dE/WnXnujlFwZNaxOHWXP1LD5Y9KqIpYy/pTdQOYJJps+5Ob
# SDm1Rge3SXc/CdBcF0ROamLtQHb2rlW2cBkJC9cfGiv7L4xEFtDVMidvc5wx4l5e
# by6EU44xabIVAYtviGPpjamy5o9uI+Xk/m4w5RNx5jbSz6S3DA2KmdR/ulOmJmoj
# ZmnNo0VwwGnhBP7qAzLdnQK3yT+zPjA7988zTUyDXrjRLQ1YJvc8H4CFAl5w2blb
# YjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM
# 57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm
# 95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzB
# RMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBb
# fowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCO
# Mcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYw
# XE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW
# /aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/w
# EPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPK
# Z6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2
# BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfH
# CBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYB
# BAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8v
# BO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYM
# KwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEF
# BQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBW
# BgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUH
# AQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# L2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518Jx
# Nj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+
# iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2
# pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefw
# C2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7
# T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFO
# Ry3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhL
# mm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3L
# wUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5
# m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE
# 0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggLLMIICNAIB
# ATCB+KGB0KSBzTCByjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEmMCQGA1UE
# CxMdVGhhbGVzIFRTUyBFU046MTJCQy1FM0FFLTc0RUIxJTAjBgNVBAMTHE1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVABtxdozuCxDF
# S8IChl3WDDeBQYDgoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTAwDQYJKoZIhvcNAQEFBQACBQDmwc2ZMCIYDzIwMjIwOTA2MjE0NjAxWhgPMjAy
# MjA5MDcyMTQ2MDFaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAObBzZkCAQAwBwIB
# AAICDzAwBwIBAAICEnIwCgIFAObDHxkCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYK
# KwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUF
# AAOBgQAWfVf4n1CKC/FZ0/i8IOzG/h8iiCibravygrQMD1vY1t2TV2QtmQDc2F76
# 2ASvzPm6Xvf+QlG7MBYnkFqKQbAogViS8mVby4ORq4RKi0AYOp3//L+c5kZRgSl+
# D1Dx5Vlf7Xn+R5NSEQLfBJp2Dsr2k4HCbyxDiSxFKFYQeZPEAzGCBA0wggQJAgEB
# MIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABoQGFVZm5VF2K
# AAEAAAGhMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwLwYJKoZIhvcNAQkEMSIEINXRrZO9AIbk6VCr3Hqro7s9SzCZq5OHofoL
# oaEsY9h+MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQg6whU8TqBgmgggo6E
# cgXtSUkKzCXggk8hK84oid+O0IQwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAaEBhVWZuVRdigABAAABoTAiBCCE62rFHOIFPSo2ZBpn
# nJ4afbI2KVURK5tvPclWV5Q4djANBgkqhkiG9w0BAQsFAASCAgBz068oGB38FzY+
# YJOM5Yidwo3OxYQrX6Q3FgbebfObMyG2XLjQhvu8M+WcVWM/FPa4N6tsMwk+CxB8
# Oo+SiO/ZvDan0BnwNcGnzemV+8w4iTQ/h51v7LXnznGzYc9ROelKKkgunH3BRFAy
# /kfhmftoHDDtM9mvs+SN9qUG0bHSM2GTMJbMW2IdblwkjDaupInGTWQu+1LasaGD
# EAABNLyx71qEAUQ4l7icTBh0jmGtug7gKcvpMu0p2nyKucaQtLikjuQJkFAhbfNg
# ucVNvsveLbio6JhqSEPar9QBBQbMRwabKnb5ok+27qrIaT2NTaYk2d/1BpcfKGF9
# pEP0zyclgdzOjKQ+A9NnsrXMEuZLzK/nPqFsQ6lvEyoyu6eq91EL/NPIyV9QksLY
# aL2jYWUZnJ6q/ndoisBJbITZN9FvKhxInB/WqfAtSN6ewxzQiGML1ujmKfrGS+lD
# CLov4jnLBFzl20owhJ141SDp9+TscxPUokHxJ0AQ29ppdQKEACuX74Yd022v9iu3
# TB51B3B5us+GovyKRiVjQSq6p75fXKME3xQr67Wubb0AtdPFhCf6NmLWf/vdOBV4
# CNqiXpZpNO8Qy8B4a2Z/Vz6Er4y50GFBQRTA39IuFs6F8NQ3NP4cVrpCHUfXVChB
# KiTq+crcZoAEFy9vBNDZcuE0ZDRXXg==
# SIG # End signature block
