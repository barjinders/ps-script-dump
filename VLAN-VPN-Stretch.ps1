# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}

$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  'VMware1!'
$dlr = l2vpn
$trunk = L2VPN-Trunk
$importpath = "C:\Users\Administrator\Documents\test\pg.csv"


#Connect NSX Manager and VC
Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue | Out-Null


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
    'vdspg','tunnelid','PrimaryAddress', 'PrefixLength' | 
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




#Gather portgroups before stretching. 
$pg = Get-VDSwitch RegionA01-vDS-MGMT |Get-VDPortgroup

#Remove Portgroups without VLAN, Uplink and Trunk from the list
$portgroups = $pg | Where-Object {($_.vlanconfiguration -NE $null) -and ($_.IsUplink -ne $true) -and ($_.vlanconfiguration.vlantype -ne "Trunk")}

#Loop to add the stretched VLANS
for ($i = 0 ; $i -lt  $portgroups.count; $i++) {

#Gather the tunnel IDs
$tunid = (Get-NsxEdge $dlr |Get-NsxEdgeInterface -Name $trunk |get-NsxEdgeSubInterface).tunnelID | % {[convert]::toInt32($_,10)}

#Update the tunnel id for each iteration. 
 $NextID = (($tunID| sort | select -Last 1) +1)

 #Add the new Strech subinterface
 Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |New-NsxEdgeSubInterface -Name ($portgroups[$i].Name) -TunnelId $NextID -Network $portgroups[$i]
 Write-Host "Portgroup" $portgroups[$i].Name "added with the TunnelID" $NextID
  }