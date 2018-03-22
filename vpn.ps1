# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}

$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  'VMware1!'

Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue | Out-Null
$pg = Get-VDSwitch RegionA01-vDS-MGMT |Get-VDPortgroup
$portgroups = $pg | Where-Object {($_.vlanconfiguration -NE $null) -and ($_.IsUplink -ne $true) -and ($_.vlanconfiguration.vlantype -ne "Trunk")}
for ($i = 0 ; $i -lt  $portgroups.count; $i++) {

#$upl = Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Index 0
#$ls= Get-NsxLogicalSwitch
$tunid = (Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |get-NsxEdgeSubInterface).tunnelID | % {[convert]::toInt32($_,10)}
#$tunid= $subint.tunnelID
#$tunIDint=@()
#$tunid = $tunid -as [int]


 if (!$tunid){
 Write-Host "TunnelID is zero" $tunid
 $tunid = 1
 Write-host "Updating the tunnelid to" $tunid
 }
 $NextID = (($tunID| sort | select -Last 1) +1)
 
 
 #$internalLs =  $ls | Where-Object name -NE $upl.name
  #For VXLAN Onboarding
 #for ($i = 0 ; $i -lt  $internalLs.count; $i++) {
 
 #Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |New-NsxEdgeSubInterface -Name $internalLs[$i].name -Network $internalLs[$i] -TunnelId ($countTunId + $i)
 # }


 #For VLAN Onboarding

 #$pg = Get-VDSwitch RegionA01-vDS-MGMT |Get-VDPortgroup
 #$portgroups = $pg | Where-Object {($_.vlanconfiguration -NE $null) -and ($_.IsUplink -ne $true) -and ($_.vlanconfiguration.vlantype -ne "Trunk")}
 #for ($i = 0 ; $i -lt  $portgroups.count; $i++) {
  Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |New-NsxEdgeSubInterface -Name ($portgroups[$i].Name) -TunnelId $NextID -Network $portgroups[$i]

  }