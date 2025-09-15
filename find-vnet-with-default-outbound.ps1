# Azure vNet Default Outbound Internet Access Detection Script
# This script identifies vNets that are using Default Outbound internet access

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

# Help function
function Show-Help {
    $helpText = @"

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
       • UDR assigned with at least one route with destination "0.0.0.0/0" or "Internet"
       • Subnet contains Network Interfaces from Virtual Machines

SYNTAX:
    .\script.ps1 [parameters]

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
    • HasUDR/RouteTableName             • HasInternetRoute
    • VNetHasNATGateway                 • VNetHasLoadBalancer
    • HasVMNICs                         • DefaultOutboundReason
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

VERSION: 2.0
AUTHOR: Azure Network Security Assessment Tool
LAST UPDATED: $(Get-Date -Format 'yyyy-MM-dd')

"@

    Write-Host $helpText -ForegroundColor Cyan
}

# Check if help was requested
if ($Help) {
    Show-Help
    return
}

# Validate parameter combinations
if ($TenantWide -and $SubscriptionId) {
    Write-Error "Cannot specify both -TenantWide and -SubscriptionId. Please use one or the other."
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}

if (($ExcludeSubscriptions.Count -gt 0 -or $IncludeSubscriptions.Count -gt 0) -and -not $TenantWide) {
    Write-Error "Subscription filters (-ExcludeSubscriptions, -IncludeSubscriptions) can only be used with -TenantWide"
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}

if ($ExcludeSubscriptions.Count -gt 0 -and $IncludeSubscriptions.Count -gt 0) {
    Write-Error "Cannot use both -ExcludeSubscriptions and -IncludeSubscriptions simultaneously"
    Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
    exit 1
}

# Ensure Azure PowerShell module is available
if (-not (Get-Module -ListAvailable -Name Az.Network)) {
    Write-Error "Azure PowerShell module (Az.Network) is not installed. Please install it using: Install-Module -Name Az -Force"
    Write-Host "Use -Help for more information about prerequisites" -ForegroundColor Yellow
    exit 1
}

# Connect to Azure if not already connected
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not connected to Azure. Please sign in..." -ForegroundColor Yellow
        Connect-AzAccount
    }
} catch {
    Write-Host "Please sign in to Azure..." -ForegroundColor Yellow
    Connect-AzAccount
}

# Display current operation mode
# Get list of subscriptions to analyze
$subscriptionsToScan = @()
    Write-Host "🌐 TENANT-WIDE SCAN MODE" -ForegroundColor Magenta
    if ($IncludeSubscriptions.Count -gt 0) {
        Write-Host "   📋 Including only: $($IncludeSubscriptions -join ', ')" -ForegroundColor Cyan
    }
    if ($ExcludeSubscriptions.Count -gt 0) {
        Write-Host "   🚫 Excluding: $($ExcludeSubscriptions -join ', ')" -ForegroundColor Cyan
    }
} elseif ($SubscriptionId) {
    Write-Host "🎯 SINGLE SUBSCRIPTION MODE: $SubscriptionId" -ForegroundColor Magenta
} else {
    Write-Host "🎯 CURRENT SUBSCRIPTION MODE" -ForegroundColor Magenta
}

