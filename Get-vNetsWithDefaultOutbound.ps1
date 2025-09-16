# Azure vNet Default Outbound Internet Access Detection Script
# NoPlaceLike.Cloud
# Bernhard Flür - Cloud Solutions Architect
# VERSION: 2.1


param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [switch]$TenantWide,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\DefaultOutboundVNets.csv",
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeSubscriptions = @(),
    
    [Parameter(Mandatory=$false)]
    [string[]]$IncludeSubscriptions = @(),
    
    [Parameter(Mandatory=$false)]
    [switch]$Help
)

function Show-Help {
    $helpText = $helpText = @"

╔══════════════════════════════════════════════════════════════════════════════════╗
║                Azure vNet Default Outbound Internet Access Detection             ║
╚══════════════════════════════════════════════════════════════════════════════════╝

DESCRIPTION:
    This PowerShell script identifies Azure virtual networks that are using Default 
    Outbound internet access. This is crucial for identifying vNets that will be 
    affected by Azure's deprecation of Default Outbound internet access.

DETECTION CRITERIA:
    The script identifies subnets meeting these criteria:
    
    📌 Criteria 1: Legacy Default Outbound
       • No User Defined Route (UDR) assigned to subnet
       • vNet has no NAT Gateway configured
       • vNet has no Load Balancer configured  
       • Subnet contains Network Interfaces from Virtual Machines
    
    📌 Criteria 2: UDR with Internet Route
       • UDR assigned with at least one route with destination "0.0.0.0/0"
       • Subnet contains Network Interfaces from Virtual Machines

SYNTAX:
    .\DefaultOutboundDetection.ps1 [parameters]

PARAMETERS:
    -SubscriptionId <string>
        Target a specific Azure subscription by ID
        Example: -SubscriptionId "12345678-1234-1234-1234-123456789012"
    
    -TenantWide
        Scan all accessible subscriptions in the current tenant
        Example: -TenantWide
    
    -OutputPath <string>
        Specify custom path for CSV output file
        Default: ".\DefaultOutboundVNets.csv"
        Example: -OutputPath "C:\Reports\MyReport.csv"
    
    -ExcludeSubscriptions <string[]>
        Exclude specific subscriptions from tenant-wide scan (by ID or Name)
        Example: -ExcludeSubscriptions @("DevSub", "12345678-1234-1234-1234-123456789012")
    
    -IncludeSubscriptions <string[]>
        Include only specific subscriptions in tenant-wide scan (by ID or Name)
        Example: -IncludeSubscriptions @("ProdSub", "StagingSub")
    
    -Help
        Display this help information
        Example: -Help

USAGE EXAMPLES:

    📋 Basic single subscription scan (current context):
    .\DefaultOutboundDetection.ps1

    📋 Target specific subscription:
    .\DefaultOutboundDetection.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"

    📋 Scan entire tenant:
    .\DefaultOutboundDetection.ps1 -TenantWide

    📋 Tenant scan excluding development subscriptions:
    .\DefaultOutboundDetection.ps1 -TenantWide -ExcludeSubscriptions @("DevSub1", "DevSub2")

    📋 Scan only production subscriptions:
    .\DefaultOutboundDetection.ps1 -TenantWide -IncludeSubscriptions @("ProdSub", "StagingSub")

    📋 Custom output location:
    .\DefaultOutboundDetection.ps1 -TenantWide -OutputPath "C:\Reports\TenantDefaultOutbound.csv"

PREREQUISITES:
    ✅ Azure PowerShell module (Az.Network) installed
       Install-Module -Name Az -Force
    
    ✅ Authenticated to Azure
       Connect-AzAccount
    
    ✅ Appropriate permissions:
       • Reader permissions on subscriptions
       • Network Contributor or equivalent for detailed analysis

OUTPUT FILES:
    📄 Primary Report: [OutputPath] (default: DefaultOutboundVNets.csv)
       Contains all subnets using Default Outbound internet access
    
    📄 Error Log: [OutputPath]_Errors.csv (if tenant-wide scan encounters errors)
       Contains details of any subscription processing failures

OUTPUT COLUMNS:
    • SubscriptionId/SubscriptionName    • VNetName/VNetLocation
    • ResourceGroupName                  • SubnetName/SubnetAddressPrefix  
    • HasUDR/RouteTableName              • HasInternetRoute
    • SubnetHasNATGateway                • SubnetHasLoadBalancer
    • HasVMNICs                          • DefaultOutboundReason
    • VNetId/SubnetId                   

MIGRATION PLANNING:
    Use this script to:
    🎯 Identify vNets affected by Default Outbound deprecation
    🎯 Plan migration to explicit outbound connectivity methods
    🎯 Audit current outbound internet access patterns
    🎯 Generate compliance reports for security reviews

SECURITY CONSIDERATIONS:
    ⚠️  Default Outbound access provides unrestricted internet egress
    ⚠️  Azure is deprecating this feature for enhanced security
    ⚠️  Plan migration to NAT Gateway, Load Balancer, or explicit UDRs

SUPPORT:
    For issues or questions about this script, refer to Azure documentation:
    https://docs.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access

VERSION: 2.1
AUTHOR: Azure Network Security Assessment Tool
LAST UPDATED: $(Get-Date -Format 'yyyy-MM-dd')

"@
    Write-Host $helpText -ForegroundColor Cyan
}

