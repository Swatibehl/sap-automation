#region Initialize
# Initialize variables from Environment variables

$ADO_Organization = $Env:SDAF_ADO_ORGANIZATION
$ADO_Project = $Env:SDAF_ADO_PROJECT
$Control_plane_code = $Env:SDAF_CONTROL_PLANE_CODE
$Workload_zone_code = $Env:SDAF_WORKLOAD_ZONE_CODE

$Control_plane_subscriptionID = $Env:SDAF_ControlPlaneSubscriptionID
$Workload_zone_subscriptionID = $Env:SDAF_WorkloadZoneSubscriptionID
$ControlPlaneSubscriptionName = $Env:SDAF_ControlPlaneSubscriptionName
$Workload_zoneSubscriptionName = $Env:SDAF_WorkloadZoneSubscriptionName
#endregion
if ($Env:ARM_TENANT_ID.Length -eq 0) {
  az login --output none
}
else {
  az login --output none --tenant  $Env:ARM_TENANT_ID
}

Write-Host ""
Write-Host ""

if (Test-Path .\start.md) {
  Write-Host "Removing start.md"
  Remove-Item .\start.md
}

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

#region Validate parameters

if ($Control_plane_subscriptionID.Length -eq 0) {
  Write-Host "$Env:ControlPlaneSubscriptionID is not set!" -ForegroundColor Red
  $Control_plane_subscriptionID = Read-Host "Please enter your Control plane subscription ID"
  az account set --sub $Control_plane_subscriptionID
  $ControlPlaneSubscriptionName = (az account show --query name -o tsv)
  exit
}
else {
  az account set --sub $Control_plane_subscriptionID
  $ControlPlaneSubscriptionName = (az account show --query name -o tsv)
}

if ($ControlPlaneSubscriptionName.Length -eq 0) {
  Write-Host "ControlPlaneSubscriptionName is not set"
  exit
}

if ($Workload_zone_subscriptionID.Length -eq 0) {
  Write-Host "$Env:WorkloadZoneSubscriptionID is not set!" -ForegroundColor Red
  $Workload_zone_subscriptionID = Read-Host "Please enter your Workload zone subscription ID"
  az account set --sub $Workload_zone_subscriptionID
  $Workload_zoneSubscriptionName = (az account show --query name -o tsv)

  exit
}
else {
  az account set --sub $Workload_zone_subscriptionID
  $Workload_zoneSubscriptionName = (az account show --query name -o tsv)
}

if ($Workload_zoneSubscriptionName.Length -eq 0) {
  Write-Host "Workload_zoneSubscriptionName is not set"
  exit
}

if ($ADO_Organization.Length -eq 0) {
  Write-Host "Organization is not set"
  $ADO_Organization = Read-Host "Enter your ADO organization URL"
}
else {
  Write-Host "Using Organization: $ADO_Organization" -foregroundColor Yellow
}

if ($Control_plane_code.Length -eq 0) {
  Write-Host "Control plane code is not set  (MGMT, etc)"
  $Control_plane_code = Read-Host "Enter your Control plane code"
}
else {
  Write-Host "Using Control plane code: $Control_plane_code" -foregroundColor Yellow
}

if ($Workload_zone_code.Length -eq 0) {
  Write-Host "Workload zone code is not set  (DEV, etc)"
  $Workload_zone_code = Read-Host "Enter your Workload zone code"
}
else {
  Write-Host "Using Workload zone code: $Workload_zone_code" -foregroundColor Yellow
}

$ApplicationName = $ControlPlanePrefix + "-configuration-app"

if ($Env:SDAF_APP_NAME.Length -ne 0) {
  $ApplicationName = $Env:SDAF_APP_NAME
}

$ControlPlanePrefix = "SDAF-" + $Control_plane_code
$WorkloadZonePrefix = "SDAF-" + $Workload_zone_code
$Pool_Name = $ControlPlanePrefix + "-POOL"

$url = ( az devops project list --organization $ADO_Organization --query "value | [0].url")
if ($url.Length -eq 0) {
  Write-Error "Could not get the DevOps organization URL"
  exit
}

