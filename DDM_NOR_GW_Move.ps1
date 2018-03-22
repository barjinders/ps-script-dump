# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name} 

# Data input
$importPath = 'U:\Barjinder\DDM\NW\LS_NOR.csv'

# Environment variables
$vcName = ''
$nsxServerIP = ''
$vcUsername = 'administrator@vsphere.local'
$vcPassword =  ''


$EdgeName = ''
$dlrName = ''


#region Functions

function ConvertTo-DottedDecimalIP {
  <#
    .Synopsis
      Returns a dotted decimal IP address from either an unsigned 32-bit integer or a dotted binary string.
    .Description
      ConvertTo-DottedDecimalIP uses a regular expression match on the input string to convert to an IP address.
    .Parameter IPAddress
      A string representation of an IP address from either UInt32 or dotted binary.
  #>
  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [String]$IPAddress
  )

  process {
    Switch -RegEx ($IPAddress) {
      "([01]{8}.){3}[01]{8}" {
        return [String]::Join('.', $( $IPAddress.Split('.') | ForEach-Object { [Convert]::ToUInt32($_, 2) } ))
      }
      "\d" {
        $IPAddress = [UInt32]$IPAddress
        $DottedIP = $( For ($i = 3; $i -gt -1; $i--) {
          $Remainder = $IPAddress % [Math]::Pow(256, $i)
          ($IPAddress - $Remainder) / [Math]::Pow(256, $i)
          $IPAddress = $Remainder
         } )
      
        return [String]::Join('.', $DottedIP)
      }
      default {
        Write-Error "Cannot convert this format"
      }
    }
  }

}

function ConvertTo-DecimalIP {
  <#
    .Synopsis
      Converts a Decimal IP address into a 32-bit unsigned integer.
    .Description
      ConvertTo-DecimalIP takes a decimal IP, uses a shift-like operation on each octet and returns a single UInt32 value.
    .Parameter IPAddress
      An IP Address to convert.
  #>

  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [Net.IPAddress]$IPAddress
  )
  process {
    $i = 3; $DecimalIP = 0;
    $IPAddress.GetAddressBytes() | ForEach-Object { $DecimalIP += $_ * [Math]::Pow(256, $i); $i-- }
    return [UInt32]$DecimalIP
  }
}

function Get-NetworkAddress {
  <#
    .Synopsis
      Takes an IP address and subnet mask then calculates the network address for the range.
    .Description
      Get-NetworkAddress returns the network address for a subnet by performing a bitwise AND
      operation against the decimal forms of the IP address and subnet mask. Get-NetworkAddress
      expects both the IP address and subnet mask in dotted decimal format.
    .Parameter IPAddress
      Any IP address within the network range.
    .Parameter SubnetMask
      The subnet mask for the network.
  #>

  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [Net.IPAddress]$IPAddress,
   
    [Parameter(Mandatory = $true, Position = 1)]
    [Alias("Mask")]
    [Net.IPAddress]$SubnetMask
  )

  process {
    return ConvertTo-DottedDecimalIP ((ConvertTo-DecimalIP $IPAddress) -band (ConvertTo-DecimalIP $SubnetMask))
  }
}

function ConvertTo-Mask {
  <#
    .Synopsis
      Returns a dotted decimal subnet mask from a mask length.
    .Description
      ConvertTo-Mask returns a subnet mask in dotted decimal format from an integer value ranging
      between 0 and 32. ConvertTo-Mask first creates a binary string from the length, converts
      that to an unsigned 32-bit integer then calls ConvertTo-DottedDecimalIP to complete the operation.
    .Parameter MaskLength
      The number of bits which must be masked.
  #>

  [CmdLetBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [Alias("Length")]
    [ValidateRange(0, 32)]
    $MaskLength
  )

  Process {
    return ConvertTo-DottedDecimalIP ([Convert]::ToUInt32($(("1" * $MaskLength).PadRight(32, "0")), 2))
  }
}
#endregion


# Connect to NSX server
Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue | Out-Null

# validate connection
if(($DefaultNSXConnection.VIConnection.name -eq $vcName) -and ($DefaultNSXConnection.Server -eq $nsxServerIP)){
    Write-host "Connection to NSX server $($DefaultNSXConnection.Server) was established successfully"
}
else{
    Write-host -Fore:red "Connection to NSX server failed. Exiting..."
    Exit
}

 
#import CSV
$csv = import-csv -Path $importPath

 
# validate CSV file location
if(!$ImportPath) {
    Logger "Red" 'Please provide valid CSV file path using -ImportPath switch, exiting..'
    DisconnectVC
    exit
}
if(!(Test-Path -Path $ImportPath -PathType:Leaf)) {
    Logger "Red" 'Please provide valid CSV file path using -ImportPath switch, exiting..'
    DisconnectVC
    exit
}

# validate CSV file content
$invalidEntry = @()
foreach ($entry in $csv){
    'lsName','PrimaryAddress', 'PrefixLength' |
        foreach{
            if($entry.$_ -contains ""){
                    $InvalidEntry += $entry.lsName 
            }
        }
}

# Reporting the Churnsheet validation results
if ($invalidEntry){
    $invalidEntry = $invalidEntry | select -Unique
    Write-Host -fore:Red "The following logical switches have missing information in the churnsheet. Exiting..."
    Write-Host -fore:Yellow "$($invalidEntry | ft)"
    Exit
    }
else{
    Write-Host -fore:Green "All mandatory values in the churnsheet are present`n"
    }



#region Script blocks