if ($Help) { Show-Help; return }

# Validate parameter combinations
if ($TenantWide -and $SubscriptionId) {
    Write-Error "Cannot specify both -TenantWide and -SubscriptionId."
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}
if (($ExcludeSubscriptions.Count -gt 0 -or $IncludeSubscriptions.Count -gt 0) -and -not $TenantWide) {
    Write-Error "Subscription filters can only be used with -TenantWide."
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}
if ($ExcludeSubscriptions.Count -gt 0 -and $IncludeSubscriptions.Count -gt 0) {
    Write-Error "Cannot use both -ExcludeSubscriptions and -IncludeSubscriptions."
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}

# Ensure Az.Network
if (-not (Get-Module -ListAvailable -Name Az.Network)) {
    Write-Error "Az module not installed. Install-Module -Name Az -Force"
    exit 1
}

# Ensure login
try {
    if (-not (Get-AzContext)) { Write-Host "Please sign in to Azure..." -ForegroundColor Yellow; Connect-AzAccount }
} catch { Write-Host "Please sign in to Azure..." -ForegroundColor Yellow; Connect-AzAccount }

# Resolve subscriptions to scan
$subscriptionsToScan = @()

if ($TenantWide) {
    Write-Host "🌐 TENANT-WIDE SCAN MODE" -ForegroundColor Magenta
    if ($IncludeSubscriptions.Count -gt 0) { Write-Host "   📋 Including only: $($IncludeSubscriptions -join ', ')" -ForegroundColor Cyan }
    if ($ExcludeSubscriptions.Count -gt 0) { Write-Host "   🚫 Excluding: $($ExcludeSubscriptions -join ', ')" -ForegroundColor Cyan }

    try {
        Write-Host "🔍 Retrieving all accessible subscriptions..." -ForegroundColor Cyan
        $allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

        if ($IncludeSubscriptions.Count -gt 0) {
            $allSubscriptions = $allSubscriptions | Where-Object { $_.Id -in $IncludeSubscriptions -or $_.Name -in $IncludeSubscriptions }
        }
        if ($ExcludeSubscriptions.Count -gt 0) {
            $allSubscriptions = $allSubscriptions | Where-Object { $_.Id -notin $ExcludeSubscriptions -and $_.Name -notin $ExcludeSubscriptions }
        }

        $subscriptionsToScan = $allSubscriptions
        Write-Host "✅ Found $($subscriptionsToScan.Count) accessible subscriptions to scan" -ForegroundColor Green
        if ($subscriptionsToScan.Count -eq 0) { throw "No subscriptions found to scan. Check your filters or permissions." }
    } catch {
        Write-Error "❌ Failed to retrieve subscriptions: $($_.Exception.Message)"
        exit 1
    }
}
elseif ($SubscriptionId) {
    Write-Host "🎯 SINGLE SUBSCRIPTION MODE: $SubscriptionId" -ForegroundColor Magenta
    try {
        $targetSub = Get-AzSubscription -SubscriptionId $SubscriptionId
        $subscriptionsToScan = @($targetSub)
        Write-Host "✅ Target subscription found: $($targetSub.Name)" -ForegroundColor Green
    } catch {
        Write-Error "❌ Could not find subscription: $SubscriptionId"
        exit 1
    }
}
else {
    Write-Host "🎯 CURRENT SUBSCRIPTION MODE" -ForegroundColor Magenta
    $currentSubscription = (Get-AzContext).Subscription
    if (-not $currentSubscription) {
        Write-Error "❌ No subscription context found. Specify -SubscriptionId or use -TenantWide."
        exit 1
    }
    $subscriptionsToScan = @($currentSubscription)
    Write-Host "✅ Using current subscription: $($currentSubscription.Name)" -ForegroundColor Green
}

