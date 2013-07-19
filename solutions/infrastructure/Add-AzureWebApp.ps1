<#
.Synopsis
   Add two virtual machines to Azure subscription, deploy the provided WebPI application to the front end machine, 
   and conect it to the back end SQL Server virtual machine.
.DESCRIPTION
   This is a sample script demonstrating how to deploy a virtual machine that will host an application published on
   the Web Platform Installer catalog and will connect to a back end SQL Server.
.EXAMPLE
    Use the following to query an image name for the back end

    (Get-AzureVMImage | 
              where {($_.Label -ilike "*SQL Server*") -and ($_.PublisherName -ilike "*Microsoft*")} | 
              Sort-Object PublishedDate)[0] 

    And the following for the front end server
    (Get-AzureVMImage | 
              where {($_.Label -ilike "*Windows Server*") -and ($_.PublisherName -ilike "*Microsoft Windows Server Grou*")} | 
              Sort-Object PublishedDate)[0] 

   Add-AzureWebApp.ps1 -ServiceName mytestservice -Location "West US" -WebPIApplicationName BlogengineNET -WebPIApplicationAnswerFile .\BlogengineNet.app -FrontEndComputerName frontend `
    -FrontEndInstanceSize Small -BackEndComputerName backend -BackEndInstanceSize Small -AffinityGroupName beaffinity
.INPUTS
   none
.OUTPUTS
   none
#>
param
(
    
    # Name of the service the VMs will be deployed to. If the service exists, the VMs will be deployed ot this service, otherwise, it will be created.
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # The target region the VMs will be deployed to. This is used to create the affinity group if it does not exist. If the affinity group exists, but in a different region, the commandlet displays a warning.
    [Parameter(Mandatory = $true)]
    [String]
    $Location,
       
    # The host name for the SQL server.
    [Parameter(Mandatory = $true)]
    [String]
    $ComputerName,
    
    # Instance size for the SQL server. We will use 4 disks, so it has to be a minimum Medium size. The validate set checks that.
    [Parameter(Mandatory = $true)]
    [ValidateSet("Medium", "Large", "ExtraLarge", "A6", "A7")]
    [String]
    $InstanceSize)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

<#
.SYNOPSIS
    Adds a new affinity group if it does not exist.
.DESCRIPTION
   Looks up the current subscription's (as set by Set-AzureSubscription cmdlet) affinity groups and creates a new
   affinity group if it does not exist.
.EXAMPLE
   New-AzureAffinityGroupIfNotExists -AffinityGroupNme newAffinityGroup -Locstion "West US"
.INPUTS
   None
.OUTPUTS
   None
#>
function New-AzureAffinityGroupIfNotExists
{
    param
    (
        
        # Name of the affinity group
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Location where the affinity group will be pointing to
        [Parameter(Mandatory = $true)]
        [String]
        $Location)
    
    $affinityGroup = Get-AzureAffinityGroup -Name $AffinityGroupName -ErrorAction SilentlyContinue
    if ($affinityGroup -eq $null)
    {
        New-AzureAffinityGroup -Name $AffinityGroupName -Location $Location -Label $AffinityGroupName `
        -ErrorVariable lastError -ErrorAction SilentlyContinue | Out-Null
        if (!($?))
        {
            throw "Cannot create the affinity group $AffinityGroupName on $Location"
        }
        Write-Verbose "Created affinity group $AffinityGroupName"
    }
    else
    {
        if ($affinityGroup.Location -ne $Location)
        {
            Write-Warning "Affinity group with name $AffinityGroupName already exists but in location `
            $affinityGroup.Location, not in $Location"
        }
    }
}

<#
.SYNOPSIS
   Sets the provided values in the VNet file of a subscription's VNet file 
.DESCRIPTION
   It sets the VNetSiteName and AffinityGroup of a given subscription's VNEt configuration file.
.EXAMPLE
    Set-VNetFileValues -FilePath c:\temp\servvnet.xml -VNet testvnet -AffinityGroupName affinityGroup1
.INPUTS
   None
