# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}


# destination Variables
$destVcName = ''
$destNsxServerIP = ''
$destVcUsername = ''
$destVcPassword =  ''
$destEdgeName =  ''

# source Variables
$importPath = 'U:\Barjinder\DDM\Sandbox\LS-Cutover.csv'
$vcName = ''
$nsxServerIP = ''
$vcUsername = ''
$vcPassword =  'PASSWORD'
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

function Remove-DHCPrelayFromDLR{
    param(
    [Parameter(Mandatory = $True)]
    [string]$giAddress,
    [Parameter(Mandatory = $True)]
    [string]$dlrName 
    )


    $dlr = Get-NsxLogicalRouter $dlrName
    $relayToRemove = $dlr.features.dhcp.relay.relayAgents.selectSingleNode("child::relayAgent[giAddress='$giaddress']")
    $dlr.features.dhcp.relay.relayAgents.RemoveChild($relayToRemove)
    $dlr | set-nsxlogicalrouter -Confirm:$false


}

#endregion




# Connect to NSX server
Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue
$destNsxConnection = Connect-NsxServer -vCenterServer $destVcName -Username $destVcUsername -password $destVcPassword -ErrorAction SilentlyContinue  -DefaultConnection:$false

# validate Source NSX connection
if(($DefaultNSXConnection.VIConnection.name -eq $vcName) -and ($DefaultNSXConnection.Server -eq $nsxServerIP)){
    Write-host "Connection to NSX server $nsxServerIP was established successfully"
}
else{
    Write-host -Fore:red "Connection to NSX server $nsxServerIP failed. Exiting..."
    Exit
}


# validate Destination NSX connection
if(($destNsxConnection.VIConnection.name -eq $destVcName) -and ($destNsxConnection.Server -eq $destNsxServerIP)){
    Write-host "Connection to NSX server $destNsxServerIP was established successfully"
}
else{
    Write-host -Fore:red "Connection to NSX server $destNsxServerIP failed. Exiting..."
    Exit
}


#import CSV
$csv = import-csv -Path $importPath
# collecting objects

$tz = Get-NsxTransportZone $tzName
$logicalSwitches = $tz | Get-NsxLogicalSwitch
$dlr = Get-NsxLogicalRouter -Name $dlrName
$dlrUplinkIP = ($dlr.interfaces.interface | ?{$_.type -eq "Uplink"}).addressgroups.addressgroup.primaryAddress


#region Script Blocks
$ConnectLStoDLR = {
   Param (
    $LsName,
    $DlrName,
    $primaryAddress,
    $prefixLength,
    $NSXConnection
   )   
    $Dlr = Get-NsxLogicalRouter -Name $DlrName -Connection $NSXConnection
    $LS = Get-NsxLogicalSwitch -Name $LsName -Connection $NSXConnection
  
    New-NsxLogicalRouterInterface -LogicalRouter $Dlr -Name $LsName -Type internal -ConnectedTo $LS -PrimaryAddress $primaryAddress  -SubnetPrefixLength $prefixLength -Connection $NSXConnection
}

$RemoveDlrInterface = {
   Param (
    $lsName,
    $dlrName,
    $DefaultNSXConnection
   )   
    $dlr = Get-NsxLogicalRouter -Name $dlrName -Connection $DefaultNSXConnection
    $LS = Get-NsxLogicalSwitch -Name $lsname -Connection $DefaultNSXConnection
    Get-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $lsname | Remove-NsxLogicalRouterInterface -Confirm:$false
   
}

$EnableL2VPN = {
   Param (
    $lsID,
    $DefaultNSXConnection
   )   

    $edge = Get-NsxEdge -Connection $DefaultNSXConnection |  ?{$_.vnics.vnic.subinterfaces.subinterface.logicalswitchid -eq $lsID}
    
    (($edge.vnics.vnic | ?{$_.Type -eq "Trunk"}).subinterfaces.subinterface | ?{$_.logicalSwitchID -eq $lsID}).isConnected = 'True'
    $edge | Set-NsxEdge -Confirm:$false -Connection $DefaultNSXConnection
}

$RemoveStaticRoutefromEdge = {
   Param (
    $routingEdgeName,
    $network,
    $dlrUplinkIP,
    $DefaultNSXConnection
   )   

    Get-NsxEdge -name $routingEdgeName -Connection $DefaultNSXConnection | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP  | Remove-NsxEdgeStaticRoute -Confirm:$false -Connection $DefaultNSXConnection
    
}

$AddEdgeInterface = {
   Param (
    $LsName,
    $edgeName,
    $NSXConnection
   )   
    $edge = Get-NsxEdge -Name $edgeName -Connection $NSXConnection

    #validate that there is only one interface matching logical switch to be disconnected
    $intToConnect = $edge.vnics.vnic | ?{$_.portgroupname -match $lsname}
    if(($intToConnect | measure).count -eq 1){
        ($edge.vnics.vnic | ?{$_.portgroupname -match $lsname}).isConnected = 'true'
        $edge | Set-NsxEdge -Confirm:$false -Connection $NSXConnection
    }
    else{
        write-host -fore:red "There is more than one interface on $($nsxedge) matching logical switch $lsname"
    }
}