# --- Analysis ---

$results = @()
$subscriptionErrors = @()
$totalVNets = 0

foreach ($subscription in $subscriptionsToScan) {
    Write-Host "`n=== Processing Subscription: $($subscription.Name) ($($subscription.Id)) ===" -ForegroundColor Magenta
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
        Write-Host "Context set." -ForegroundColor Green

        Write-Host "Retrieving virtual networks..." -ForegroundColor Cyan
        $vNets = Get-AzVirtualNetwork -ErrorAction Stop
        $totalVNets += $vNets.Count
        Write-Host "Found $($vNets.Count) vNet(s)" -ForegroundColor Cyan
        if ($vNets.Count -eq 0) { continue }

        foreach ($vNet in $vNets) {
            Write-Host "  Analyzing vNet: $($vNet.Name) in RG: $($vNet.ResourceGroupName)" -ForegroundColor Yellow

            # Gather LBs in same RG/location once
            $loadBalancers = Get-AzLoadBalancer -ResourceGroupName $vNet.ResourceGroupName -ErrorAction SilentlyContinue |
                             Where-Object { $_.Location -eq $vNet.Location }

            foreach ($subnet in $vNet.Subnets) {
                Write-Host "    Checking subnet: $($subnet.Name)" -ForegroundColor Gray

                # Determine if subnet has NICs from VMs
                $hasVMNics = $false
                $subnetIdNormalized = $subnet.Id.ToLower()

                if ($subnet.IpConfigurations) {
                    foreach ($ipConfigRef in $subnet.IpConfigurations) {
                        if ($ipConfigRef.Id -match "/networkInterfaces/") {
                            try {
                                $nicId = ($ipConfigRef.Id -split "/ipConfigurations/")[0]
                                $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                                if ($nic -and $nic.VirtualMachine) {
                                    $hasVMNics = $true
                                    break
                                }
                            } catch { }
                        }
                    }
                }
                if (-not $hasVMNics) { continue }

                # NAT GW on this subnet?
                $subnetHasNatGateway = $false
                if ($subnet.NatGateway) { $subnetHasNatGateway = $true }

                # LB association relevant to this subnet? (backend ipConfigs in same subnet)
                $subnetHasLoadBalancer = $false
                foreach ($lb in $loadBalancers) {
                    foreach ($pool in $lb.BackendAddressPools) {
                        foreach ($ipConfig in ($pool.BackendIpConfigurations | Where-Object { $_ })) {
                            # Some SDKs expose Subnet on ipConfig, others only the id string
                            $ipCfgSubnetId = try { $ipConfig.Subnet.Id } catch { $null }
                            if (-not $ipCfgSubnetId) {
                                # fall back: infer from ipConfig.Id (points to NIC/ipConfigurations)
                                try {
                                    $cfgNicId = ($ipConfig.Id -split "/ipConfigurations/")[0]
                                    $cfgNic = Get-AzNetworkInterface -ResourceId $cfgNicId -ErrorAction SilentlyContinue
                                    $ipCfgSubnetId = $cfgNic.IpConfigurations[0].Subnet.Id
                                } catch { }
                            }
                            if ($ipCfgSubnetId -and ($ipCfgSubnetId.ToLower() -eq $subnetIdNormalized)) {
                                $subnetHasLoadBalancer = $true
                                break
                            }
                        }
                        if ($subnetHasLoadBalancer) { break }
                    }
                    if ($subnetHasLoadBalancer) { break }
                }

                # UDR on subnet?
                $udrAssigned     = $false
                $hasInternetRoute = $false
                $routeTableName   = "None"

                if ($subnet.RouteTable) {
                    $udrAssigned = $true
                    try {
                        $routeTable = Get-AzRouteTable -ResourceId $subnet.RouteTable.Id -ErrorAction Stop
                        $routeTableName = $routeTable.Name
                        foreach ($route in $routeTable.Routes) {
                            if ($route.AddressPrefix -eq "0.0.0.0/0") {
                                $hasInternetRoute = $true
                                break
                            }
                        }
                    } catch {
                        Write-Warning "Could not retrieve route table details for subnet $($subnet.Name)"
                    }
                }

                # Determine criterion
                $meetsDefaultOutboundCriteria = $false
                $reason = $null

                if (-not $udrAssigned -and -not $subnetHasNatGateway -and -not $subnetHasLoadBalancer -and $hasVMNics) {
                    $meetsDefaultOutboundCriteria = $true
                    $reason = "No UDR, no NAT Gateway, no Load Balancer, has VM NICs"
                }
                elseif ($udrAssigned -and $hasInternetRoute -and $hasVMNics) {
                    $meetsDefaultOutboundCriteria = $true
                    $reason = "UDR with 0.0.0.0/0 route, has VM NICs"
                }

                if ($meetsDefaultOutboundCriteria) {
                    Write-Host "      ✓ Subnet meets Default Outbound criteria: $reason" -ForegroundColor Green
                    $results += [PSCustomObject]@{
                        SubscriptionId        = $subscription.Id
                        SubscriptionName      = $subscription.Name
                        ResourceGroupName     = $vNet.ResourceGroupName
                        VNetName              = $vNet.Name
                        VNetLocation          = $vNet.Location
                        SubnetName            = $subnet.Name
                        SubnetAddressPrefix   = ($subnet.AddressPrefix -join ", ")
                        HasUDR                = $udrAssigned
                        RouteTableName        = $routeTableName
                        HasInternetRoute      = $hasInternetRoute
                        SubnetHasNATGateway   = $subnetHasNatGateway
                        SubnetHasLoadBalancer = $subnetHasLoadBalancer
                        HasVMNICs             = $hasVMNics
                        DefaultOutboundReason = $reason
                        VNetId                = $vNet.Id
                        SubnetId              = $subnet.Id
                    }
                }
            }
        }

        Write-Host "✅ Completed analysis of subscription: $($subscription.Name)" -ForegroundColor Green
    }
    catch {
        $subscriptionErrors += [PSCustomObject]@{
            SubscriptionId   = $subscription.Id
            SubscriptionName = $subscription.Name
            ErrorMessage     = $_.Exception.Message
            ErrorDetails     = $_.Exception.ToString()
        }
        Write-Error "❌ Error processing subscription $($subscription.Name): $($_.Exception.Message)"
        continue
    }
}

