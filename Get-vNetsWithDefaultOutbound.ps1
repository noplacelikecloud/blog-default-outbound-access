# Azure vNet Default Outbound Internet Access Detection Script
# NoPlaceLike.Cloud
# Bernhard Flür - Cloud Solutions Architect
# VERSION: 2.2

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
    $helpText = @"

╔══════════════════════════════════════════════════════════════════════════════════╗
║                Azure vNet Default Outbound Internet Access Detection             ║
╚══════════════════════════════════════════════════════════════════════════════════╝

DESCRIPTION:
    This PowerShell script identifies Azure virtual networks that are still using
    Default Outbound Internet access or are otherwise at risk because they lack
    an explicit outbound path.

DETECTION CRITERIA (v2.2):
    A subnet is flagged only if it has VM NICs and NONE of the explicit egress paths exist:
       • NAT Gateway attached to the subnet, OR
       • Standard Load Balancer with an OUTBOUND RULE targeting a backend pool that
         contains NICs from this subnet, OR
       • Any NIC in the subnet has a Public IP, OR
       • UDR default route (0.0.0.0/0) to VirtualAppliance or VirtualNetworkGateway.

    Additionally, a subnet is flagged if:
       • It has a UDR default route (0.0.0.0/0) to Internet AND it does NOT have
         NAT/LB outbound/PIP (i.e., risky direct Internet UDR).

NOTES:
    - We explicitly check NIC-level Public IPs.
    - We differentiate UDR next-hop types (Internet vs Appliance/VNG).
    - We verify Standard LB OUTBOUND rules (mere backend membership is not enough).
    - (Optional) We attempt to surface 'defaultOutboundAccess' if the SDK exposes it.

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
    ✅ Azure PowerShell module (Az) installed
       Install-Module -Name Az -Force
    
    ✅ Authenticated to Azure
       Connect-AzAccount
    
    ✅ Appropriate permissions:
       • Reader (minimum) on subscriptions
       • Network Reader/Contributor recommended for richer details

OUTPUT FILES:
    📄 Primary Report: [OutputPath] (default: DefaultOutboundVNets.csv)
       Contains all subnets flagged by the criteria
    
    📄 Error Log: [OutputPath]_Errors.csv (if tenant-wide scan encounters errors)
       Contains details of any subscription processing failures

OUTPUT COLUMNS:
    • SubscriptionId/SubscriptionName     • VNetName/VNetLocation
    • ResourceGroupName                   • SubnetName/SubnetAddressPrefix  
    • HasUDR/RouteTableName               • HasInternetRoute
    • UdrDefaultNextHops                  • SubnetHasNATGateway
    • HasLbOutboundRules                  • HasNicPublicIp
    • HasVMNICs                           • DefaultOutboundAccess
    • DefaultOutboundReason               • VNetId/SubnetId                   

MIGRATION PLANNING:
    Use this script to:
    🎯 Identify subnets that will lose Internet egress without explicit configuration
    🎯 Plan migration to NAT Gateway, LB outbound, PIP, or hub firewall
    🎯 Audit current outbound Internet access patterns

SECURITY CONSIDERATIONS:
    ⚠️  Default Outbound access provides unmanaged Internet egress
    ⚠️  Azure is retiring this behavior for new VNets/subnets (by API version)
    ⚠️  Plan migration to explicit outbound methods

SUPPORT:
    See Azure docs on default outbound access:
    https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access

VERSION: 2.2
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

