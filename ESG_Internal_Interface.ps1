Connect-NsxServer -vCenterServer ocmvc01.oc.prod.au.internal.cba -Username 'singhb6-adm' -Password "Harvir@Waheguru1!"
$report = @()
$edges= Get-NsxEdge
#$edgeuplinlks = $edges|Get-NsxEdgeInterface | ?{$_.type -like "uplink"}

foreach($edge in $edges) {
    $edgeuplinlks = $edge|Get-NsxEdgeInterface | ?{$_.type -like "internal" -and $_.isconnected -like "true"}
        foreach($edgeuplink in $edgeuplinlks) {
         $a = New-Object PSobject
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Name" -Value $($edge.name)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Internal Int" -Value $($edgeuplink.addressgroups.addressgroup.primaryAddress)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "SubnetMask" -Value $($edgeuplink.addressgroups.addressgroup.subnetMask)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Interface Name" -Value $($edgeuplink.name)
                 $report += $a
        }
}
Write-Host "`n `n `n `n"

Write-Host ("ESG Internal Interface Configuration for " + $global:DefaultVIServer)
$report | ft -AutoSize