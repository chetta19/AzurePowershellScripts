#Requires -Modules Az.Resources

# Authenticate to Azure
$psAzureProfile = Connect-AzAccount

if($null -eq $psAzureProfile)
{
    Exit
}

# Select the source subscription
$sourceSubscription = Get-AzSubscription | Out-GridView -Title "Select the source subscription" -PassThru

if($null -eq $sourceSubscription)
{
    Exit
}

# Select the destination subscription
$destinationSubscription = Get-AzSubscription | Out-GridView -Title "Select the destination subscription" -PassThru

if($null -eq $destinationSubscription)
{
    Exit
}

$srcSubId = "/subscriptions/" + $sourceSubscription.Id
$destSubId = "/subscriptions/" + $destinationSubscription.Id

#Get the RoleManagementPolicyAssignment from the the source subscription
Write-Host "Fetching source RoleManagementPolicyAssignment"
$srcRoleManagementPolicyAssignments = Get-AzRoleManagementPolicyAssignment -Scope $srcSubId
Write-Host "Fetched $($srcRoleManagementPolicyAssignments.Count) source RoleManagementPolicyAssignment"
#Get the RoleManagementPolicyAssignment from the the destination subscription
Write-Host "Fetching destination RoleManagementPolicyAssignment"
$destRoleManagementPolicyAssignments = Get-AzRoleManagementPolicyAssignment -Scope $destSubId
Write-Host "Fetched $($destRoleManagementPolicyAssignments.Count) destination RoleManagementPolicyAssignment"

# Get the list of role eligibility in the source subscription
$srcRoleEligibilities = Get-AzRoleEligibilityScheduleRequest -Scope $srcSubId -Filter "atScope()" | Where-Object {($_.ScopeId -EQ $srcSubId) -and ($_.Status -eq "Provisioned")}
$counter = 1

$srcRoleEligibilityRoleDefinitionIds = $srcRoleEligibilities| Select-Object RoleDefinitionId -Unique

foreach ($srcRoleEligibilityRoleDefinitionId in $srcRoleEligibilityRoleDefinitionIds) {
    $roleDefinitionId = $srcRoleEligibilityRoleDefinitionId.RoleDefinitionId -split '/' | Select-Object -Last 1
    $destRoleDefinitionId = "$($destSubId)/providers/Microsoft.Authorization/roleDefinitions/$($roleDefinitionId)"

    #Update the policy (Role setting details) for role from the source to the destination
    $destRoleManagementPolicyAssignment = $destRoleManagementPolicyAssignments | Where-Object -Property "RoleDefinitionId" -EQ -Value $destRoleDefinitionId
    $srcRoleManagementPolicyAssignment = $srcRoleManagementPolicyAssignments | Where-Object -Property "RoleDefinitionId" -EQ -Value $srcRoleEligibilityRoleDefinitionId.RoleDefinitionId


    $srcRoleManagementPolicyAssignmentPolicyName = $srcRoleManagementPolicyAssignment.PolicyId -split '/' | Select-Object -Last 1
    $destRoleManagementPolicyAssignmentPolicyName = $destRoleManagementPolicyAssignment.PolicyId -split '/' | Select-Object -Last 1

    $srcRoleManagementPolicy = Get-AzRoleManagementPolicy -Scope $srcRoleManagementPolicyAssignment.Scope -Name $srcRoleManagementPolicyAssignmentPolicyName
    Write-Host "Copying Role Management Policy $($counter)/$($srcRoleEligibilityRoleDefinitionIds.Count) - $($srcRoleEligibilityRoleDefinitionId.RoleDefinitionId)"
    Update-AzRoleManagementPolicy -Scope $destSubId -Name $destRoleManagementPolicyAssignmentPolicyName -Rule $srcRoleManagementPolicy.Rule -Description "Copied from $($srcRoleManagementPolicyAssignment.PolicyId)" | Out-Null

    $counter++
}

# Recreate each role PIM eligibility to it in the destination subscription
$counter = 1
 foreach ($roleEligibility in $srcRoleEligibilities) {
    $roleDefinitionId = $roleEligibility.RoleDefinitionId -split '/' | Select-Object -Last 1
    $destRoleDefinitionId = "$($destSubId)/providers/Microsoft.Authorization/roleDefinitions/$($roleDefinitionId)"

    Write-Host "Copying role eligibility $($counter)/$($srcRoleEligibilities.Count) - RoleDefId $($roleDefinitionId) - PrincipaleId $($roleEligibility.PrincipalId)"
    $counter++

    $params = @{
        Name = New-Guid
        Scope = $destSubId
        RoleDefinitionId = $destRoleDefinitionId
        PrincipalId = $roleEligibility.PrincipalId
        RequestType = $roleEligibility.RequestType
        Justification =  "Copying from $($srcSubId)"
        ScheduleInfoStartDateTime = Get-Date -Format o
        ExpirationDuration = "PT1H"
        ExpirationType = $roleEligibility.ExpirationType
    }

    if($null -ne $roleEligibility.ExpirationDuration)
    {
        $params.ExpirationDuration = $roleEligibility.ExpirationDuration
    }

    if($null -ne $roleEligibility.EndDateTime)
    {
        $params.ExpirationEndDateTime = $roleEligibility.ExpirationEndDateTime
    }

    New-AzRoleEligibilityScheduleRequest @params -ErrorAction SilentlyContinue | Out-Null
 }
