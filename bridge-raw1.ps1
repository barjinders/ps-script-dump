# Credentials
$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  ''
$dlrName = "Distributed-Router-01"
$routingEdges = @('Perimeter-Gateway-01')
#$primaryAddress = "10.2.2.2"
#$prefixLength = "24"
$importPath = 'C:\Users\Administrator\Documents\test\LS.csv'



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


# validate all logical switches are present
$LSInvalidEntry = @()
$LS = get-NsxLogicalSwitch -Connection $DefaultNSXConnection
foreach($entry in $csv){
    if($LS.name -notcontains $entry.lsname){
        $LSInvalidEntry += $entry.lsname
    }
}


# Reporting the Churnsheet validation results
if ($LSInvalidEntry){
    $LSInvalidEntry = $LSInvalidEntry | select -Unique
    Write-Host -fore:Red "The following logical switches are not present in NSX manager" $NsxServerIP
    Write-Host -fore:Yellow "$($LSInvalidEntry | ft)"
    Exit
    }
else{
    Write-Host -fore:Green "All logical switches are present in NSX manager $NsxServerIP.`n"
    }


    # Validate DHCP Server is configured
if(!$dlr.features.dhcp.relay.relayServer.ipAddress){
    Write-host -fore:Red "There is no DHCP Relay Server configured on logical router $dlr"
}
else{
    Write-host -fore:Green "The logical router $($dlr.name) has DHCP Relay Server configured"
}

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



#collect Logical Switch Details
 foreach($row in $csv){    
    $LsNamecsv = $row.LsName
    $primaryAddress = $row.primaryAddress
    $prefixLength = $row.prefixLength

   

#Create a table of CVM and Logical Switches. 
$table = @()
Get-NsxLogicalRouter | %{
    if($_.features.bridges.enabled -eq "true"){
        $a = New-Object -TypeName PSobject
        $a | Add-Member -Type NoteProperty -Name cvmName -Value $_.name    
        $a | Add-Member -Type NoteProperty -Name LS -Value $(($_ | Get-NsxLogicalRouterBridging).bridge.virtualwirename)
        $table += $a
    }
}


$table | %{
          $cvm = $_.cvmName
          $lsName= $_.LS
        write-host "Bridge DLR CVM Name is: " $cvm
        write-host "Bridge DLR LS Name is: "$lsName
   
    #Remove LS from the Bridge
    foreach($item in $table) {
    $brg = @()
    $brg= Get-NsxLogicalRouter $cvm |Get-NsxLogicalRouterBridging | Get-NSxLogicalRouterBridge
    
    Get-NsxLogicalRouter $table.cvmName |Get-NsxLogicalRouterBridging | Get-NSxLogicalRouterBridge -Name $brg.name| Remove-NsxLogicalRouterBridge -Confirm:$false
  
    
    #Add LS to the DLR
    $dlr = Get-NsxLogicalRouter -Name $dlrName -Connection $DefaultNSXConnection
    $LS = Get-NsxLogicalSwitch -Name $lsname -Connection $DefaultNSXConnection
    if($lsnamecsv -eq $lsname) {
    New-NsxLogicalRouterInterface -LogicalRouter $dlr -Name "test" -Type internal -ConnectedTo $LS -PrimaryAddress $primaryAddress  -SubnetPrefixLength $prefixLength 
    }

     #Add Static Routes
    $subnet = Get-NetworkAddress $PrimaryAddress  $(convertto-mask $PrefixLength) 
    $network = $subnet+"/"+$PrefixLength
    $dlrUplinkIP = ($dlr.interfaces.interface | ?{$_.type -eq "Uplink"}).addressgroups.addressgroup.primaryAddress
    Get-NsxEdge -name $routingEdgeName -Connection $DefaultNSXConnection | Get-NsxEdgeRouting  | New-NsxEdgeStaticRoute -Network $network -NextHop $dlrUplinkIP -confirm:$false -Connection $DefaultNSXConnection

    }               
  }
  }