if ($TenantWide) {
if ($TenantWide) {
    
    try {
        $allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
        
        # Apply inclusion filter if specified
        if ($IncludeSubscriptions.Count -gt 0) {
            $allSubscriptions = $allSubscriptions | Where-Object { 
                $_.Id -in $IncludeSubscriptions -or $_.Name -in $IncludeSubscriptions 
            }
        }
        
        # Apply exclusion filter
        if ($ExcludeSubscriptions.Count -gt 0) {
            $allSubscriptions = $allSubscriptions | Where-Object { 
                $_.Id -notin $ExcludeSubscriptions -and $_.Name -notin $ExcludeSubscriptions 
            }
        }
        
    Write-Host "🔍 Retrieving all accessible subscriptions..." -ForegroundColor Cyan
        
        $subscriptionsToScan = $allSubscriptions
        Write-Host "✅ Found $($subscriptionsToScan.Count) accessible subscriptions to scan" -ForegroundColor Green
        
        if ($subscriptionsToScan.Count -eq 0) {
            Write-Error "❌ No subscriptions found to scan. Check your filters or permissions."
            Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Error "❌ Failed to retrieve subscriptions: $($_.Exception.Message)"
        Write-Host "Use -Help for troubleshooting information" -ForegroundColor Yellow
        exit 1
    }

# Initialize results array
$results = @()
$subscriptionErrors = @()
$totalVNets = 0

# Process each subscription
foreach ($subscription in $subscriptionsToScan) {
    Write-Host "`n" -NoNewline
    Write-Host "=== Processing Subscription: $($subscription.Name) ($($subscription.Id)) ===" -ForegroundColor Magenta
    
    try {
        # Set context to current subscription
        $context = Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop
        Write-Host "Successfully switched to subscription context" -ForegroundColor Green
        
        # Get all virtual networks in this subscription
        Write-Host "Retrieving virtual networks..." -ForegroundColor Cyan
        $vNets = Get-AzVirtualNetwork -ErrorAction Stop
        $totalVNets += $vNets.Count
        
        Write-Host "Found $($vNets.Count) virtual networks in this subscription" -ForegroundColor Cyan
        
        if ($vNets.Count -eq 0) {
            Write-Host "No virtual networks found in this subscription. Skipping..." -ForegroundColor Yellow
            continue
        }

        foreach ($vNet in $vNets) {
            Write-Host "  Analyzing vNet: $($vNet.Name) in RG: $($vNet.ResourceGroupName)" -ForegroundColor Yellow
            
            # Get NAT Gateways and Load Balancers in the same resource group and location
            $natGateways = Get-AzNatGateway -ResourceGroupName $vNet.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $vNet.Location }
            $loadBalancers = Get-AzLoadBalancer -ResourceGroupName $vNet.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $vNet.Location }
            
            # Check if vNet has NAT Gateway or Load Balancer associated
            $vNetHasNatGateway = $false
            $vNetHasLoadBalancer = $false
            
            # Check for NAT Gateway associations
            foreach ($subnet in $vNet.Subnets) {
                if ($subnet.NatGateway) {
                    $vNetHasNatGateway = $true
                    break
                }
            }
            
            # Check for Load Balancer associations (check if any LB has backend pools in this vNet)
            foreach ($lb in $loadBalancers) {
                foreach ($backendPool in $lb.BackendAddressPools) {
                    if ($backendPool.BackendIpConfigurations) {
                        foreach ($ipConfig in $backendPool.BackendIpConfigurations) {
                            if ($ipConfig.Id -match "/virtualNetworks/$($vNet.Name)/") {
                                $vNetHasLoadBalancer = $true
                                break
                            }
                        }
                    }
                }
                if ($vNetHasLoadBalancer) { break }
            }
            
            # Analyze each subnet
            foreach ($subnet in $vNet.Subnets) {
                Write-Host "    Checking subnet: $($subnet.Name)" -ForegroundColor Gray
                
                # Check if subnet has NICs from VMs
                $hasVMNics = $false
                if ($subnet.IpConfigurations) {
                    foreach ($ipConfig in $subnet.IpConfigurations) {
                        # Check if the IP configuration belongs to a VM NIC
                        if ($ipConfig.Id -match "/networkInterfaces/") {
                            try {
                                $nicId = ($ipConfig.Id -split "/ipConfigurations/")[0]
                                $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction SilentlyContinue
                                if ($nic -and $nic.VirtualMachine) {
                                    $hasVMNics = $true
                                    break
                                }
                            } catch {
                                # Continue if unable to get NIC details
                            }
                        }
                    }
                }
                
                # Skip if no VM NICs in this subnet
                if (-not $hasVMNics) {
                    continue
                }
                
                # Check UDR assignment
                $udrAssigned = $subnet.RouteTable -ne $null
                $hasInternetRoute = $false
                
                if ($udrAssigned) {
                    # Get route table details
                    try {
                        $routeTable = Get-AzRouteTable -ResourceId $subnet.RouteTable.Id
                        foreach ($route in $routeTable.Routes) {
                            if ($route.AddressPrefix -eq "0.0.0.0/0" -or $route.AddressPrefix.ToLower() -eq "internet") {
                                $hasInternetRoute = $true
                                break
                            }
                        }
                    } catch {
                        Write-Warning "Could not retrieve route table details for subnet $($subnet.Name)"
                    }
                }
                
                # Determine if this subnet meets the criteria for Default Outbound access
                $meetsDefaultOutboundCriteria = $false
                $reason = ""
                
                if (-not $udrAssigned -and -not $vNetHasNatGateway -and -not $vNetHasLoadBalancer -and $hasVMNics) {
                    # Criteria 1: No UDR, no NAT Gateway, no Load Balancer, has VM NICs
                    $meetsDefaultOutboundCriteria = $true
                    $reason = "No UDR assigned, no NAT Gateway, no Load Balancer, has VM NICs"
                } elseif ($udrAssigned -and $hasInternetRoute -and $hasVMNics) {
                    # Criteria 2: Has UDR with Internet route, has VM NICs
                    $meetsDefaultOutboundCriteria = $true
                    $reason = "UDR assigned with Internet route, has VM NICs"
                }
                
                if ($meetsDefaultOutboundCriteria) {
                    Write-Host "      ✓ Subnet meets Default Outbound criteria: $reason" -ForegroundColor Green
                    
                    $result = [PSCustomObject]@{
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        ResourceGroupName = $vNet.ResourceGroupName
                        VNetName = $vNet.Name
                        VNetLocation = $vNet.Location
                        SubnetName = $subnet.Name
                        SubnetAddressPrefix = $subnet.AddressPrefix -join ", "
                        HasUDR = $udrAssigned
                        RouteTableName = if ($udrAssigned) { ($subnet.RouteTable.Id -split "/")[-1] } else { "None" }
                        HasInternetRoute = $hasInternetRoute
                        VNetHasNATGateway = $vNetHasNatGateway
                        VNetHasLoadBalancer = $vNetHasLoadBalancer
                        HasVMNICs = $hasVMNics
                        DefaultOutboundReason = $reason
                        VNetId = $vNet.Id
                        SubnetId = $subnet.Id
                    }
                    
                    $results += $result
                }
            }
        }
        
} elseif ($SubscriptionId) {
    # Single subscription specified
    try {
        $targetSub = Get-AzSubscription -SubscriptionId $SubscriptionId
        $subscriptionsToScan = @($targetSub)
        Write-Host "✅ Target subscription found: $($targetSub.Name)" -ForegroundColor Green
    } catch {
        Write-Error "❌ Could not find subscription: $SubscriptionId"
        Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
        exit 1
    }
} else {
    # Use current subscription
    $currentSubscription = (Get-AzContext).Subscription
    if (-not $currentSubscription) {
        Write-Error "❌ No subscription context found. Please specify -SubscriptionId or use -TenantWide"
        Write-Host "Use -Help for usage examples" -ForegroundColor Yellow
        exit 1
    }
    $subscriptionsToScan = @($currentSubscription)
    Write-Host "✅ Using current subscription: $($currentSubscription.Name)" -ForegroundColor Green
}
        
    } catch {
        Write-Host "✅ Completed analysis of subscription: $($subscription.Name)" -ForegroundColor Green
        
        $subscriptionErrors += [PSCustomObject]@{
            SubscriptionId = $subscription.Id
            SubscriptionName = $subscription.Name
            ErrorMessage = $_.Exception.Message
            ErrorDetails = $_.Exception.ToString()
        }
        
        continue
    }
}