$pipeline_permission_url = ""

$idx = $url.IndexOf("_api")
$pat_url = ($url.Substring(0, $idx) + "_usersSettings/tokens").Replace("""", "")

$import_code = $false

$APP_REGISTRATION_ID = ""
$WEB_APP_CLIENT_SECRET = "Enter your App registration secret here"

#endregion

$fname = "start.md"

Add-Content -Path $fname -Value "# Welcome to the SDAF Wiki"
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value "## Deployment details"
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value "Azure DevOps organization: $ADO_Organization"


#region Install extension

Write-Host "Installing the DevOps extensions" -ForegroundColor Green
$extension_name = (az devops extension list --organization $ADO_Organization --query "[?extensionName=='Post Build Cleanup'].extensionName | [0]")

if ($extension_name.Length -eq 0) {
  az devops extension install --organization $ADO_Organization --extension PostBuildCleanup  --publisher-id mspremier --output none
}

#endregion

#region Create DevOps project
$Project_ID = (az devops project list --organization $ADO_ORGANIZATION --query "[value[]] | [0] | [? name=='$ADO_PROJECT'].id | [0]")

if ($Project_ID.Length -eq 0) {
  Write-Host "Creating the project: " $ADO_PROJECT -ForegroundColor Green
  $Project_ID = (az devops project create --name $ADO_PROJECT --description 'SDAF Automation Project' --organization $ADO_ORGANIZATION --visibility private --source-control git  --query id).Replace("""", "")

  Add-Content -Path $fname -Value ""
  Add-Content -Path $fname -Value "Using Azure DevOps Project: $ADO_PROJECT"

  az devops configure --defaults organization=$ADO_ORGANIZATION project=$ADO_PROJECT

  $repo_id = (az repos list --query "[?name=='$ADO_Project'].id | [0]").Replace("""", "")

  Write-Host "Importing the content from GitHub" -ForegroundColor Green
  az repos import create --git-url https://github.com/Azure/SAP-automation-bootstrap --repository $repo_id --output none

  az repos update --repository $repo_id --default-branch main

  $confirmation = Read-Host "You can optionally import the Terraform and Ansible code from GitHub into Azure DevOps, however, this should only be done if you cannot access github from the Azure DevOps agent or if you intend to customize the code. Do you want to import the code from GitHub y/n?"
  if ($confirmation -eq 'y') {
    Add-Content -Path $fname -Value ""
    Add-Content -Path $fname -Value "Using the code from the sap-automation repository"

    $import_code = $true
    Write-Host "Creating sap-automation repository" -ForegroundColor Green
    $code_repo_id = (az repos create --name sap-automation --query id)
    az repos import create --git-url https://github.com/Azure/SAP-automation --repository $code_repo_id --output none
    az repos update --repository $code_repo_id --default-branch main
    $queryString = "?api-version=6.0-preview"
    $pipeline_permission_url = "$ADO_ORGANIZATION/$projectID/_apis/pipelines/pipelinePermissions/repository/$projectID.$code_repo_id$queryString"
  }
  else {
    Add-Content -Path $fname -Value ""
    Add-Content -Path $fname -Value "Using the code directly from GitHub"

  }
}

else {

  Add-Content -Path $fname -Value ""
  Add-Content -Path $fname -Value "DevOps Project: $ADO_PROJECT"

  $confirmation = Read-Host "Project: $ADO_PROJECT already exists, do you want to import the code from GitHub y/n?"
  $repo_id = (az repos list --query "[?name=='$ADO_Project'].id | [0]").Replace("""", "")
  az devops configure --defaults organization=$ADO_ORGANIZATION project=$ADO_PROJECT

  if ($confirmation -eq 'y') {

    Write-Host "Importing the repository from GitHub" -ForegroundColor Green

    Add-Content -Path $fname -Value ""
    Add-Content -Path $fname -Value "Terraform and Ansible code repository stored in the DevOps project (sap-automation)"

    az repos import create --git-url https://github.com/Azure/SAP-automation-bootstrap --repository $repo_id --output none

    az repos update --repository $repo_id --default-branch main

    $confirmation = Read-Host "You can optionally import Terraform and Ansible code from GitHub into Azure DevOps, however, this should only be done if you cannot access github from the Azure DevOps agent or if you intend to customize the code. Do you want to import the code from GitHub y/n?"
    if ($confirmation -eq 'y') {
      $import_code = $true
      Write-Host "Creating sap-automation repository" -ForegroundColor Green
      $code_repo_id = (az repos create --name sap-automation --query id)
      az repos import create --git-url https://github.com/Azure/SAP-automation --repository $code_repo_id --output none
      az repos update --repository $code_repo_id --default-branch main
    }
  }
  else {
    Add-Content -Path $fname -Value ""
    Add-Content -Path $fname -Value "Using the code directly from GitHub"

    $resources_url = $ADO_ORGANIZATION + "/_git/" + [uri]::EscapeDataString($ADO_Project) + "?path=/pipelines/resources.yml"

    $log = ("Please update [resources.yml](" + $resources_url + ") to point to Github instead of Azure DevOps.")

    $gh_connection_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_settings/adminservices"
    Write-Host ""
    Write-Host "The browser will now open, please create a new Github connection, record the name of the connection."
    Start-Process $gh_connection_url
    Read-Host "Please press enter when you have created the connection"

    $ghConn = (az devops service-endpoint list --query "[?type=='github'].name | [0]")

    Add-Content -Path $fname -Value $log

    Add-Content -Path $fname -Value "Change the following lines in the resources.yml file:"

    Add-Content -Path $fname -Value "type: GitHub"
    Add-Content -Path $fname -Value "name: Azure/sap-automation"
    Add-Content -Path $fname -Value ("endpoint: " + $ghConn)

  }

}

#endregion

$repo_id = (az repos list --query "[?name=='$ADO_Project'].id | [0]").Replace("""", "")
$repo_name = (az repos list --query "[?name=='$ADO_Project'].name | [0]").Replace("""", "")

#region Create pipelines
Write-Host "Creating the pipelines in repo: " $repo_name "(" $repo_id ")" -foregroundColor Green

Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value "### Pipelines"
Add-Content -Path $fname -Value ""

$pipeline_name = 'Create Control Plane configuration'
$sample_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($sample_pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Create sample configuration'  --skip-run --yaml-path "/pipelines/22-sample-deployer-configuration.yml" --repository $repo_id --repository-type tfsgit --output none
  $sample_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $sample_pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log

$bodyText = [PSCustomObject]@{
  pipelines = @([ordered]@{
      id         = $sample_pipeline_id
      authorized = $true
    })
}


$pipeline_name = 'Deploy Control plane'
$control_plane_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($control_plane_pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Deploys the control plane'  --skip-run --yaml-path "/pipelines/01-deploy-control-plane.yml" --repository $repo_id --repository-type tfsgit --output none
  $control_plane_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
}

$bodyText.pipelines += @{
  id         = $control_plane_pipeline_id
  authorized = $true
}


$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $control_plane_pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log

$pipeline_name = 'SAP Workload Zone deployment'
$wz_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($wz_pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Deploys the workload zone'  --skip-run --yaml-path "/pipelines/02-sap-workload-zone.yml" --repository $repo_id --repository-type tfsgit --output none
  $wz_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")

}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $wz_pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log

$bodyText.pipelines += @{
  id         = $wz_pipeline_id
  authorized = $true
}

$pipeline_name = 'SAP SID Infrastructure deployment'
$system_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($system_pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Deploys the infrastructure required for a SAP SID deployment' --skip-run --yaml-path "/pipelines/03-sap-system-deployment.yml" --repository $repo_id --repository-type tfsgit --output none
  $system_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")

}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $system_pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $system_pipeline_id
  authorized = $true
}

$pipeline_name = 'SAP Software acquisition'
$pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Downloads the software from SAP'  --skip-run --yaml-path "/pipelines/04-sap-software-download.yml" --repository $repo_id --repository-type tfsgit --output none
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")

}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

$pipeline_name = 'Configuration and SAP installation'
$installation_pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($installation_pipeline_id.Length -eq 0) {
  $installation_pipeline_id = (az pipelines create --name $pipeline_name --branch main --description 'Configures the Operating System and installs the SAP application' --skip-run --yaml-path "/pipelines/05-DB-and-SAP-installation.yml" --repository $repo_id --repository-type tfsgit --output none)
}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $installation_pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

$pipeline_name = 'Remove System of Workload Zone'
$pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Removes either the SAP system or the workload zone'  --skip-run --yaml-path "/pipelines/10-remover-terraform.yml" --repository $repo_id --repository-type tfsgit --output none
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
}
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

