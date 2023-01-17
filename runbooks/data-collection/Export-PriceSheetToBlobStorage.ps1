param(
    [Parameter(Mandatory = $false)]
    [string] $BillingAccountID,

    [Parameter(Mandatory = $false)]
    [string] $externalCloudEnvironment = "",

    [Parameter(Mandatory = $false)]
    [string] $externalTenantId = "",

    [Parameter(Mandatory = $false)]
    [string] $externalCredentialName = "",

    [Parameter(Mandatory = $false)] 
    [string] $billingPeriod = "" # YYYYMM format
)

$ErrorActionPreference = "Stop"

function Authenticate-AzureWithOption {
    param (
        [string] $authOption = "ManagedIdentity",
        [string] $cloudEnv = "AzureCloud"
    )

    switch ($authOption) {
        "RunAsAccount" { 
            $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
            Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnv -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
            break
        }
        "ManagedIdentity" { 
            Connect-AzAccount -Identity -EnvironmentName $cloudEnv
            break
        }
        Default {
            $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
            Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnv -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
            break
        }
    }        
}

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

# get Consumption exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_PriceSheetContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "pricesheetexports"
}

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    $externalCredential = Get-AutomationPSCredential -Name $externalCredentialName
}

$consumptionOffsetDays = [int] (Get-AutomationVariable -Name  "AzureOptimization_ConsumptionOffsetDays")
$meterCategories = Get-AutomationVariable -Name "AzureOptimization_PriceSheetMeterCategories" -ErrorAction SilentlyContinue
$meterRegions = Get-AutomationVariable -Name "AzureOptimization_PriceSheetMeterRegions" -ErrorAction SilentlyContinue
$BillingAccountIDVar = Get-AutomationVariable -Name  "AzureOptimization_BillingAccountID" -ErrorAction SilentlyContinue

Write-Output "Logging in to Azure with $authenticationOption..."

Authenticate-AzureWithOption -authOption $authenticationOption -cloudEnv $cloudEnvironment

# get reference to storage sink
Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    Connect-AzAccount -ServicePrincipal -EnvironmentName $externalCloudEnvironment -Tenant $externalTenantId -Credential $externalCredential 
    $cloudEnvironment = $externalCloudEnvironment   
}

# compute billing period

if ([string]::IsNullOrEmpty($billingPeriod))
{
    $billingPeriod = (Get-Date).Date.AddDays($consumptionOffsetDays * -1).ToString("yyyyMM")
}

if (-not([string]::IsNullOrEmpty($BillingAccountIDVar)))
{
    $BillingAccountID = $BillingAccountIDVar
}

if ([string]::IsNullOrEmpty($BillingAccountID))
{
    throw "Billing Account ID undefined. Use either the AzureOptimization_BillingAccountID variable or the BillingAccountID parameter"
}

if ($null -ne $meterCategories)
{
    $meterCategories = $meterCategories.Split(',')
}

if ($null -ne $meterRegions)
{
    $meterRegions = $meterRegions.Split(',')
}

Write-Output "Starting pricesheet export process for $billingPeriod billing period for Billing Account $BillingAccountID..."

$MaxTries = 9 # The typical Retry-After is set to 20 seconds. We'll give 3 minutes overall to download the pricesheet report

$PriceSheetApiPath = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountID/billingPeriods/$billingPeriod/providers/Microsoft.Consumption/pricesheets/download?api-version=2022-06-01&ln=en"

