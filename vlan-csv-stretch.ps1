# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}

$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  'VMware1!'
#$dlr = l2vpn
#$trunk = L2VPN-Trunk
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
    'vdspg','tunnelid','vpnedge','trunkpg'| 
        foreach{
            if($entry.$_ -contains ""){
                    $InvalidEntry += $entry.lsName  
            }
        }
}

# Reporting the Churnsheet validation results
if ($invalidEntry){
    $invalidEntry = $invalidEntry | select -Unique
    Write-Host -fore:Red "The following feilds have missing information in the churnsheet. Exiting..."
    Write-Host -fore:Yellow "$($invalidEntry | ft)"
    Exit
    }
else{
    Write-Host -fore:Green "All mandatory values in the churnsheet are present`n"
    }

#Loop to add the stretched VLANS
foreach($row in $csv) {


    do {
        $start = Read-Host -Prompt "Type 'continue' to start VLAN stretch for Portgroup $($row.vdspg)"
    } while($start -ne 'continue')


 #Add the new Strech subinterface
 Get-NsxEdge $row.vpnedge |Get-NsxEdgeInterface -Name $row.trunkpg |New-NsxEdgeSubInterface -Name (Get-VDSwitch RegionA01-vDS-MGMT |Get-VDPortgroup $row.vdspg).name -TunnelId $row.tunnelid -Network (Get-VDSwitch RegionA01-vDS-MGMT |Get-VDPortgroup $row.vdspg)
 Write-Host "Portgroup" $row.vdspg "added with the TunnelID" $row.tunnelid
  }