$pipeline_name = 'Remove deployments via ARM'
$pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Removes the resource groups via ARM. Use this only as last resort'  --skip-run --yaml-path "/pipelines/11-remover-arm-fallback.yml" --repository $repo_id --repository-type tfsgit --output none
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
}

$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

$pipeline_name = 'Remove control plane'
$pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
if ($pipeline_id.Length -eq 0) {
  az pipelines create --name $pipeline_name --branch main --description 'Removes the control plane'  --skip-run --yaml-path "/pipelines/12-remove-control-plane.yml" --repository $repo_id --repository-type tfsgit --output none
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
}
$this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $pipeline_id
$log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
Add-Content -Path $fname -Value $log
$bodyText.pipelines += @{
  id         = $pipeline_id
  authorized = $true
}

if ($import_code) {
  $pipeline_name = 'Update repository'
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
  if ($pipeline_id.Length -eq 0) {
    az pipelines create --name $pipeline_name --branch main --description 'Updates the codebase'  --skip-run --yaml-path "/pipelines/20-update-ado-repository.yml" --repository $repo_id --repository-type tfsgit --output none
  }
  $pipeline_id = (az pipelines list  --query "[?name=='$pipeline_name'].id | [0]")
  $this_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $pipeline_id
  $log = ("[" + $pipeline_name + "](" + $this_pipeline_url + ")")
  Add-Content -Path $fname -Value $log
  $bodyText.pipelines += @{
    id         = $pipeline_id
    authorized = $true
  }

}


