###############################################################################
# Install az cli
###############################################################################

# Refresh packages
apt-get update
apt-get upgrade

# From:
# https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=apt
sudo apt-get update
sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg

# Download the microsoft signing keys
curl -sL https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor |
    sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

# Add the Azure CLI software repository:
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |
    sudo tee /etc/apt/sources.list.d/azure-cli.list

# Update repository information and install the azure-cli package:
sudo apt-get update
sudo apt-get install azure-cli

###############################################################################
# Install kubectl (latest stable version)
###############################################################################

# Download the latest release 
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Download the kubectl checksum file:
curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"

# Validate the kubectl binary against the checksum file:
echo "$(<kubectl.sha256)  kubectl" | sha256sum --check

# Install kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client

# Install auto-completion
# OPTIONAL
# -
sudo apt-get install bash-completion
source /usr/share/bash-completion/bash_completion

###############################################################################
# Install Helm
# 
# Reference: 
###############################################################################

# Add signing keys
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -

# Install dependencies
sudo apt-get install apt-transport-https --yes

# Add repository
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update

# Install helm
sudo apt-get install helm

# Verify
helm version

###############################################################################
# Setup AKS via Azure CLI
###############################################################################

# Authenticate with Azure CLI
az login

# list regions with az
az account list-locations

# Create a resource group for our AKS cluster
az group create --name GitHubActionsRunners --location westeurope

# Get list of resources in the resource group
az group show --resource-group GitHubActionsRunners

# Verify Microsoft.OperationsManagement and Microsoft.OperationalInsights 
# are registered on your subscription.
az provider show -n Microsoft.OperationsManagement -o table
az provider show -n Microsoft.OperationalInsights -o table

# Create AKS cluster in resource group
# --name cannot exceed 63 characters and can only contain letters, 
# numbers, or dashes (-).
az aks create \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --enable-addons monitoring \
  --node-count 1 \
  --generate-ssh-keys

###############################################################################
# Access K8s cluster
###############################################################################

# Configure kubectl to connect to your Kubernetes cluster
# Downloads credentials and configures the Kubernetes CLI to use them.
  # Uses ~/.kube/config, the default location for the Kubernetes configuration 
  # file. Specify a different location for your Kubernetes configuration file 
  # using --file.
az aks get-credentials \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster

# Verify
kubectl config get-contexts
# AND
kubectl get nodes

###############################################################################
# Manually scaling nodes
###############################################################################

# Scale up
az aks scale \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --node-count 3

# Scale down
az aks scale \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --node-count 1

# Check progress
watch -n 3 kubectl get nodes

###############################################################################
# Create ACR
# 
# Reference: https://docs.microsoft.com/en-us/azure/aks/cluster-container-registry-integration?tabs=azure-cli
###############################################################################

# Create an Azure Container Registry instance
  # The Basic SKU is a cost-optimized entry point for development purposes 
  # that provides a balance of storage and throughput.
  # --name | 'registry_name': must conform to the following pattern: '^[a-zA-Z0-9]*$'
az acr create \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsOHACR \
  --sku Basic

# Integrate the new ACR with our existing AKS cluster
az aks update \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --attach-acr GitHubActionsOHACR

# Check that AKS can successfully connect to our ACR
# 1. Get ACR FQDN
ACR_URL=$(az acr show \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsOHACR \
  --query loginServer \
  --output tsv) \
  && echo $ACR_URL

# OUTPUT: githubactionsohacr.azurecr.io

# 2. Do the check
  # REPLACE VALUE OF LOGIN_SERVER WITH YOUR ACR FQDN
az aks check-acr \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --acr $ACR_URL

###############################################################################
# Enable application gateway for our AKS cluster
###############################################################################

# First create a public IP resource
az network public-ip create \
  --resource-group GitHubActionsRunners \
  --name APGWPublicIp \
  --allocation-method Static \
  --sku Standard

# Create the AppGW VNet
az network vnet create \
  --name appgwVNet \
  --resource-group GitHubActionsRunners \
  --address-prefix 11.0.0.0/8 \
  --subnet-name appgwSubnet \
  --subnet-prefix 11.1.0.0/16

# Create application gateway
# REPLACE PLACEHOLDERS
az network application-gateway create \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersAPGW \
  --location westeurope \
  --sku Standard_v2 \
  --public-ip-address APGWPublicIp \
  --vnet-name appgwVNet \
  --subnet appgwSubnet

# Attach APGW to our AKS
APPGW_ID=$(az network application-gateway show \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersAPGW \
  --query "id" \
  --output tsv) \
  && echo $APPGW_ID

# Enable APGW addon
# REPLACE PLACEHOLDERS
az aks enable-addons \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --addons ingress-appgw \
  --appgw-id $APPGW_ID

# Peer the 2 VNets
##################

# Get AKS Cluster associated resource group
NODERESOURCEGROUP=$(az aks show \
  --name GitHubActionsRunnersK8sCluster \
  --resource-group GitHubActionsRunners \
  --query "nodeResourceGroup" \
  --output tsv) \
  && echo $NODERESOURCEGROUP