$result = Invoke-AzRestMethod -Path $PriceSheetApiPath -Method GET
$requestResultPath = $result.Headers.Location.PathAndQuery
if ($result.StatusCode -in (200,202))
{
    $tries = 0
    $requestSuccess = $false

    Write-Output "Obtained pricesheet results endpoint: $requestResultPath..."

    Write-Output "Was told to wait $($result.Headers.RetryAfter.Delta.TotalSeconds) seconds."

    $sleepSeconds = 60
    if ($result.Headers.RetryAfter.Delta.TotalSeconds -gt 0)
    {
        $sleepSeconds = $result.Headers.RetryAfter.Delta.TotalSeconds
    }

    do
    {
        $tries++
        Write-Output "Checking whether export is ready (try $tries)..."
        
        Start-Sleep -Seconds $sleepSeconds
        $downloadResult = Invoke-AzRestMethod -Method GET -Path $requestResultPath

        if ($downloadResult.StatusCode -eq 200)
        {

            Write-Output "Export is ready. Proceeding with CSV download..."

            $downloadUrl = ($downloadResult.Content | ConvertFrom-Json).properties.downloadUrl

            $csvExportPath = "$env:TEMP\pricesheet-$billingPeriod-$BillingAccountID.csv"
            $finalCsvExportPath = "$env:TEMP\pricesheet-$billingPeriod-$BillingAccountID-final.csv"

            Invoke-WebRequest -Uri $downloadUrl -OutFile $csvExportPath

            Write-Output "Blob downloaded to $csvExportPath successfully."

            Write-Output "Filtering data with meter categories ($($meterCategories -join ",")) and meter regions ($($meterRegions -join ",")) to $finalCsvExportPath..."

            $r = [IO.File]::OpenText($csvExportPath)
            $w = [System.IO.StreamWriter]::new($finalCsvExportPath)
            $lineCounter = 0
            while ($r.Peek() -ge 0) {
                $line = $r.ReadLine()
                $lineCounter++
                if ($lineCounter -eq 3)
                {
                    $line = $line.Replace(" ", "").Replace("-","").Replace("category", "Category").Replace("name","Name").Replace("sub", "Sub").Replace("region","Region").Replace("of","Of").Replace("measure","Measure").Replace("number","Number").Replace("price","Price").Replace("code","Code").Replace("quantity","Quantity").Replace("type","Type")
                    Write-Output "New headers: $line"
                    $w.WriteLine($line)
                }
                if ($lineCounter -gt 3)
                {
                    $categoryWriteLine = $false
                    $regionWriteLine = $false

                    if ($meterCategories.Count -gt 0)
                    {
                        foreach ($meterCategory in $meterCategories)
                        {
                            if ($line -match ",$meterCategory,")
                            {
                                $categoryWriteLine = $true
                                break
                            }
                        }    
                    }
                    else
                    {
                        $categoryWriteLine = $true
                    }                    

                    if ($meterRegions.Count -gt 0)
                    {
                        foreach ($meterRegion in $meterRegions)
                        {
                            if ($line -match ",$meterRegion,")
                            {
                                $regionWriteLine = $true
                                break
                            }
                        }    
                    }
                    else
                    {
                        $regionWriteLine = $true
                    }
                    if ($categoryWriteLine -and $regionWriteLine)
                    {
                        $w.WriteLine($line)
                    }
                }
            }
            $r.Dispose()
            $w.Close()
        
            $csvBlobName = [System.IO.Path]::GetFileName($finalCsvExportPath)
            $csvProperties = @{"ContentType" = "text/csv"};
            Set-AzStorageBlobContent -File $finalCsvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
                
            $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
            Write-Output "[$now] Uploaded $csvBlobName to Blob Storage..."

            Remove-Item -Path $csvExportPath -Force
        
            $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
            Write-Output "[$now] Removed $csvExportPath from local disk..."                    

            Remove-Item -Path $finalCsvExportPath -Force
        
            $now = (Get-Date).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
            Write-Output "[$now] Removed $finalCsvExportPath from local disk..."                    

            $requestSuccess = $true
        }
        elseif ($downloadResult.StatusCode -eq 202)
        {
            Write-Output "Was told to wait a bit more... $($downloadResult.Headers.RetryAfter.Delta.TotalSeconds) seconds."

            $sleepSeconds = 60
            if ($downloadResult.Headers.RetryAfter.Delta.TotalSeconds -gt 0)
            {
                $sleepSeconds = $downloadResult.Headers.RetryAfter.Delta.TotalSeconds
            }
        }
        elseif ($downloadResult.StatusCode -eq 401)
        {
            Write-Output "Had an authentication issue. Will login again and sleep just a couple of seconds."

            Authenticate-AzureWithOption -authOption $authenticationOption -cloudEnv $cloudEnvironment

            $sleepSeconds = 2
        }
        else
        {
            Write-Output "Got an unexpected response code: $($downloadResult.StatusCode)"
        }
    } 
    while (-not($requestSuccess) -and $tries -lt $MaxTries)

    if (-not($requestSuccess))
    {
        throw "Error returned by the Download PriceSheet API. Status Code: $($downloadResult.StatusCode). Message: $($downloadResult.Content)"
    }
    else
    {
        Write-Output "Export download processing complete."
    }
}
else
{
    if ($result.StatusCode -ne 204)
    {
        throw "Error returned by the Download PriceSheet API. Status Code: $($result.StatusCode). Message: $($result.Content)"
    }
    else
    {
        Write-Output "Request returned 204 No Content"
    }
}