$UpdateStaticRouteOnEdge = {
   Param (
    $EdgeName,
    $network,
    $edgeUplinkIP,
    $DefaultNSXConnection
   )  
    $edgeStaticRouting = get-nsxedge -name EdgeName -Connection$ DefaultNSXConnection | Get-NsxEdgeRouting
    $edgeStaticRouting.staticRouting.staticRoutes.route | %{if($_.network -eq $network){$_.nextHop = $NewEdgeUplinkIP}}
    Set-NsxEdgeRouting -EdgeRouting $edgeStaticRouting

    #Get-NsxEdge -name $EdgeName -Connection $DefaultNSXConnection | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP  | Remove-NsxEdgeStaticRoute -Confirm:$false -Connection $DefaultNSXConnection
   
}


$RemoveDlrInterface = 
{
   Param (
    $dlrIntName,
    $dlr_Name,
    $DefaultNSXConnection
   )  
    $dlr = Get-NsxLogicalRouter -Name $dlr_Name -Connection $DefaultNSXConnection
    #$LS = Get-NsxLogicalSwitch -Name $lsname -Connection $DefaultNSXConnection
    Get-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $dlrIntName | Remove-NsxLogicalRouterInterface -Confirm:$false
}


$RemoveStaticRoutefromEdge = {
   Param (
    $EdgeName,
    $network,
    $dlrUplinkIP,
    $DefaultNSXConnection
   )  
 
    Get-NsxEdge -name $EdgeName -Connection $DefaultNSXConnection | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP  | Remove-NsxEdgeStaticRoute -Confirm:$false -Connection $DefaultNSXConnection
   
}


#endregion


$dlr = Get-NsxLogicalRouter -Name $dlrName
$dlrUplinkIP = ($dlr.interfaces.interface | ?{$_.type -eq "Uplink"}).addressgroups.addressgroup.primaryAddress

# Move the network to the Edge


foreach($row in $csv)
{

    # get next available Edge interface
    $edgeInterface =  get-nsxedge $EdgeName | Get-NsxEdgeInterface |  ?{$_.isconnected -eq 'false'} | select -First 1
    if(!$edgeInterface)
    {
        Write-host -Fore:Red "There are no available interfaces on the Edge appliance $EdgeName. Exiting..."
        Exit
    }

    # get logical switch
    $ls = Get-NsxLogicalSwitch -Name $row.lsname
    If(!$ls)
    {
        Write-host -Fore:Red "There are no available interfaces on the Edge appliance. Exiting..."
        Exit
    }

    # get logical switch details
    $dlrIntName = ($dlr.interfaces.interface | ?{$_.connectedToName -eq $row.lsname}).name
    $primaryAddress = ($dlr.interfaces.interface | ?{$_.connectedToName -eq $row.lsname}).addressGroups.addressGroup.primaryAddress
    $prefixLength = ($dlr.interfaces.interface | ?{$_.connectedToName -eq $row.lsname}).addressGroups.addressGroup.subnetPrefixLength

    do {
        $start = Read-Host -Prompt "Type 'continue' to start network cutover for logical switch $($row.lsName)"
    } while($start -ne 'continue')


    # Remove static routes from Edge
    $subnet = Get-NetworkAddress $primaryAddress  $(convertto-mask $prefixLength)
    $network = $subnet+"/"+$prefixLength
    Start-Job -ScriptBlock $RemoveStaticRoutefromEdge -ArgumentList $EdgeName,$network,$dlrUplinkIP,$DefaultNSXConnection


    $i = 1
    do
    {
        sleep 1
        $i++
    }
    while(Get-NsxEdge -name $EdgeName | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP)
       
    write-host "It took $i seconds to remove static route" 

    # Disconnect LS from DLR
    $lsName = $row.lsName

    Start-Job -ScriptBlock $RemoveDlrInterface -ArgumentList $dlrIntName,$dlrName,$DefaultNSXConnection


    # Connect LS to Edge

    Set-NsxEdgeInterface -Interface $edgeInterface -Name $dlrIntName -Type internal -ConnectedTo $ls -PrimaryAddress $primaryAddress -SubnetPrefixLength $prefixLength -Connected:$true


    # check that jobs are completed
    do{
    sleep 1
    }while (get-job | ?{$_.state -eq "Running"})


    # Validation 

   # validate static route
    if(Get-NsxEdge -name $EdgeName | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP){
        Write-host -Fore:red "Failed to remove static route to $EdgeName"
    }
    else{
        Write-host -Fore:green "Static route was succesfully removed from $EdgeName"
    }

    #Validate that LS is disconnected from DLR
    if(Get-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $dlrIntName)
    {
        Write-host -Fore:Red "Failed to disconnect logical switch $($row.lsname) from $dlrName"
    }
    else
    {
       Write-host -Fore:Green "Successfully disconnnected logical switch $($row.lsname) from $dlrName" 
    }

    #Validate that all LS are connected to Edge
    $edge = Get-NsxEdge $EdgeName
    $edgeInt = Get-NsxEdgeInterface -Edge $Edge -Name $dlrIntName
    if($edgeInt.addressgroups.addressgroup.primaryAddress -eq $primaryAddress)
    {
        Write-host -Fore:Green "Successfully connected logical switch $($row.lsname) to edge appliance $edgeName"
    }
    else
    {
       
       Write-host -Fore:Red "Failed to connect logical switch $($row.lsname) to edge appliance $edgeName"
    }

    # validate that LS default gateway is pingable
    if (Test-Connection -ComputerName $primaryAddress -Quiet)
    {
         Write-host -Fore:Green "The default gateway of logical switch $($row.lsname) was successfully pinged"
    }
    else
    {        
         Write-host -Fore:Green "Failed to ping the default gateway of logical switch $($row.lsname)"   
    }
}
