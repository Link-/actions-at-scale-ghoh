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
# 
  # The application gateway subnet can contain only application gateways. 
  # No other resources are allowed. You can either create a new subnet for 
  # Application Gateway or use an existing one.
az aks create \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --network-plugin azure \
  --enable-addons monitoring,ingress-appgw \
  --appgw-name K8sGitHubActionsAPGW \
  --appgw-subnet-cidr "10.240.2.0/24" \
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
az acr show \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsOHACR \
  --query loginServer \
  --output tsv

# OUTPUT: githubactionsohacr.azurecr.io

# 2. Do the check
  # REPLACE VALUE OF LOGIN_SERVER WITH YOUR ACR FQDN
az aks check-acr \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --acr <LOGIN_SERVER>

az aks check-acr \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --acr githubactionsohacr.azurecr.io

###############################################################################
# Create Cert Manager and setup TLS termination
###############################################################################

ACR_URL=githubactionsohacr.azurecr.io
REGISTRY_NAME=GitHubActionsOHACR
CERT_MANAGER_REGISTRY=quay.io
CERT_MANAGER_TAG=v1.5.4
CERT_MANAGER_IMAGE_CONTROLLER=jetstack/cert-manager-controller
CERT_MANAGER_IMAGE_WEBHOOK=jetstack/cert-manager-webhook
CERT_MANAGER_IMAGE_CAINJECTOR=jetstack/cert-manager-cainjector

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
kubectl create namespace github-actions-runners

# Label the cert-manager namespace to disable resource validation
kubectl label namespace github-actions-runners cert-manager.io/disable-validation=true

# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io

# Update your local Helm chart repository cache
helm repo update

# Install the cert-manager Helm chart
helm install cert-manager jetstack/cert-manager \
  --namespace github-actions-runners \
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
# Apply the configuration;
kubectl apply -f cluster-issuer.yaml --namespace github-actions-runners

# Deploy the sample app
kubectl apply -f test-app.yaml --namespace github-actions-runners
kubectl apply -f ingress.yaml --namespace github-actions-runners

# Create dns name for the front-end public ip
# manually

# Test
curl -G http://githubactionsapgw.westeurope.cloudapp.azure.com

az group delete --name GitHubActionsRunners