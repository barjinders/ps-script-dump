# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}
#Connect-NsxServer -NsxServer  -Username  -Password  -VIUserName  -VIPassword 

$importPath = ''
$vcName = ''
$nsxServerIP = ''
$vcUsername = ''
$vcPassword =  ''
$tzName = ''
$dlrName = ''
$routingEdges = @()

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

function Add-DHCPrelayToDLR{
    param(
    [Parameter(Mandatory = $True)]
    [string]$giAddress,
    [Parameter(Mandatory = $True)]
    [string]$dlrName 
    )

    $dlr = Get-NsxLogicalRouter $dlrName



    # create new nodes
    $newRelayAgent = $dlr.OwnerDocument.CreateElement("relayAgent")
    $newvnicIndex = $dlr.OwnerDocument.CreateElement("vnicIndex")
    $newgiAddress = $dlr.OwnerDocument.CreateElement("giAddress")


    # link property nodes to the Relay Agent node
    $newRelayAgent.AppendChild($newvnicIndex)
    $newRelayAgent.AppendChild($newgiAddress)

    $newRelayAgent.vnicIndex = ($dlr.interfaces.interface | ?{$_.addressGroups.addressGroup.primaryAddress -eq $giAddress}).index
    $newRelayAgent.giAddress = $giAddress 
    
    # Check if RelayAgents exists
    if(!$dlr.features.dhcp.relay.SelectSingleNode("relayAgents")){
        $newRelayAgents = $dlr.OwnerDocument.CreateElement("relayAgents")
        $newRelayAgents.AppendChild($newRelayAgent)
        $dlr.features.dhcp.relay.AppendChild($newRelayAgents)
    }
    else{
        $dlr.features.dhcp.relay.relayAgents.AppendChild($newRelayAgent)
    }
    

    # Update Values 
    
    $dlr | Set-NsxLogicalRouter -Confirm:$false
}
#endregion

# Connect to NSX server
Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue | Out-Null

