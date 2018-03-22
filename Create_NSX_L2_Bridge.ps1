# reset all variable
foreach ($i in (ls variable:/*)) {rv -ea 0 $i.Name}

# Credentials
$VcName = 'vcsa-01a.corp.local/vsphere-client/'
$NsxServerIP = '192.168.110.42'
$VcUsername = 'administrator@vsphere.local'
$VcPassword =  ''


# CSV file location
$ImportPath = 'U:\Barjinder\S3\Bridging\bridge.csv'

# Connect to vCenter/NSX
Connect-NsxServer -vCenterServer $VcName -Username $VcUsername -password $VcPassword -ErrorAction SilentlyContinue | out-null

# validate NSX connection
if(($DefaultNSXConnection.VIConnection.name -eq $vcName) -and ($DefaultNSXConnection.Server -eq $nsxServerIP)){
    Write-host "Connection to NSX server $nsxServerIP was established successfully"
}
else{
    Write-host -Fore:red "Connection to NSX server $nsxServerIP failed. Exiting..."
    Exit
}

 
# validate CSV file location
if(!$ImportPath) {
    Logger "Red" 'Please provide valid CSV file path using $ImportPath variable, exiting..'
    DisconnectVC
    exit
}
if(!(Test-Path -Path $ImportPath -PathType:Leaf)) {
    Logger "Red" 'Please provide valid CSV file path using $ImportPath variable, exiting..'
    DisconnectVC
    exit
}


#import CSV
$csv = import-csv -Path $importPath

# validate CSV file content
$invalidEntry = @()
foreach ($entry in $csv){
    'lsName','pgName','CVM'|
        foreach{
            if($entry.$_ -contains ""){
                    $InvalidEntry += $entry.lsName 
            }
        }
}


# Reporting the Churnsheet validation results
if ($invalidEntry){
    $invalidEntry = $invalidEntry | select -Unique
    Write-Host -fore:Red "The following logical switches have missing information in the CSV file. Exiting..."
    Write-Host -fore:Yellow "$($invalidEntry | ft)"
    Exit
    }
else{
    Write-Host -fore:Green "All mandatory values in the CSV file are present`n"
    }



# Validate CSV file content - CVMs, Logical Switches, Portgroups

$missingLS = @()
$missingPG = @()
$missingCVM = @()

$LogicalSwitches =  Get-NsxLogicalSwitch 
$Portgroups = Get-VDSwitch $dvsName | Get-VDPortgroup 
$controlVMs = Get-NsxLogicalRouter 

foreach($entry in $csv){
    if($LogicalSwitches.name -notcontains $entry.lsName){
        $missingLS += $entry.lsname
    }
    if(($Portgroups.name -notcontains $entry.pgName) -or  (!($Portgroups | ?{$_.name -eq $entry.pgName}).vlanConfiguration)){
        $missingPG += $entry.pgName
    }
    if($controlVMs.name -notcontains $entry.CVM){
        $missingCVM += $entry.CVM
    }
}


if ($missingLS){
    $missingLS = $missingLS | select -Unique
    Write-Host -fore:Red "The following logical switches are not present in NSX manager $NsxServerIP . Exiting..."
    Write-Host -fore:Yellow $missingLS 
    Exit
    }
else{
    Write-Host -fore:Green "Validation of logical switches was completed successfully`n"
    }

if($missingPG){
    $missingPG = $missingPG | select -Unique
    Write-Host -fore:Red "The following portgroups are not present in DVS $dvsName or portgroups have no VLAN assigned . Exiting..."
    Write-Host -fore:Yellow $missingPG 
    Exit
    }
else{
    Write-Host -fore:Green "Validation of portgroups was completed successfully`n"
    }

if($missingCVM){
    $missingCVM = $missingCVM | select -Unique
    Write-Host -fore:Red "The following control VMs are not present in NSX manager $NsxServerIP . Exiting..."
    Write-Host -fore:Yellow $missingCVM
    Exit
    }
else{
    Write-Host -fore:Green "Validation of control VMs was completed successfully`n"
    }



foreach($entry in $csv){

    do {
        $start = Read-Host -Prompt "Type 'next' to enable L2 Bridge between portgroup $($entry.pgName) and logical switch $($entry.lsName)"
    } while($start -ne 'next')
    
    $bridging = Get-NsxLogicalRouter $entry.cvm | Get-NsxLogicalRouterBridging
   if(($bridging.bridge.virtualwireName -contains $entry.lsName) -or ($bridging.bridge.dvportGroupName -eq $entry.pgName)){
        write-host -fore:Yellow "Control VM has already bridge instance for LS or PG"
        continue
    }
    Get-NsxLogicalRouter $entry.cvm | Get-NsxLogicalRouterBridging | New-NsxLogicalRouterBridge -Name $($entry.pgname+"-to-"+$entry.lsName) -PortGroup $($Portgroups | ?{$_.name -eq $entry.pgName}) -LogicalSwitch $($LogicalSwitches | ?{$_.name -eq $entry.lsName})
}

