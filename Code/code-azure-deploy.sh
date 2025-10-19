#!/bin/bash
# ===========================================
# Azure Demo Environment Deployment Script
# ===========================================

# --- Variables ---
RG="DemoRG2025"
LOCATION="southeastasia"
Azure_SQL_SERVER_NAME="my-sql-server-demo-2025"
MYSQL_ADMIN="adminuser"
MYSQL_PASS="P@ssowrd2025"
VM_NAME="demoFileServer"
VM_ADMIN="azureuser"
VM_PASS="P@ssowrd2025"
VNET_NAME="demoVNet"
SUBNET_NAME="demoSubnet"
NSG_NAME="demoNSG"
PUBLIC_IP="demoPublicIP"
NIC_NAME="demoNIC"
STORAGE="demostorage28388"
STORAGE_NAME="demostorage28388"
PLAN="funcplan-demo"
FUNCAPP="sharepoint-func-demo"
RUNTIME="powershell"

echo "Creating resource group..."
az group create --name $RG --location $LOCATION

# --- 1. Archive Storage (Blob) ---
echo "Creating storage account for archive data..."
az storage account create \
  --name $STORAGE_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --sku Standard_GRS \
  --kind StorageV2 \
  --access-tier Cool

az storage container create \
  --name archive \
  --account-name $STORAGE_NAME \
  --public-access off

az sql server create \
  --name $Azure_SQL_SERVER_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --admin-user sqladmin \
  --admin-password 'P@ssowrd2025'

echo "Config the firewall to allow connection to Azure SQL"
az sql server firewall-rule create \
  --resource-group $RG \
  --server $Azure_SQL_SERVER_NAME \
  --name AllowMyIP \
  --start-ip-address $(curl -4 -s ifconfig.me) \
  --end-ip-address $(curl -4 -s ifconfig.me)

echo "Create database"
az sql db create \
  --resource-group $RG \
  --server $Azure_SQL_SERVER_NAME \
  --name ServerAuditDB \
  --service-objective S0


# --- 2. Function App (Serverless Code) ---
echo "Creating a consumption plan for Function App..."
az provider register --namespace Microsoft.Web
az functionapp plan create \
  --resource-group $RG \
  --name $PLAN_NAME \
  --location $LOCATION \
  --is-linux \
  --number-of-workers 1 \
  --sku Y1

echo "Creating a Function App..."
az functionapp create \
  --name $FUNC_APP_NAME \
  --resource-group $RG \
  --plan $PLAN_NAME \
  --storage-account $STORAGE_NAME \
  --runtime python \
  --functions-version 4 \
  --os-type Linux

# --- 3. Database (MySQL Flexible Server) ---
echo "Creating MySQL flexible server..."
az mysql flexible-server create \
  --name $MYSQL_SERVER_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --admin-user $MYSQL_ADMIN \
  --admin-password $MYSQL_PASS \
  --tier Burstable \
  --sku-name Standard_B1ms \
  --storage-size 20

# --- 4. On-prem Simulation (Windows VM + AD/File Server) ---
echo "Creating virtual network..."
az network vnet create \
  --resource-group $RG \
  --name $VNET_NAME \
  --subnet-name $SUBNET_NAME

echo "Creating network security group..."
az network nsg create \
  --resource-group $RG \
  --name $NSG_NAME

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $NSG_NAME \
  --name "AllowRDP" \
  --protocol tcp \
  --priority 1000 \
  --destination-port-range 3389 \
  --access Allow

echo "Creating public IP..."
az network public-ip create \
  --resource-group $RG \
  --name $PUBLIC_IP

echo "Creating demoSubnet"
az network vnet subnet create \
  --resource-group DemoRG2025 \
  --vnet-name FileServerVNet \
  --name demoSubnet \
  --address-prefix 10.0.1.0/24

echo "Creating NIC..."
az network nic create \
  --resource-group $RG \
  --name $NIC_NAME \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --network-security-group $NSG_NAME \
  --public-ip-address $PUBLIC_IP

echo "Creating Windows Server VM (File + AD)..."
az vm create \
  --resource-group $RG \
  --name $VM_NAME \
  --image Win2022Datacenter \
  --admin-username $VM_ADMIN \
  --admin-password $VM_PASS \
  --nics $NIC_NAME \
  --size Standard_B1s

az vm open-port \
  --port 3389 \
  --resource-group $RG \
  --name $VM_NAME

# ---5. Install Azure AD
az vm run-command invoke \
  --command-id RunPowerShellScript \
  --name $VM_NAME \
  --resource-group $RG \
  --scripts "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools"

## ---6. Create AD forest
az vm run-command invoke \
  --command-id RunPowerShellScript \
  --name $VM_NAME \
  --resource-group $RG \
  --scripts 'Install-ADDSForest -DomainName "corp.local" -SafeModeAdministratorPassword (ConvertTo-SecureString "P@ssword1234!" -AsPlainText -Force) -Force:$true'

## --- 7. Download & Install Azure AD Connect
az vm run-command invoke \
  --command-id RunPowerShellScript \
  --name $VM_NAME \
  --resource-group $RG \
  --scripts "Invoke-WebRequest -Uri https://download.microsoft.com/download/9/5/E/95E0A2E7-5C7F-4746-9E4D-3EDB5E0B5A3A/AzureADConnect.msi -OutFile C:\\AzureADConnect.msi"

  echo "Install Azure AD connect"
  az vm run-command invoke \
  --command-id RunPowerShellScript \
  --name $VM_NAME \
  --resource-group $RG \
  --scripts "Start-Process msiexec.exe -ArgumentList '/i C:\\AzureADConnect.msi /quiet /norestart' -Wait"

## ---8. Configure Azure AD Connect
echo "Create a configuration file C:\ADSyncConfig.ini"
[Configuration]
SyncMode=Sync
AADUser=admin@ssis.onmicrosoft.com
AADPassword=P@ssowrd2025
ADDomain=corp.local
ADUser=CORP\Administrator
ADPassword=P@ssowrd2025