#endregion

Write-Host "Creating the variable group SDAF-General" -ForegroundColor Green

$general_group_id = (az pipelines variable-group list  --query "[?name=='SDAF-General'].id | [0]" --only-show-errors)
if ($general_group_id.Length -eq 0) {
  az pipelines variable-group create --name SDAF-General --variables ANSIBLE_HOST_KEY_CHECKING=false Deployment_Configuration_Path=WORKSPACES Branch=main S-Username='Enter your S User' S-Password='Enter your S user password' tf_version=1.2.8 ansible_core_version=2.13 --output yaml  --authorize true --output none
  $general_group_id = (az pipelines variable-group list  --query "[?name=='SDAF-General'].id | [0]" --only-show-errors)
}

Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value "### Variable Groups"
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value "SDAF-General"
Add-Content -Path $fname -Value $ControlPlanePrefix
Add-Content -Path $fname -Value $WorkloadZonePrefix

Add-Content -Path $fname -Value "### Credentials"
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value ("Web Application:" + $ApplicationName)

#region App registration
Write-Host "Creating the App registration in Azure Active Directory" -ForegroundColor Green

$found_appRegistration = (az ad app list --show-mine --query "[?displayName=='$ApplicationName'].displayName | [0]" --only-show-errors)

if ($found_appRegistration.Length -ne 0) {
  Write-Host "Found an existing App Registration:" $ApplicationName
  $ExistingData = (az ad app list --show-mine --query "[?displayName=='$ApplicationName']| [0]" --only-show-errors) | ConvertFrom-Json

  $APP_REGISTRATION_ID = $ExistingData.appId

  $confirmation = Read-Host "Reset the app registration secret y/n?"
  if ($confirmation -eq 'y') {
    $WEB_APP_CLIENT_SECRET = (az ad app credential reset --id $APP_REGISTRATION_ID --append --query "password" --only-show-errors)
  }

}
else {
  Write-Host "Creating an App Registration for"  $ApplicationName -ForegroundColor Green
  Add-Content -Path manifest.json -Value '[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"e1fe6dd8-ba31-4d61-89e7-88639da4683d","type":"Scope"}]}]'

  $APP_REGISTRATION_ID = (az ad app create --display-name $ApplicationName --enable-id-token-issuance true --sign-in-audience AzureADMyOrg --required-resource-access .\manifest.json --query "appId").Replace('"', "")

  Remove-Item manifest.json

  $WEB_APP_CLIENT_SECRET = (az ad app credential reset --id $APP_REGISTRATION_ID --append --query "password" --only-show-errors)
}

