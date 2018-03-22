# Reset all variables
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}

$VcName = 'vcsa-01a.corp.local'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  'VMware1!'

Connect-NsxServer -vCenterServer $vcName -Username $vcUsername -password $vcPassword -ErrorAction SilentlyContinue | Out-Null

$excludels = Get-NsxEdge l2vpn |Get-NsxEdgeInterface | where {($_.type -ne "internal")}
$ls= Get-NsxLogicalSwitch | where ($_.name -notin $excludels.name)



$internalLs =  $ls |where ($_.objectid -ne $excludels)
for ($i = 0 ; $i -lt  $internalLS.count; $i++) {

$tunid1 = (Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |get-NsxEdgeSubInterface).tunnelID
if (!$tunid1) {
$tunid = 1
}Else {
$tunid = (Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |get-NsxEdgeSubInterface).tunnelID | % {[convert]::toInt32($_,10)}
}

$NextID = (($tunID| sort | select -Last 1) +1)
 
  Get-NsxEdge l2vpn |Get-NsxEdgeInterface -Name L2VPN-Trunk |New-NsxEdgeSubInterface -Name ($internalLS[$i].Name) -TunnelId $NextID -Network $internalLS[$i]

  }