.OUTPUTS
   None
#>
function Set-VNetFileValues
{
    [CmdletBinding()]
    param (
        
        # The path to the exported VNet file
        [String]$FilePath, 
        
        # Name of the new VNet site
        [String]$VNet, 
        
        # The affinity group the new Vnet site will be associated with
        [String]$AffinityGroupName, 
        
        # Address prefix for the Vnet. For the sake of examples in this scripts, the smallest address space possible for Azure is default
        [String]$VNetAddressPrefix = "10.0.0.0/8", 
        
        # The name of the subnet to be added to the Vnet
        [String] $DefaultSubnetName = "Subnet-1", 
        
        # Addres space for the Subnet
        [String] $SubnetAddressPrefix = "10.0.0.0/8")
    
    [Xml]$xml = New-Object XML
    $xml.Load($filePath)
    
    $foundVirtualNetworkSite = $null
    if (($xml.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites -ne $null) -and ($xml.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.Length -gt 0))
    {
        $foundVirtualNetworkSite = $xml.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.VirtualNetworkSite | Where-Object {$_.name -eq $VNet}
    }
    
    if ($foundVirtualNetworkSite -ne $null)
    {
        $foundVirtualNetworkSite.AffinityGroup = $AffinityGroupName
    }
    else
    {
        $virtualNetworkSites = $xml.NetworkConfiguration.VirtualNetworkConfiguration.GetElementsByTagName("VirtualNetworkSites")
        if ($null -ne $virtualNetworkSites)
        {
            
            $virtualNetworkElement = $xml.CreateElement("VirtualNetworkSite", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            
            $vNetSiteNameAttribute = $xml.CreateAttribute("name")
            $vNetSiteNameAttribute.InnerText = $VNet
            $virtualNetworkElement.Attributes.Append($vNetSiteNameAttribute) | Out-Null
            
            $affinityGroupAttribute = $xml.CreateAttribute("AffinityGroup")
            $affinityGroupAttribute.InnerText = $AffinityGroupName
            $virtualNetworkElement.Attributes.Append($affinityGroupAttribute) | Out-Null
            
            $addressSpaceElement = $xml.CreateElement("AddressSpace", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")            
            $addressPrefixElement = $xml.CreateElement("AddressPrefix", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $addressPrefixElement.InnerText = $VNetAddressPrefix
            $addressSpaceElement.AppendChild($addressPrefixElement) | Out-Null
            $virtualNetworkElement.AppendChild($addressSpaceElement) | Out-Null
            
            $subnetsElement = $xml.CreateElement("Subnets", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetElement = $xml.CreateElement("Subnet", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetNameAttribute = $xml.CreateAttribute("name")
            $subnetNameAttribute.InnerText = $DefaultSubnetName
            $subnetElement.Attributes.Append($subnetNameAttribute) | Out-Null
            $subnetAddressPrefixElement = $xml.CreateElement("AddressPrefix", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetAddressPrefixElement.InnerText = $SubnetAddressPrefix
            $subnetElement.AppendChild($subnetAddressPrefixElement) | Out-Null
            $subnetsElement.AppendChild($subnetElement) | Out-Null
            $virtualNetworkElement.AppendChild($subnetsElement) | Out-Null
            
            $virtualNetworkSites.AppendChild($virtualNetworkElement) | Out-Null
        }
        else
        {
            throw "Can't find 'VirtualNetworkSite' tag"
        }
    }
    
    $xml.Save($filePath)
}

<#
.SYNOPSIS
   Creates a Virtual Network Site if it does not exist and sets the subnet details.
.DESCRIPTION
   Creates the VNet site if it does not exist. It first downloads the neetwork configuration for the subscription.
   If there is no network configuration, it creates an empty one first using the Add-AzureVnetConfigurationFile helper
   function, then updates the network file with the provided Vnet settings also by adding the subnet.
.EXAMPLE
   New-VNetSiteIfNotExists -VNetSiteName testVnet -SubnetName mongoSubnet -AffinityGroupName mongoAffinity
#>
function New-VNetSiteIfNotExists
{
    [CmdletBinding()]
    param
    (
        
        # Name of the Vnet site
        [Parameter(Mandatory = $true)]
        [String]
        $VNetSiteName,
        
        # Name of the subnet
        [Parameter(Mandatory = $true)]
        [String]
        $SubnetName,
        
        # THe affinity group the vnet will be associated with
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Address prefix for the Vnet. For the sake of examples in this scripts, 
        
        # the smallest address space possible for Azure is default
        [String]$VNetAddressPrefix = "10.0.0.0/8", 
        
        # The name of the subnet to be added to the Vnet
        [String] $DefaultSubnetName = "Subnet-1", 
        
        # Addres space for the Subnet
        [String] $SubnetAddressPrefix = "10.0.0.0/8")
    
    # Check the VNet site, and add it to the configuration if it does not exist.
    $vNet = Get-AzureVNetSite -VNetName $VNetSiteName -ErrorAction SilentlyContinue
    if ($vNet -eq $null)
    {
        $vNetFilePath = "$env:temp\$AffinityGroupName" + "vnet.xml"
        Get-AzureVNetConfig -ExportToFile $vNetFilePath | Out-Null
        if (!(Test-Path $vNetFilePath))
        {
            Add-AzureVnetConfigurationFile -Path $vNetFilePath
        }
        
        Set-VNetFileValues -FilePath $vNetFilePath -VNet $vNetSiteName -DefaultSubnetName $SubnetName -AffinityGroup $AffinityGroupName -VNetAddressPrefix $VNetAddressPrefix -SubnetAddressPrefix $SubnetAddressPrefix
        Set-AzureVNetConfig -ConfigurationPath $vNetFilePath -ErrorAction SilentlyContinue -ErrorVariable errorVariable | Out-Null
        if (!($?))
        {
            throw "Cannot set the vnet configuration for the subscription, please see the file $vNetFilePath. Error detail is: $errorVariable"
        }
        Write-Verbose "Modified and saved the VNET Configuration for the subscription"
        
        Remove-Item $vNetFilePath
    }
}

<#
.SYNOPSIS
  Sends a file to a remote session.
.EXAMPLE
  $remoteSession = New-PSSession -ConnectionUri $remoteWinRmUri.AbsoluteUri -Credential $credential
  Send-File -Source "c:\temp\myappdata.xml" -Destination "c:\temp\myappdata.xml" $remoteSession
#>
function Send-File
{
    param (
        
        ## The path on the local computer
        [Parameter(Mandatory = $true)]
        $Source,
        
        ## The target path on the remote computer
        [Parameter(Mandatory = $true)]
        $Destination,
        
        ## The session that represents the remote computer
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] $Session)
    
    $remoteScript =
    {
        param ($destination, $bytes)
        
        ## Convert the destination path to a full filesystem path (to support relative paths)
        $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($destination)
        
        ## Write the content to the new file
        $file = [IO.File]::Open($destination, "OpenOrCreate")
        $null = $file.Seek(0, "End")
        $null = $file.Write($bytes, 0, $bytes.Length)
        $file.Close()
    }
    
    ## Get the source file, and then start reading its content
    $sourceFile = Get-Item $source
    
    ## Delete the previously-existing file if it exists
    Invoke-Command -Session $session {
        if (Test-Path $args[0])
        {
            Remove-Item $args[0]
        }
        
        $destinationDirectory = Split-Path -LiteralPath $args[0]
        if (!(Test-Path $destinationDirectory))
        {
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
        }
    } -ArgumentList $Destination
    
    ## Now break it into chunks to stream
    Write-Progress -Activity "Sending $Source" -Status "Preparing file"
    $streamSize = 1MB
    $position = 0
    $rawBytes = New-Object byte[] $streamSize
    $file = [IO.File]::OpenRead($sourceFile.FullName)
    while (($read = $file.Read($rawBytes, 0, $streamSize)) -gt 0)
    {
        Write-Progress -Activity "Writing $Destination" `
        -Status "Sending file" `
        -PercentComplete ($position / $sourceFile.Length * 100)
        
        ## Ensure that our array is the same size as what we read
        
        ## from disk
        if ($read -ne $rawBytes.Length)
        {
            [Array]::Resize( [ref] $rawBytes, $read)
        }
        
        ## And send that array to the remote system
        Invoke-Command -Session $session $remoteScript `
        -ArgumentList $destination, $rawBytes
        
        ## Ensure that our array is the same size as what we read
        
        ## from disk
        if ($rawBytes.Length -ne $streamSize)
        {
            [Array]::Resize( [ref] $rawBytes, $streamSize)
        }
        [GC]::Collect()
        $position += $read
    }
    
    $file.Close()
    
    ## Show the result
    Invoke-Command -Session $session { Get-Item $args[0] } -ArgumentList $Destination
}

<#
.SYNOPSIS
   Installs a WinRm certificate to the local store
.DESCRIPTION
   Gets the WinRM certificate from the Virtual Machine in the Service Name specified, and 
   installs it on the Current User's personal store.
.EXAMPLE
    Install-WinRmCertificate -ServiceName testservice -vmName testVm
.INPUTS
   None
.OUTPUTS
   Microsoft.WindowsAzure.Management.ServiceManagement.Model.OSImageContext
#>
function Install-WinRmCertificate($ServiceName, $VMName)
{
    $vm = Get-AzureVM -ServiceName $ServiceName -Name $VMName
    $winRmCertificateThumbprint = $vm.VM.DefaultWinRMCertificateThumbprint
    
    $winRmCertificate = Get-AzureCertificate -ServiceName $ServiceName -Thumbprint $winRmCertificateThumbprint -ThumbprintAlgorithm sha1
    
    $installedCert = Get-Item Cert:\CurrentUser\My\$winRmCertificateThumbprint -ErrorAction SilentlyContinue
    
    if ($installedCert -eq $null)
    {
        $certBytes = [System.Convert]::FromBase64String($winRmCertificate.Data)
        $x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate
        $x509Cert.Import($certBytes)
        
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
        $store.Open("ReadWrite")
        $store.Add($x509Cert)
        $store.Close()
    }
}

# Create the affinity group
New-AzureAffinityGroupIfNotExists -AffinityGroupName $AffinityGroupName -Location $Location

# Configure the VNET
$vNetSiteName = ($WebPIApplicationName + "vnet").ToLower()
$subnetName = "webappsubnet"
New-VnetSiteIfNotExists -VNetSiteName $vNetSiteName -SubnetName $subnetName -AffinityGroupName $AffinityGroupName

$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $FrontEndComputerName -ErrorAction SilentlyContinue
if ($existingVm -ne $null)
{
    throw "A VM with name $FrontEndComputerName exists on $ServiceName"
}

$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $BackEndComputerName -ErrorAction SilentlyContinue
if ($existingVm -ne $null)
{
    throw "A VM with name $BackEndComputerName exists on $ServiceName"
}

# Get latest Images
$windowsServerImage = "a699494373c04fc0bc8f2bb1389d6106__Windows-Server-2012-Datacenter-201305.01-en.us-127GB.vhd"
$sqlServerImage = "fb83b3509582419d99629ce476bcb5c8__Microsoft-SQL-Server-2012SP1-Enterprise-CY13SU04-SQL2012-SP1-11.0.3350.0-Win2012"

$vms = @()

$credential = Get-Credential

$vms += New-AzureVMConfig -Name $FrontEndComputerName -InstanceSize $FrontEndInstanceSize `
            -ImageName $windowsServerImage | 
        Add-AzureEndpoint -Name "http" -Protocol tcp -LocalPort 80 -PublicPort 80 | 
        Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username `
            -Password $credential.GetNetworkCredential().password | 
        Set-AzureSubnet -SubnetNames $subnetName

$vms += New-AzureVMConfig -Name $BackEndComputerName -InstanceSize $BackEndInstanceSize `
            -ImageName $sqlServerImage | 
        Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username `
            -Password $credential.GetNetworkCredential().password | 
        Set-AzureSubnet -SubnetNames $subnetName

if (Test-AzureName -Service -Name $ServiceName)
{
    New-AzureVM -ServiceName $ServiceName -VMs $vms -VNetName $vNetSiteName -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs."
    }
} 
else
{
    New-AzureVM -ServiceName $ServiceName -AffinityGroup $AffinityGroupName -VMs $vms -VNetName $vNetSiteName -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs and the cloud service $ServiceName"
    }
}

# prepare to run the remote execution

# Get the RemotePS/WinRM Uri to connect to
$frontEndwinRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $FrontEndComputerName
$backEndwinRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $BackEndComputerName

Install-WinRmCertificate $ServiceName $FrontEndComputerName
Install-WinRmCertificate $ServiceName $BackEndComputerName

$remoteScriptsDirectory = "c:\Scripts"
$remoteScriptFileName = "RemoteScripts.ps1"

# Copy the required files to the remote server
$remoteSession = New-PSSession -ConnectionUri $frontEndwinRmUri.AbsoluteUri -Credential $credential
$sourcePath = "$PSScriptRoot\$remoteScriptFileName"
$remoteScriptFilePath = "$remoteScriptsDirectory\$remoteScriptFileName"
Send-File $sourcePath $remoteScriptFilePath $remoteSession

$answerFileName = Split-Path -Leaf $WebPIApplicationAnswerFile
$answerFilePath = "$remoteScriptsDirectory\$answerFileName"
Send-File $WebPIApplicationAnswerFile $answerFilePath $remoteSession
Remove-PSSession -InstanceId $remoteSession.InstanceId

# Run the install script for the WebPI application
$runInstallScript = 
{
    param ([String]$WebPiApplication, [String]$scriptFilePath, [String] $AnswerFilePath)
    
    # Usual recommendation is not to set the execution policy to a potentially less restrictive setting then what

    # may have been already set, such as AllSigned. However, in this sample, we know we are creating this VM from
    
    # scratch and we know the initial setting.
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    
    # Install .NET 3.5 seperately, as it fails through WebPI dependencies install
    Import-Module ServerManager
    Add-Windowsfeature -Name NET-Framework-Features | Out-Null
    Add-Windowsfeature -Name Web-Asp-Net45 | Out-Null
    
    . $scriptFilePath
    
    Install-WebPiApplication -ApplicationId $WebPiApplication -AnswerFile $AnswerFilePath
}
$argumentList = @(
    $WebPIApplicationName, 
    $remoteScriptFilePath, 
    $answerFilePath)

Invoke-Command -ConnectionUri $frontEndwinRmUri.ToString() -Credential $credential -ScriptBlock $runInstallScript `
-ArgumentList $argumentList

$setMixedSqlScript = 
{
    param ([String] $password)
    
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    
    # Importing the 
    Import-Module sqlps
    
    $sqlServer = New-Object ('Microsoft.SqlServer.Management.Smo.Server')  .
    
    $sqlServer.Settings.LoginMode = [Microsoft.SqlServer.Management.SMO.ServerLoginMode]::Mixed
    $sqlServer.Alter()
    
    # Now restart the service
    $sqlService = Get-Service -Name MSSQLSERVER
    $sqlService.Stop()
    
    $sqlService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped)
    $sqlService.Start()
    $sqlService.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running)
    
    $sqlServer = New-Object ('Microsoft.SqlServer.Management.Smo.Server')  .
    $sqlServer.Logins.Item('sa').ChangePassword($password)
    $sqlServer.Logins.Item('sa').Alter()
    
    # Create the firewall rule for the SQL Server access
    netsh advfirewall firewall add rule name= "SQLServer" dir=in action=allow protocol=TCP localport=1433
}
Invoke-Command -ConnectionUri $backEndwinRmUri.ToString() -Credential $credential -ScriptBlock $setMixedSqlScript `
-ArgumentList @($credential.GetNetworkCredential().password)