#endregion

#region Control plane Service Principal
$spn_name = $ControlPlanePrefix + " Deployment credential"
if ($Env:SDAF_MGMT_SPN_NAME.Length -ne 0) {
  $spn_name = $Env:SDAF_MGMT_SPN_NAME
}

Add-Content -Path $fname -Value ("Control Plane Service Principal:" + $spn_name)

$scopes = "/subscriptions/" + $Control_plane_subscriptionID

Write-Host "Creating the deployment credentials for the control plane. Service Principal Name:" $spn_name -ForegroundColor Green

$ARM_CLIENT_ID = ""
$ARM_TENANT_ID = ""
$ARM_CLIENT_SECRET = "Please update"

$SPN_Created = $false

$found_appName = (az ad sp list --show-mine --query "[?displayName=='$spn_name'].displayName | [0]" --only-show-errors)
if ($found_appName.Length -gt 0) {
  Write-Host "Found an existing Service Principal:" $spn_name
  $ExistingData = (az ad sp list --show-mine --query "[?displayName=='$spn_name']| [0]" --only-show-errors) | ConvertFrom-Json
  Write-Host "Updating the variable group"

  $ARM_CLIENT_ID = $ExistingData.appId

  $ARM_TENANT_ID = $ExistingData.appOwnerOrganizationId

  $confirmation = Read-Host "Reset the Control Plane Service Principal password y/n?"
  if ($confirmation -eq 'y') {

    $ARM_CLIENT_SECRET = (az ad sp credential reset --id $ARM_CLIENT_ID --append --query "password" --only-show-errors)
  }

}
else {
  Write-Host "Creating the Service Principal" $spn_name -ForegroundColor Green
  $SPN_Created = $true
  $Control_plane_SPN_data = (az ad sp create-for-rbac --role "Contributor" --scopes $scopes --name $spn_name --only-show-errors) | ConvertFrom-Json
  $ARM_CLIENT_ID = $Control_plane_SPN_data.appId
  $ARM_TENANT_ID = $Control_plane_SPN_data.tenant
  $ARM_CLIENT_SECRET = $Control_plane_SPN_data.password

}

az role assignment create --assignee $ARM_CLIENT_ID --role "Contributor" --subscription $Workload_zone_subscriptionID --output none
az role assignment create --assignee $ARM_CLIENT_ID --role "Contributor" --subscription $Control_plane_subscriptionID --output none

az role assignment create --assignee $ARM_CLIENT_ID --role "User Access Administrator" --subscription $Workload_zone_subscriptionID --output none
az role assignment create --assignee $ARM_CLIENT_ID --role "User Access Administrator" --subscription $Control_plane_subscriptionID --output none


$Control_plane_groupID = (az pipelines variable-group list  --query "[?name=='$ControlPlanePrefix'].id | [0]" --only-show-errors)
if ($Control_plane_groupID.Length -eq 0) {
  Write-Host "Creating the variable group" $ControlPlanePrefix -ForegroundColor Green
  az pipelines variable-group create --name $ControlPlanePrefix --variables Agent='Azure Pipelines' APP_REGISTRATION_APP_ID=$APP_REGISTRATION_ID ARM_CLIENT_ID=$ARM_CLIENT_ID ARM_CLIENT_SECRET='Enter your SPN password here' ARM_SUBSCRIPTION_ID=$Control_plane_subscriptionID ARM_TENANT_ID=$ARM_TENANT_ID WEB_APP_CLIENT_SECRET=$WEB_APP_CLIENT_SECRET PAT='Enter your personal access token here' POOL=$Pool_Name AZURE_CONNECTION_NAME='Control_Plane_Service_Connection' WORKLOADZONE_PIPELINE_ID=$wz_pipeline_id SYSTEM_PIPELINE_ID=$system_pipeline_id SDAF_GENERAL_GROUP_ID=$general_group_id SAP_INSTALL_PIPELINE_ID=$installation_pipeline_id  --output none  --authorize true
  $Control_plane_groupID = (az pipelines variable-group list  --query "[?name=='$ControlPlanePrefix'].id | [0]" --only-show-errors)
}

