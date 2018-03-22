#Set-PowerCLIConfiguration -InvalidCertificateAction ignore -confirm:$false

$vc = ""


Connect-NsxServer -vc $vc -Username "" -Password ""

$dlr = Get-NsxLogicalRouter
#$tempStaticRoutes = @()
$report = @()


foreach($dl in $dlr) {
   
    
    $tempStaticRoutes =  $dl.features.routing.staticRouting.staticRoutes.route

    if ($tempStaticRoutes -eq $null) 
    {
        Write-Host ("================================================")
        Write-Host ("DLR: "+ $dlr.name +" doesn't have static routes ")
        Write-Host ("================================================")
    } else 
    {
        foreach($staticRoute in $tempStaticRoutes) {
            $a = New-Object PSobject
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Name" -Value $($dl.name)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Description" -Value $($staticRoute.description)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Network" -Value $($staticRoute.network)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "NextHop" -Value $($staticRoute.nexthop)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "Admin Distance" -Value $($staticRoute.adminDistance)
                Add-Member -InputObject $a -MemberType NoteProperty -Name "MTU" -Value $($staticRoute.mtu)

            $report += $a
       
        }
     }
    
}


$report | ft -AutoSize