#endregion

foreach($row in $csv){
    do {
        $start = Read-Host -Prompt "Type 'continue' to start network rollback for logical switch $($row.destlsName)"
    } while($start -ne 'continue')

    #refresh DLR config
    $dlr = Get-NsxLogicalRouter -Name $dlrName

    # Collect variables
    $lsName = $row.destLsName
    $destlsName = $row.sourceLsName
    $primaryAddress = $row.primaryAddress
    $prefixLength = $row.prefixLength

    # Remove DHCP Relay Agent
    if($dlr.features.dhcp.relay.relayAgents.relayAgent | ?{$_.giAddress -eq $primaryAddress}){
        Remove-DHCPrelayFromDLR -dlrName $dlrName  -giAddress $primaryAddress


        $dlr = Get-NsxLogicalRouter -Name $dlrName
        if($dlr.features.dhcp.relay.relayAgents.relayAgent | ?{$_.giAddress -eq $primaryAddress}){
            
            Write-host -Fore:Red "Failed to remove DHCP Relay Agent to $dlrName"
            Write-host -Fore:Yellow "Remove DHCP Relay Agent for logical switch $lsName on logical router $dlrName"
            do {
                $start = Read-Host -Prompt "Type 'Yes' to confirm that DHCP Relay Agent for logical switch $lsName was removed"
            } while($start -ne 'Yes')

        }
        else{
            Write-host -Fore:Green "DHCP Relay Agent was succesfully removed to $dlrName"
        }
    }
   
    # Disconnect LS to DLR
    Start-Job -name RemoveDlrInterface -ScriptBlock $RemoveDlrInterface -ArgumentList $lsName,$dlrName,$DefaultNSXConnection
    
    # Connect destination LS to destination Edge
    Start-Job -name AddEdgeInterface -ScriptBlock $AddEdgeInterface -ArgumentList $destlsName,$destEdgeName,$destNsxConnection


    #  Enable L2 VPN
    $lsID = ($logicalSwitches | ?{$_.name -eq $row.destlsName}).objectID
    Start-Job -name EnableL2VPN -ScriptBlock $EnableL2VPN -ArgumentList $lsID,$DefaultNSXConnection


    # Remove static routes from Edge
    $subnet = Get-NetworkAddress $row.PrimaryAddress  $(convertto-mask $row.PrefixLength) 
    $network = $subnet+"/"+$row.PrefixLength
    foreach($routingEdgeName in $routingEdges){
        Start-Job -name RemoveStaticRoutefromEdge -ScriptBlock $RemoveStaticRoutefromEdge -ArgumentList $routingEdgeName,$network,$dlrUplinkIP,$DefaultNSXConnection
    }

    $jobN = (get-job | ?{$_.state -eq "Running"}).count


    #check results
    do{
    sleep 1
    }while (get-job | ?{$_.state -eq "Running"})


    # Validate LS to DLR connection
    if(Get-NsxLogicalRouterInterface -LogicalRouter $dlr -Name $lsname){
        Write-host -Fore:red "`nFailed to remove Logical switch $lsname from DLR $($dlr.name) "
    }
    else{
        Write-host -Fore:green "`nLogical switch $lsname was succesfully removed from DLR $($dlr.name)"
    }   

    <#
    # Validate LS to DLR connection
    $destDLR = Get-NsxLogicalRouter -Name $destDlrName -Connection $destNsxConnection
    if(Get-NsxLogicalRouterInterface -LogicalRouter $destDLR -Name $destlsName){
        Write-host -Fore:green "`nLogical switch $destlsName was succesfully re-connected to DLR $destDlrName"
    }
    else{
        Write-host -Fore:red "`nFailed to-reconnect Logical switch $destlsName failed to connect to DLR $destDlrName"  
    }
    #>

    # Validate L2 VPN Disable
    $edge = Get-NsxEdge|  ?{$_.vnics.vnic.subinterfaces.subinterface.logicalswitchid -eq $lsID}
    if((($edge.vnics.vnic | ?{$_.Type -eq "Trunk"}).subinterfaces.subinterface | ?{$_.logicalSwitchID -eq $lsID}).isConnected -eq "true"){
        Write-host -Fore:green "L2 VPN was successfully enabled for $lsname"
    }
    else{
        Write-host -Fore:red "Failed to enable L2 VPN for $lsname"
    }


    # validate static route
    foreach($routingEdgeName in $routingEdges){
        if(Get-NsxEdge -name $routingEdgeName | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP){
            Write-host -Fore:red "Failed to remove static route to $routingEdgeName" 
        }
        else{
            Write-host -Fore:green "Static route was succesfully removed from $routingEdgeName" 
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