if ($ARM_CLIENT_SECRET -ne "Please update") {
  az pipelines variable-group variable update --group-id $Control_plane_groupID  --name "ARM_CLIENT_SECRET" --value $ARM_CLIENT_SECRET --secret true --output none --only-show-errors
  az pipelines variable-group variable update --group-id $Control_plane_groupID  --name "ARM_CLIENT_ID" --value $ARM_CLIENT_ID --secret true --output none --only-show-errors
}

Write-Host "Create the Service Endpoint in Azure for the control plane" -ForegroundColor Green

$Service_Connection_Name = "Control_Plane_Service_Connection"
$Env:AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY = $ARM_CLIENT_SECRET

$epExists = (az devops service-endpoint list   --query "[?name=='$Service_Connection_Name'].name | [0]")
if ($epExists.Length -eq 0) {
  Write-Host "Creating Service Endpoint" $Service_Connection_Name -ForegroundColor Green
  az devops service-endpoint azurerm create  --azure-rm-service-principal-id $ARM_CLIENT_ID --azure-rm-subscription-id $Workload_zone_subscriptionID --azure-rm-subscription-name $Workload_zoneSubscriptionName --azure-rm-tenant-id $ARM_TENANT_ID --name $Service_Connection_Name --output none --only-show-errors
  $epId = az devops service-endpoint list  --query "[?name=='$Service_Connection_Name'].id" -o tsv
  az devops service-endpoint update --id $epId --enable-for-all true --output none --only-show-errors
}
else {
  Write-Host "Service Endpoint already exists, recreating it with the updated credentials" -ForegroundColor Green
  az devops service-endpoint delete --id $epId --yes
  az devops service-endpoint azurerm create  --azure-rm-service-principal-id $ARM_CLIENT_ID --azure-rm-subscription-id $Workload_zone_subscriptionID --azure-rm-subscription-name $Workload_zoneSubscriptionName --azure-rm-tenant-id $ARM_TENANT_ID --name $Service_Connection_Name --output none --only-show-errors
  $epId = az devops service-endpoint list  --query "[?name=='$Service_Connection_Name'].id" -o tsv
  az devops service-endpoint update --id $epId --enable-for-all true --output none --only-show-errors
}


$ARM_CLIENT_SECRET = "Please update"

az pipelines variable-group variable update --group-id $Control_plane_groupID  --name "WEB_APP_CLIENT_SECRET" --value $WEB_APP_CLIENT_SECRET --secret true --output none --only-show-errors
#endregion


#region Workload zone Service Principal
Add-Content -path $fname  -value ("Workload zone Service Principal:" + $spn_name)

$workload_zone_scopes = "/subscriptions/" + $Workload_zone_subscriptionID
$workload_zone_spn_name = $Workload_zonePrefix + " Deployment credential"
if ($Env:SDAF_WorkloadZone_SPN_NAME.Length -ne 0) {
  $workload_zone_spn_name = $Env:SDAF_WorkloadZone_SPN_NAME
}

$SPN_Created = $false
$found_appName = (az ad sp list --show-mine --query "[?displayName=='$workload_zone_spn_name'].displayName | [0]" --only-show-errors)