# Get AKS Cluster associated VNet from the resource group
AKSVNETNAME=$(az network vnet list \
  --resource-group $NODERESOURCEGROUP \
  --query "[0].name" \
  --output tsv) \
  && echo $AKSVNETNAME

# Get the AKS Cluster VNet ID
AKSVNETID=$(az network vnet show \
  --name $AKSVNETNAME \
  --resource-group $NODERESOURCEGROUP \
  --query "id" \
  --output tsv) \
  && echo $AKSVNETID

# Peer the AppGateway VNet to the AKS VNet
az network vnet peering create \
  --name AppGWtoAKSVnetPeering \
  --resource-group GitHubActionsRunners \
  --vnet-name appgwVNet \
  --remote-vnet $AKSVNETID \
  --allow-vnet-access

# Get AppGateway VNet ID
APPGWVNETID=$(az network vnet show \
  --name appgwVNet \
  --resource-group GitHubActionsRunners \
  --query "id" \
  --output tsv) \
  && echo $APPGWVNETID

# Peer the AKS VNet to the AppGateway VNet
az network vnet peering create \
  --name AKStoAppGWVnetPeering \
  --resource-group $NODERESOURCEGROUP \
  --vnet-name $AKSVNETNAME \
  --remote-vnet $APPGWVNETID \
  --allow-vnet-access

###############################################################################
# Create and deploy a simple testing app
###############################################################################

kubectl apply -f apps/test-app.yaml --namespace default
kubectl apply -f ingress/ingress.yaml --namespace default

# Add a DNS alias for the public ip (manually)

# Fetch the DNS alias
APGW_FQDN=$(az network public-ip show \
  --resource-group GitHubActionsRunners \
  --name APGWPublicIp \
  --query dnsSettings.fqdn \
  --output tsv) \
  && echo $APGW_FQDN

curl -G http://${APGW_FQDN}/

###############################################################################
# Create Cert Manager and setup TLS termination
###############################################################################

ACR_URL=githubactionsohacr.azurecr.io
REGISTRY_NAME=GitHubActionsOHACR
CERT_MANAGER_REGISTRY=quay.io
CERT_MANAGER_TAG=v1.6.1
CERT_MANAGER_IMAGE_CONTROLLER=jetstack/cert-manager-controller
CERT_MANAGER_IMAGE_WEBHOOK=jetstack/cert-manager-webhook
CERT_MANAGER_IMAGE_CAINJECTOR=jetstack/cert-manager-cainjector

# Import all the images and helm charts to our ACR
az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG \
&& az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG \
&& az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG

# Create cert-manager namespace
kubectl create namespace cert-manager

# Label the cert-manager namespace to disable resource validation
kubectl label namespace cert-manager cert-manager.io/disable-validation=true

# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io

# Update your local Helm chart repository cache
helm repo update

# Install the cert-manager Helm chart
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version $CERT_MANAGER_TAG \
  --set installCRDs=true \
  --set nodeSelector."kubernetes\.io/os"=linux \
  --set image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_CONTROLLER \
  --set image.tag=$CERT_MANAGER_TAG \
  --set webhook.image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_WEBHOOK \
  --set webhook.image.tag=$CERT_MANAGER_TAG \
  --set cainjector.image.repository=$ACR_URL/$CERT_MANAGER_IMAGE_CAINJECTOR \
  --set cainjector.image.tag=$CERT_MANAGER_TAG

# Create an issuer: cluster-issuer.yaml;
# Apply the configuration - it has to be without a namespace!!
kubectl apply -f cert-manager/cluster-issuer-staging.yaml

# Update the ingress controller to use the cert-manager issuer
# kubectl delete -f ./ingress.yaml -n default
kubectl apply -f ingress/ingress-tls.yaml -n default


###############################################################################
# Setup actions-runner-controller
###############################################################################

### 1. Setup a GitHub App

# Permissions
- Actions: Read-only
- Contents: Read-only
- Metadata: Read-only
- Self-hosted runners: Read and Write

# Webhook events
- Workflow job
- Workflow dispatch
- Workflow run

# Fetch the installation id
gh token installations -i 135318 -k ~/.ghe/.is-actions-manager.pem

# Update the values.yaml file with the appropriate values

### 2. Install actions-runner-controller

# Add the actions-runner-controller Helm chart repository
helm repo add \
  actions-runner-controller \
  https://actions-runner-controller.github.io/actions-runner-controller

# Update your local Helm chart repository cache
helm repo update

# Install the actions-runner-controller Helm chart
helm upgrade --install \
  -f actions-runner-controller/values.yaml \
  --namespace actions-runner-system \
  --create-namespace \
  --wait \
  actions-runner-controller \
  actions-runner-controller/actions-runner-controller

# Verify the actions-runner-controller is running
kubectl get all --namespace actions-runner-system









###############################################################################
# BREAK
###############################################################################

az aks stop \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster

az aks start \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster

###############################################################################
# NUKE THE SETUP!
###############################################################################

az group delete --name GitHubActionsRunners