# Display results
Write-Host "`n" -NoNewline
Write-Host "=== TENANT-WIDE ANALYSIS COMPLETE ===" -ForegroundColor Green

if ($TenantWide) {
    Write-Host "Scanned $($subscriptionsToScan.Count) subscriptions with $totalVNets total virtual networks" -ForegroundColor Cyan
    if ($subscriptionErrors.Count -gt 0) {
        Write-Host "Encountered errors in $($subscriptionErrors.Count) subscription(s)" -ForegroundColor Red
    }
}

Write-Host "Found $($results.Count) subnets in $($results | Select-Object VNetName, SubscriptionId -Unique | Measure-Object | Select-Object -ExpandProperty Count) vNets using Default Outbound internet access" -ForegroundColor Green

if ($results.Count -gt 0) {
    Write-Host "`nSummary by Subscription:" -ForegroundColor Cyan
    $results | Group-Object SubscriptionName | ForEach-Object {
        $subResults = $_.Group | Group-Object VNetName
        Write-Host "  📋 $($_.Name): $($subResults.Count) vNet$(if($subResults.Count -ne 1){'s'}), $($_.Count) subnet$(if($_.Count -ne 1){'s'})" -ForegroundColor White
        $subResults | ForEach-Object {
            Write-Host "    • $($_.Name) ($($_.Count) subnet$(if($_.Count -ne 1){'s'}))" -ForegroundColor Gray
        }
    }
    
    # Export to CSV
    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host "`nDetailed results exported to: $OutputPath" -ForegroundColor Green
    
    # Export subscription errors if any
    if ($subscriptionErrors.Count -gt 0) {
        $errorPath = $OutputPath -replace "\.csv$", "_Errors.csv"
        $subscriptionErrors | Export-Csv -Path $errorPath -NoTypeInformation
        Write-Host "Subscription errors exported to: $errorPath" -ForegroundColor Yellow
    }
    
    # Display first few results as table
    Write-Host "`nFirst 10 results:" -ForegroundColor Cyan
    $results | Select-Object -First 10 | Format-Table SubscriptionName, VNetName, SubnetName, DefaultOutboundReason, VNetLocation -AutoSize
} else {
    Write-Host "`nNo vNets found using Default Outbound internet access across all scanned subscriptions." -ForegroundColor Yellow
}

# Display any subscription errors
if ($subscriptionErrors.Count -gt 0) {
    Write-Host "`n⚠️  Subscription Processing Errors:" -ForegroundColor Red
    $subscriptionErrors | ForEach-Object {
        Write-Host "    ❌ $($_.SubscriptionName): $($_.ErrorMessage)" -ForegroundColor Red
    }
    Write-Host "    💡 Check the error log CSV for detailed troubleshooting information" -ForegroundColor Yellow
}

Write-Host "`n🎉 Script completed successfully!" -ForegroundColor Green
Write-Host "📊 Use the generated CSV report for migration planning and compliance review" -ForegroundColor Cyan
Write-Host "💡 Run with -Help for additional usage information" -ForegroundColor Gray

