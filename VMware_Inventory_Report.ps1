$report = @()
$reportVM = @()
Get-VMHost | %{
    $a = New-Object PSobject
    Add-Member -InputObject $a -MemberType NoteProperty -Name "NameVM" -Value $($_.Name)
    Add-Member -InputObject $a -MemberType NoteProperty -Name "Build" -Value $($_.Build)
    Add-Member -InputObject $a -MemberType NoteProperty -Name "Memory" -Value $($_.MemoryTotalGB)
    $report+= $a
    
}

Get-VM | %{
    $b= New-Object PSobject
    Add-Member -InputObject $b -MemberType NoteProperty -Name "VM Name" -Value $($_.Name)
    Add-Member -InputObject $b -MemberType NoteProperty -Name "VM IP" -Value $($_.Guest.IPAddress)
    Add-Member -InputObject $b -MemberType NoteProperty -Name "VM UsedSpace" -Value $(($_.UsedSpaceGB)/1024)
    $reportvm+= $b
}
$report | Format-Table -Property Name, Build,Memory

$reportVM |Format-Table "VM Name", "VM IP", "VM UsedSpace"

