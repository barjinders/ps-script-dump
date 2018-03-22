# Credentials
$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  'VMware1!'
$dlrName = "Distributed-Router-01"
$routingEdges = @('Perimeter-Gateway-01')
$primaryAddress = "10.2.2.2"
$prefixLength = "24"


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
    $brg= Get-NsxLogicalRouter $cvm |Get-NsxLogicalRouterBridging | Get-NSxLogicalRouterBridge
    Get-NsxLogicalRouter $table.cvmName |Get-NsxLogicalRouterBridging | Get-NSxLogicalRouterBridge -Name $brg.name| Remove-NsxLogicalRouterBridge -Confirm:$false
  
    
    #Add LS to the DLR
    $dlr = Get-NsxLogicalRouter -Name $dlrName -Connection $DefaultNSXConnection
    $LS = Get-NsxLogicalSwitch -Name $lsname -Connection $DefaultNSXConnection
     New-NsxLogicalRouterInterface -LogicalRouter $dlr -Name "test" -Type internal -ConnectedTo $LS -PrimaryAddress $primaryAddress  -SubnetPrefixLength $prefixLength 

     #Add Static Routes

  }               
   