if ($found_appName.Length -ne 0) {
  Write-Host "Found an existing Service Principal:" $workload_zone_spn_name -ForegroundColor Green
  $ExistingData = (az ad sp list --show-mine --query "[?displayName=='$workload_zone_spn_name'] | [0]" --only-show-errors) | ConvertFrom-Json
  $ARM_CLIENT_ID = $ExistingData.appId
  $ARM_TENANT_ID = $ExistingData.appOwnerOrganizationId
  $confirmation = Read-Host "Reset the Workload zone Service Principal password y/n?"
  if ($confirmation -eq 'y') {
    $ARM_CLIENT_SECRET = (az ad sp credential reset --id $ARM_CLIENT_ID --append --query "password" --only-show-errors)
  }
}
else {
  Write-Host "Creating the Service Principal" $workload_zone_spn_name -ForegroundColor Green
  $SPN_Created = $true
  $Data = (az ad sp create-for-rbac --role="Contributor" --scopes=$workload_zone_scopes --name=$workload_zone_spn_name --only-show-errors) | ConvertFrom-Json
  $ARM_CLIENT_ID = $Data.appId
  $ARM_TENANT_ID = $Data.tenant
  $ARM_CLIENT_SECRET = $Data.password

  Write-Host "Create the Service Endpoint in Azure DevOps" -ForegroundColor Green

}

Write-Host "Assigning reader permissions to the control plane subscription" -ForegroundColor Green
az role assignment create --assignee $ARM_CLIENT_ID --role "Reader" --subscription $Control_plane_subscriptionID --output none

$GroupID = (az pipelines variable-group list  --query "[?name=='$WorkloadZonePrefix'].id | [0]" --only-show-errors )
if ($GroupID.Length -eq 0) {
  Write-Host "Creating the variable group" $WorkloadZonePrefix -ForegroundColor Green
  az pipelines variable-group create --name $WorkloadZonePrefix --variables Agent='Azure Pipelines' ARM_CLIENT_ID=$ARM_CLIENT_ID ARM_CLIENT_SECRET=$ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID=$Workload_zone_subscriptionID ARM_TENANT_ID=$ARM_TENANT_ID PAT='Enter your personal access token here' POOL=$Pool_Name AZURE_CONNECTION_NAME=DEV_Service_Connection  --output yaml  --authorize true --output none
  $GroupID = (az pipelines variable-group list  --query "[?name=='$WorkloadZonePrefix'].id | [0]" --only-show-errors)
}


if ($ARM_CLIENT_SECRET -ne "Please update") {
  az pipelines variable-group variable update --group-id $GroupID  --name "ARM_CLIENT_SECRET" --value $ARM_CLIENT_SECRET --secret true --output none --only-show-errors
  az pipelines variable-group variable update --group-id $GroupID  --name "ARM_CLIENT_ID" --value $ARM_CLIENT_ID --secret true --output none --only-show-errors
  $Service_Connection_Name = "WorkloadZone_Service_Connection"
  $Env:AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY = $ARM_CLIENT_SECRET

  $epExists = (az devops service-endpoint list   --query "[?name=='$Service_Connection_Name'].name | [0]")
  if ($epExists.Length -eq 0) {
    Write-Host "Creating Service Endpoint" $Service_Connection_Name -ForegroundColor Green
    az devops service-endpoint azurerm create  --azure-rm-service-principal-id $ARM_CLIENT_ID --azure-rm-subscription-id $Workload_zone_subscriptionID --azure-rm-subscription-name $Workload_zoneSubscriptionName --azure-rm-tenant-id $ARM_TENANT_ID --name $Service_Connection_Name --output none --only-show-errors
    $epId = az devops service-endpoint list  --query "[?name=='$Service_Connection_Name'].id" -o tsv
    az devops service-endpoint update --id $epId --enable-for-all true --output none --only-show-errors
  }
  else {
    Write-Host "Service Endpoint already exists, recreating it with the updated credentials" -ForegroundColor Green
    az devops service-endpoint delete --id $epId --yes
    az devops service-endpoint azurerm create  --azure-rm-service-principal-id $ARM_CLIENT_ID --azure-rm-subscription-id $Workload_zone_subscriptionID --azure-rm-subscription-name $Workload_zoneSubscriptionName --azure-rm-tenant-id $ARM_TENANT_ID --name $Service_Connection_Name --output none --only-show-errors
    $epId = az devops service-endpoint list  --query "[?name=='$Service_Connection_Name'].id" -o tsv
    az devops service-endpoint update --id $epId --enable-for-all true --output none --only-show-errors
  }

}