# --- Reporting ---

Write-Host "`n=== ANALYSIS COMPLETE ===" -ForegroundColor Green
if ($TenantWide) {
    Write-Host "Scanned $($subscriptionsToScan.Count) subscriptions with $totalVNets total vNets" -ForegroundColor Cyan
    if ($subscriptionErrors.Count -gt 0) {
        Write-Host "Encountered errors in $($subscriptionErrors.Count) subscription(s)" -ForegroundColor Red
    }
}

Write-Host "Found $($results.Count) subnets in $(
    $results | Select-Object VNetName, SubscriptionId -Unique | Measure-Object | Select-Object -ExpandProperty Count
) vNet(s) using Default Outbound internet access" -ForegroundColor Green

if ($results.Count -gt 0) {
    Write-Host "`nSummary by Subscription:" -ForegroundColor Cyan
    $results | Group-Object SubscriptionName | ForEach-Object {
        $subResults = $_.Group | Group-Object VNetName
        Write-Host "  📋 $($_.Name): $($subResults.Count) vNet$(if($subResults.Count -ne 1){'s'}), $($_.Count) subnet$(if($_.Count -ne 1){'s'})"
        $subResults | ForEach-Object {
            Write-Host "    • $($_.Name) ($($_.Count) subnet$(if($_.Count -ne 1){'s'}))"
        }
    }

    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "`nDetailed results exported to: $OutputPath" -ForegroundColor Green

    if ($subscriptionErrors.Count -gt 0) {
        $errorPath = $OutputPath -replace "\.csv$", "_Errors.csv"
        $subscriptionErrors | Export-Csv -Path $errorPath -NoTypeInformation
        Write-Host "Subscription errors exported to: $errorPath" -ForegroundColor Yellow
    }

    Write-Host "`nFirst 10 results:" -ForegroundColor Cyan
    $results | Select-Object -First 10 |
        Format-Table SubscriptionName, VNetName, SubnetName, DefaultOutboundReason, VNetLocation -AutoSize
} else {
    Write-Host "`nNo vNets found using Default Outbound internet access." -ForegroundColor Yellow
    if ($subscriptionErrors.Count -gt 0) {
        Write-Host "Some subscriptions failed; check the error CSV if generated." -ForegroundColor Yellow
    }
}

Write-Host "`n🎉 Script completed successfully!" -ForegroundColor Green
Write-Host "📊 Use the generated CSV report for migration planning and compliance review" -ForegroundColor Cyan