# validate connection
if(($DefaultNSXConnection.VIConnection.name -eq $vcName) -and ($DefaultNSXConnection.Server -eq $nsxServerIP)){
    Write-host "Connection to VMnomad NSX server was established successfully"
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



# collecting objects

$tz = Get-NsxTransportZone $tzName
$logicalSwitches = $tz | Get-NsxLogicalSwitch
$dlr = Get-NsxLogicalRouter -Name $dlrName
$dlrUplinkIP = ($dlr.interfaces.interface | ?{$_.type -eq "Uplink"}).addressgroups.addressgroup.primaryAddress

$invalidEntry = @()
# validate all logsical switches are present
foreach($entry in $csv){
    if($logicalSwitches.name -notcontains $entry.lsname){
        $invalidEntry += $entry.lsname
    }
}

# Reporting the Churnsheet validation results
if ($invalidEntry){
    $invalidEntry = $invalidEntry | select -Unique
    Write-Host -fore:Red "The following logical switches are not present in transport zone $tzname."
    Write-Host -fore:Yellow "$($invalidEntry | ft)"
    Exit
    }
else{
    Write-Host -fore:Green "All logical switches are present in transport zone $tzname`n"
    }


# Validate DHCP Server is configured
if(!$dlr.features.dhcp.relay.relayServer.ipAddress){
    Write-host -fore:Red "There is not DHCP Relay Server configured on logical router $dlr"
}
else{
    Write-host -fore:Green "The logical router $dlr has DHCP Relay Server configured"
}


# Script Blocks
$ConnectLStoDLR = {
   Param (
    $lsName,
    $dlrName,
    $primaryAddress,
    $prefixLength,
    $DefaultNSXConnection
   )   
    $dlr = Get-NsxLogicalRouter -Name $dlrName -Connection $DefaultNSXConnection
    $LS = Get-NsxLogicalSwitch -Name $lsname -Connection $DefaultNSXConnection
  
    New-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $lsName -Type internal -ConnectedTo $LS -PrimaryAddress $primaryAddress  -SubnetPrefixLength $prefixLength 
}

$DisableL2VPN = {
   Param (
    $lsID,
    $DefaultNSXConnection
   )   

    $edge = Get-NsxEdge -Connection $DefaultNSXConnection |  ?{$_.vnics.vnic.subinterfaces.subinterface.logicalswitchid -eq $lsID}
    
    (($edge.vnics.vnic | ?{$_.Type -eq "Trunk"}).subinterfaces.subinterface | ?{$_.logicalSwitchID -eq $lsID}).isConnected = 'false'
    $edge | Set-NsxEdge -Confirm:$false -Connection $DefaultNSXConnection
}

$AddStaticRouteToEdge = {
   Param (
    $routingEdgeName,
    $network,
    $dlrUplinkIP,
    $DefaultNSXConnection
   )   

    Get-NsxEdge -name $routingEdgeName -Connection $DefaultNSXConnection | Get-NsxEdgeRouting  | New-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP -confirm:$false -Connection $DefaultNSXConnection
    
}



foreach($row in $csv){

    do {
        $start = Read-Host -Prompt "Type 'continue' to start network cutover for logical switch $($row.lsName)"
    } while($start -ne 'continue')


    # Connect LS to DLR
    
    $lsName = $row.lsName
    $primaryAddress = $row.primaryAddress
    $prefixLength = $row.prefixLength

    Start-Job -name ConnectLStoDLR -ScriptBlock $ConnectLStoDLR -ArgumentList $lsName,$dlrName,$primaryAddress,$prefixLength,$DefaultNSXConnection

  
    #  Disable L2 VPN
    $lsID = ($logicalSwitches | ?{$_.name -eq $row.lsName}).objectID
    Start-Job -name DisableL2VPN -ScriptBlock $DisableL2VPN -ArgumentList $lsID,$DefaultNSXConnection


    # Add static routes to Edge
    $subnet = Get-NetworkAddress $row.PrimaryAddress  $(convertto-mask $row.PrefixLength) 
    $network = $subnet+"/"+$row.PrefixLength
    foreach($routingEdgeName in $routingEdges){
        Start-Job -name $('AddStaticRouteTo_'+$routingEdgeName)-ScriptBlock $AddStaticRouteToEdge -ArgumentList $routingEdgeName,$network,$dlrUplinkIP,$DefaultNSXConnection
    }

    $jobN = (get-job | ?{$_.state -eq "Running"}).count

    # check that jobs are completed
    do{
    sleep 1
    }while (get-job | ?{$_.state -eq "Running"})


    # Validate LS to DLR connection
    if(Get-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $lsname){
        Write-host -Fore:green "`nLogical switch $lsname was succesfully connected to DLR $($dlr.name)"
        $validateDLR = 'Ok'
    }
    else{
        Write-host -Fore:red "`nLogical switch $lsname failed to connect to DLR $($dlr.name) "  
    }

    # Validate L2 VPN Disable
    $edge = Get-NsxEdge|  ?{$_.vnics.vnic.subinterfaces.subinterface.logicalswitchid -eq $lsID}
    if((($edge.vnics.vnic | ?{$_.Type -eq "Trunk"}).subinterfaces.subinterface | ?{$_.logicalSwitchID -eq $lsID}).isConnected -eq "false"){
        Write-host -Fore:green "L2 VPN was successfully disabled for $lsname"
        $validateL2VPN = 'Ok'
    }
    else{
        Write-host -Fore:red "Failed to disable L2 VPN for $lsname"
    }

    # validate static route
    foreach($routingEdgeName in $routingEdges){
        if(Get-NsxEdge -name $routingEdgeName | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP) {
            Write-host -Fore:green "Static route was succesfully added to $routingEdgeName"
            $validateSR = 'Ok'
        }
        else {
            Write-host -Fore:red "Failed to add static route to $routingEdgeName"
        }
    }


    # Enable DHCP Relay Agent
    if(($validateDLR -eq 'Ok') -and ($validateL2VPN -eq 'Ok') -and ($validateSR -eq 'Ok')){
        Add-DHCPrelaytoDLR -dlrName $dlrName -giAddress $primaryAddress

        if((get-nsxlogicalrouter -name $dlrName).features.dhcp.relay.relayAgents.relayAgent | ?{$_.giAddress -eq $primaryAddress}){
            Write-host -Fore:green "DHCP Relay Agent was succesfully added to $dlrName"
        }
        else{
            Write-host -Fore:red "Failed to add DHCP Relay Agent to $dlrName"
        }
    }



    #report status and timing
   $report = @()
    get-job | select -last $jobN | %{
        $props = @{
        JobName = $_.Name
        State = $_.State
        Duration = $_.PSEndTime - $_.PSBeginTime
        } 
    $report += New-Object -TypeName PSObject -Property $Props
    }
    $report | ft -AutoSize

}