#endregion

$AlreadySet = [Boolean](az pipelines variable-group variable list --group-id $GroupID --query PAT.isSecret --only-show-errors)

if ($AlreadySet) {
  Write-Host "The PAT is already set" -ForegroundColor Green
}
else {
  Write-Host ""
  Write-Host "The browser will now open, please create a Personal Access Token. Ensure that Read & manage is selected for Agent Pools, Read & write is selected for Code, Read & execute is selected for Build, and Read, create, & manage is selected for Variable Groups"
  Start-Process $pat_url

  $PAT = Read-Host -Prompt "Enter the PAT you just created"
  az pipelines variable-group variable update --group-id $Control_plane_groupID  --name "PAT" --value $PAT --secret true --only-show-errors
  az pipelines variable-group variable update --group-id $GroupID  --name "PAT" --value $PAT --secret true --only-show-errors
  # Create header with PAT
  $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)"))
  $header = @{authorization = "Basic $token" }
  $body = $bodyText | ConvertTo-Json -Depth 10

  Invoke-WebRequest -Method PATCH -Uri $pipeline_permission_url -Headers $header -ContentType "application/json" -Body $body

}

$pool_url = $url.Substring(0, $idx) + "_settings/agentpools"

$POOL_NAME_FOUND = (az pipelines pool list  --query "[?name=='$Pool_Name'].name | [0]")
if ($POOL_NAME_FOUND.Length -gt 0) {
  Write-Host ("Agent pool" + $Pool_Name + "already exists")
}
else {

  Write-Host "Creating agent pool" $Pool_Name -ForegroundColor Green
  $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes((":{0}" -f $PAT)))

  $uri = $ADO_ORGANIZATION + "/_apis/distributedtask/pools?api-version=6.0?authorizePipelines=true"
  $result = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Headers @{Authorization = ("Basic {0}" -f $base64AuthInfo) } `
    -Body (ConvertTo-Json @{name = $Pool_Name; autoProvision = $true })

  Write-Host "Agent pool" $Pool_Name  "created"

}
Write-Host ""
Write-Host "The browser will now open, Select the '" $ADO_PROJECT " Build Service' user and ensure that it has 'Allow' in the Contribute section."

$permissions_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_settings/repositories?_a=permissions"

Start-Process $permissions_url
Read-Host -Prompt "Once you have verified the permission, Press any key to continue"

$pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $sample_pipeline_id

$control_plane_pipeline_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_build?definitionId=" + $control_plane_pipeline_id

$WIKI_NAME_FOUND = (az devops wiki list  --query "[?name=='SDAF'].name | [0]")
if ($WIKI_NAME_FOUND.Length -gt 0) {
  Write-Host "Wiki SDAF already exists"
}
else {
  az devops wiki create --name SDAF
}

Add-Content -Path $fname -Value "## Next steps"
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value ( "Use the [Create Control Plane Configuration Sample](" + $pipeline_url + ") to create the control plane configuration in the region you select." )
Add-Content -Path $fname -Value ""
Add-Content -Path $fname -Value ( "Once it is complete use the [Deploy Control Plane Pipeline ](" + $control_plane_pipeline_url + ") to create the control plane configuration in the region you select.")
Add-Content -Path $fname -Value ""


$eTag = (az devops wiki page show --path 'Next steps' --wiki SDAF --query eTag )
if ($eTag.Length -gt 0) {
  $page_id = (az devops wiki page update --path 'Next steps' --wiki SDAF --file-path .\start.md --only-show-errors --version $eTag --query page.id)
}
else {
  $page_id = (az devops wiki page create --path 'Next steps' --wiki SDAF --file-path .\start.md --output none --only-show-errors --query page.id)
}


$wiki_url = $ADO_ORGANIZATION + "/" + [uri]::EscapeDataString($ADO_Project) + "/_wiki/wikis/SDAF/" + $page_id + "/Next-steps"
Start-Process $wiki_url

if (Test-Path .\start.md) {
  Write-Host "Removing start.md"
  Remove-Item .\start.md
}