# Ensure Az module
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

                $subnetIdNormalized = $subnet.Id.ToLower()
                $hasVMNics = $false
                $hasNicWithPublicIp = $false

                # Determine if subnet has NICs from VMs and whether any of those NICs have a PIP
                if ($subnet.IpConfigurations) {
                    foreach ($ipConfigRef in $subnet.IpConfigurations) {
                        if ($ipConfigRef.Id -match "/networkInterfaces/") {
                            try {
                                $nicId = ($ipConfigRef.Id -split "/ipConfigurations/")[0]
                                $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                                if ($nic) {
                                    # VM-backed NIC?
                                    if ($nic.VirtualMachine) { $hasVMNics = $true }

                                    # Any PIP on NIC?
                                    if ($nic.IpConfigurations) {
                                        foreach ($cfg in $nic.IpConfigurations) {
                                            if ($cfg.PublicIpAddress -and $cfg.PublicIpAddress.Id) {
                                                $hasNicWithPublicIp = $true
                                                break
                                            }
                                        }
                                    }
                                    if ($hasVMNics -and $hasNicWithPublicIp) { break }
                                }
                            } catch { }
                        }
                    }
                }
                if (-not $hasVMNics) { continue } # Only care about subnets with VM NICs

                # NAT GW on this subnet?
                $subnetHasNatGateway = $false
                try { if ($subnet.NatGateway) { $subnetHasNatGateway = $true } } catch {}

                # UDR inspection
                $udrAssigned                = $false
                $hasInternetRoute           = $false   # 0.0.0.0/0 -> Internet
                $hasDefaultToApplianceOrVNG = $false   # 0.0.0.0/0 -> VirtualAppliance/VirtualNetworkGateway
                $routeTableName             = "None"
                $udrDefaultNextHops         = @()

                if ($subnet.RouteTable -and $subnet.RouteTable.Id) {
                    $udrAssigned = $true

                    # Parse resource group and name from the route table resource ID
                    $rtId   = $subnet.RouteTable.Id
                    $rtMatch = [regex]::Match(
                        $rtId,
                        "/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Network/routeTables/(?<name>[^/]+)",
                        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                    )

                    if ($rtMatch.Success) {
                        $rtRg   = $rtMatch.Groups['rg'].Value
                        $rtName = $rtMatch.Groups['name'].Value
                        try {
                            $routeTable     = Get-AzRouteTable -ResourceGroupName $rtRg -Name $rtName -ErrorAction Stop
                            $routeTableName = $routeTable.Name

                            foreach ($route in $routeTable.Routes) {
                                if ($route.AddressPrefix -eq "0.0.0.0/0") {
                                    $udrDefaultNextHops += $route.NextHopType
                                    if ($route.NextHopType -eq "Internet") { $hasInternetRoute = $true }
                                    if ($route.NextHopType -in @("VirtualAppliance","VirtualNetworkGateway")) {
                                        $hasDefaultToApplianceOrVNG = $true
                                    }
                                }
                            }
                        } catch {
                            Write-Warning "Could not retrieve route table '$rtName' in RG '$rtRg' for subnet $($subnet.Name): $($_.Exception.Message)"
                        }
                    } else {
                        Write-Warning "Unable to parse RouteTable Id for subnet $($subnet.Name): $rtId"
                    }
                }


                # Load Balancer outbound rule check (Standard only)
                $subnetHasLbOutbound = $false
                if ($loadBalancers) {
                    foreach ($lb in $loadBalancers) {
                        try {
                            if ($lb.Sku.Name -ne 'Standard') { continue }

                            # Find backend pools that include NICs from this subnet
                            $poolsTouchingSubnet = @()
                            foreach ($pool in $lb.BackendAddressPools) {
                                $poolTouches = $false
                                $backendConfigs = $pool.BackendIpConfigurations | Where-Object { $_ }
                                foreach ($ipConfig in $backendConfigs) {
                                    $cfgNicId = ($ipConfig.Id -split "/ipConfigurations/")[0]
                                    $cfgNic   = Get-AzNetworkInterface -ResourceId $cfgNicId -ErrorAction SilentlyContinue
                                    if ($cfgNic -and $cfgNic.IpConfigurations -and $cfgNic.IpConfigurations[0].Subnet) {
                                        $ipCfgSubnetId = $cfgNic.IpConfigurations[0].Subnet.Id
                                        if ($ipCfgSubnetId -and ($ipCfgSubnetId.ToLower() -eq $subnetIdNormalized)) {
                                            $poolTouches = $true; break
                                        }
                                    }
                                }
                                if ($poolTouches) { $poolsTouchingSubnet += $pool.Id }
                            }

                            if (-not $poolsTouchingSubnet) { continue }

                            # Check LB.OutboundRules reference these pools
                            $outRules = $lb.OutboundRules | Where-Object { $_ }
                            foreach ($orule in $outRules) {
                                $rulePoolId = $orule.BackendAddressPool.Id
                                if ($rulePoolId -in $poolsTouchingSubnet) { $subnetHasLbOutbound = $true; break }
                            }
                            if ($subnetHasLbOutbound) { break }
                        } catch {
                            Write-Warning "LB check failed on $($lb.Name): $($_.Exception.Message)"
                        }
                    }
                }

                # Optional: surface defaultOutboundAccess when available
                $defaultOutboundAccess = $null
                try { $defaultOutboundAccess = $subnet.DefaultOutboundAccess } catch {}

                # Final classification
                $hasExplicitEgress =
                    $subnetHasNatGateway -or
                    $subnetHasLbOutbound -or
                    $hasNicWithPublicIp -or
                    $hasDefaultToApplianceOrVNG

                $atRiskDueToInternetUdr =
                    $udrAssigned -and $hasInternetRoute -and -not ($subnetHasNatGateway -or $subnetHasLbOutbound -or $hasNicWithPublicIp)

                $meetsDefaultOutboundCriteria = $false
                $reason = $null

                if ($hasVMNics) {
                    if (-not $hasExplicitEgress) {
                        $meetsDefaultOutboundCriteria = $true
                        $reason = "No NAT GW/LB outbound/PIP/UDR via Appliance/VNG; has VM NICs"
                    } elseif ($atRiskDueToInternetUdr) {
                        $meetsDefaultOutboundCriteria = $true
                        $reason = "UDR 0.0.0.0/0 -> Internet without NAT/LB outbound/PIP; has VM NICs"
                    }
                }

                if ($meetsDefaultOutboundCriteria) {
                    Write-Host "      ✓ Subnet flagged: $reason" -ForegroundColor Green
                    $results += [PSCustomObject]@{
                        SubscriptionId         = $subscription.Id
                        SubscriptionName       = $subscription.Name
                        ResourceGroupName      = $vNet.ResourceGroupName
                        VNetName               = $vNet.Name
                        VNetLocation           = $vNet.Location
                        SubnetName             = $subnet.Name
                        SubnetAddressPrefix    = ($subnet.AddressPrefix -join ", ")
                        HasUDR                 = $udrAssigned
                        RouteTableName         = $routeTableName
                        HasInternetRoute       = $hasInternetRoute
                        UdrDefaultNextHops     = ($udrDefaultNextHops -join ";")
                        SubnetHasNATGateway    = $subnetHasNatGateway
                        HasLbOutboundRules     = $subnetHasLbOutbound
                        HasNicPublicIp         = $hasNicWithPublicIp
                        HasVMNICs              = $hasVMNics
                        DefaultOutboundAccess  = $defaultOutboundAccess
                        DefaultOutboundReason  = $reason
                        VNetId                 = $vNet.Id
                        SubnetId               = $subnet.Id
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
) vNet(s) flagged by the criteria" -ForegroundColor Green

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
    Write-Host "`nNo subnets flagged by the criteria." -ForegroundColor Yellow
    if ($subscriptionErrors.Count -gt 0) {
        Write-Host "Some subscriptions failed; check the error CSV if generated." -ForegroundColor Yellow
    }
}

Write-Host "`n🎉 Script completed successfully!" -ForegroundColor Green
Write-Host "📊 Use the generated CSV report for migration planning and compliance review" -ForegroundColor Cyan
