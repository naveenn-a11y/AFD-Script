
# Set initial parameters
$ResourceGroup = "WnkWeb"
$ProfileName = "winkprodfd"
$OutputFile = "AFD_Route_Origin_Mapping.csv"

# --- 1. Cache Origin Group Details ---
# This is crucial for performance, preventing redundant calls to fetch the same origin group multiple times.
Write-Host "--- 1. Fetching and Caching all Origin Group details..."
$OriginGroupsCache = @{}
$OriginGroups = az afd origin-group list --resource-group $ResourceGroup --profile-name $ProfileName --output json | ConvertFrom-Json

foreach ($og in $OriginGroups) {
    $OriginsList = @()
    # Fetch the actual origins within this group to get the backend hostnames/URLs
    $Origins = az afd origin list --resource-group $ResourceGroup --profile-name $ProfileName --origin-group-name $og.name --output json | ConvertFrom-Json

    if ($Origins) {
        $OriginsList = $Origins | Select-Object -ExpandProperty hostName
    }

    $OriginGroupsCache[$og.name] = $OriginsList
    Write-Host "   Cached Origin Group $($og.name) with $($OriginsList.Count) origins."
}


# --- 2. Iterate through Endpoints and Routes to build the final list ---
Write-Host "--- 2. Fetching Endpoints and Routes..."
$FinalMapping = @()
$Endpoints = az afd endpoint list --resource-group $ResourceGroup --profile-name $ProfileName --output json | ConvertFrom-Json

foreach ($ep in $Endpoints) {
    $EndpointName = $ep.name
    $DefaultDomain = $ep.hostName  # Use the default Front Door Endpoint domain
    
    Write-Host "Processing Endpoint: $EndpointName"

    $Routes = az afd route list --resource-group $ResourceGroup --profile-name $ProfileName --endpoint-name $EndpointName --output json | ConvertFrom-Json

    foreach ($route in $Routes) {
        $RouteName = $route.name
        
        # Fetch detailed route object (needed for all custom domains and patterns)
        $RouteDetails = az afd route show --resource-group $ResourceGroup --profile-name $ProfileName --endpoint-name $EndpointName --route-name $RouteName --output json | ConvertFrom-Json
        
        $CustomDomains = @()
        if ($RouteDetails.customDomains) {
            # Extract just the hostname (name property) from the CustomDomain objects
            $CustomDomains = $RouteDetails.customDomains | ForEach-Object { 
                # This logic is tricky: sometimes 'id' contains the domain name, sometimes it's nested
                # Let's clean it up to just the domain part (e.g., downloadwink-com)
                if ($_.id) {
                    $_.id.Split("/")[-1]
                }
            }
        }
        
        # Extract necessary properties
        $PatternToMatch = $RouteDetails.patternsToMatch -join ", "
        $OriginGroupName = ($RouteDetails.originGroup.id -split "/")[-1]
        
        # Look up App Service URLs from the cache
        $AppServiceURLs = $OriginGroupsCache[$OriginGroupName] -join "; "
        if (-not $AppServiceURLs) {
            $AppServiceURLs = "ERROR: Origin Group '$OriginGroupName' not found or has no Origins."
        }

        # Create the custom object matching the requested format
        $FinalMapping += [PSCustomObject]@{
            Domain          = $DefaultDomain
            CustomDomains   = $CustomDomains -join ", "
            EndpointName    = $EndpointName
            RouteName       = $RouteName
            Pattern         = $PatternToMatch
            OriginGroup     = $OriginGroupName
            AppServiceURLs  = $AppServiceURLs
        }
    }
}

# --- 3. Export to CSV ---
Write-Host "--- 3. Exporting results to $OutputFile"
$FinalMapping | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "✅ Export Complete. Results written to $OutputFile"
