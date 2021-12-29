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
az aks create \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --network-plugin azure \
  --enable-addons monitoring,ingress-appgw \
  --appgw-name K8sGitHubActionsAPGW \
  --appgw-subnet-cidr "10.2.0.0/16" \
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
# Application Gateway Configuration
###############################################################################

az network application-gateway show \
  --resource-group MC_GitHubActionsRunners_GitHubActionsRunnersK8sCluster_westeurope \
  --name K8sGitHubActionsAPGW \
  --output tsv

###############################################################################
# Setting up the Ingress Controller
# 
# Reference: https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip
###############################################################################

# We import the ingress-nginx controller images as well as cert manager 
# to our ACR so that we can use them in our AKS cluster.

# REPLACE VALUE OF REGISTRY NAME
# REGISTRY_NAME=<REGISTRY_NAME> # GitHubActionsOHACR
# SOURCE_REGISTRY=k8s.gcr.io
# CONTROLLER_IMAGE=ingress-nginx/controller
# CONTROLLER_TAG=v1.0.4
# PATCH_IMAGE=ingress-nginx/kube-webhook-certgen
# PATCH_TAG=v1.1.1
# DEFAULTBACKEND_IMAGE=defaultbackend-amd64
# DEFAULTBACKEND_TAG=1.5
# CERT_MANAGER_REGISTRY=quay.io
# CERT_MANAGER_TAG=v1.5.4
# CERT_MANAGER_IMAGE_CONTROLLER=jetstack/cert-manager-controller
# CERT_MANAGER_IMAGE_WEBHOOK=jetstack/cert-manager-webhook
# CERT_MANAGER_IMAGE_CAINJECTOR=jetstack/cert-manager-cainjector

# In addition to importing container images into your ACR, 
# you can also import Helm charts into your ACR.

# az acr import \
#   --name $REGISTRY_NAME \
#   --source $SOURCE_REGISTRY/$CONTROLLER_IMAGE:$CONTROLLER_TAG \
#   --image $CONTROLLER_IMAGE:$CONTROLLER_TAG

# az acr import \
#   --name $REGISTRY_NAME \
#   --source $SOURCE_REGISTRY/$PATCH_IMAGE:$PATCH_TAG \
#   --image $PATCH_IMAGE:$PATCH_TAG

# az acr import \
#   --name $REGISTRY_NAME \
#   --source $SOURCE_REGISTRY/$DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG \
#   --image $DEFAULTBACKEND_IMAGE:$DEFAULTBACKEND_TAG

az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_CONTROLLER:$CERT_MANAGER_TAG

az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_WEBHOOK:$CERT_MANAGER_TAG

az acr import \
  --name $REGISTRY_NAME \
  --source $CERT_MANAGER_REGISTRY/$CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG \
  --image $CERT_MANAGER_IMAGE_CAINJECTOR:$CERT_MANAGER_TAG

# Get the nodepool resource group name
# az aks show \
#   --resource-group GitHubActionsRunners \
#   --name GitHubActionsRunnersK8sCluster \
#   --query nodeResourceGroup \
#   -o tsv

# Create a static public IP address for the ingress controller
# az network public-ip create \
#   --resource-group MC_GitHubActionsRunners_GitHubActionsRunnersK8sCluster_westeurope \
#   --name GitHub-Actions-OH_Cluster_IP \
#   --sku Standard \
#   --allocation-method static \
#   --query publicIp.ipAddress \
#   --output tsv

# OUTPUT: 20.126.0.160

# Add the ingress-nginx repository
# helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# Set variable for ACR location to use for pulling images
# ACR_URL=githubactionsohacr.azurecr.io
# STATIC_IP=20.126.0.160
# DNS_LABEL=githubactionsohdemo

# Use Helm to deploy an NGINX ingress controller
# helm install nginx-ingress ingress-nginx/ingress-nginx \
#     --namespace ingress-basic --create-namespace \
#     --set controller.replicaCount=2 \
#     --set controller.nodeSelector."kubernetes\.io/os"=linux \
#     --set controller.image.registry=$ACR_URL \
#     --set controller.image.image=$CONTROLLER_IMAGE \
#     --set controller.image.tag=$CONTROLLER_TAG \
#     --set controller.image.digest="" \
#     --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
#     --set controller.admissionWebhooks.patch.image.registry=$ACR_URL \
#     --set controller.admissionWebhooks.patch.image.image=$PATCH_IMAGE \
#     --set controller.admissionWebhooks.patch.image.tag=$PATCH_TAG \
#     --set controller.admissionWebhooks.patch.image.digest="" \
#     --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
#     --set defaultBackend.image.registry=$ACR_URL \
#     --set defaultBackend.image.image=$DEFAULTBACKEND_IMAGE \
#     --set defaultBackend.image.tag=$DEFAULTBACKEND_TAG \
#     --set defaultBackend.image.digest="" \
#     --set controller.service.loadBalancerIP=$STATIC_IP \
#     --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$DNS_LABEL

# Verification
# kubectl get services \
#   --namespace ingress-basic \
#   --output wide

# az network public-ip list \
#   --resource-group MC_GitHubActionsRunners_GitHubActionsRunnersK8sCluster_westeurope \
#   --query "[?name=='GitHub-Actions-OH_Cluster_IP'].[dnsSettings.fqdn]" \
#   --output tsv

###############################################################################
# Create Cert Manager and setup TLS termination
###############################################################################

# Label the cert-manager namespace to disable resource validation
kubectl label namespace ingress-basic cert-manager.io/disable-validation=true

# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io

# Update your local Helm chart repository cache
helm repo update

# Install the cert-manager Helm chart
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
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
kubectl apply -f cluster-issuer.yaml --namespace cert-manager

# Deploy the sample app
kubectl apply -f ingress-test-app.yaml --namespace default

# Apply the configuration
# kubectl apply -f ingress-test-app.yaml --namespace ingress-basic
# kubectl apply -f ingress.yaml --namespace ingress-basic

# Test
curl -G https://githubactionsohdemo.westeurope.cloudapp.azure.com/test-ingress

###############################################################################
# actions-runner-controller deployment
###############################################################################

# stop aks cluster
az aks stop \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster


az network public-ip delete \
  --resource-group MC_GitHubActionsRunners_GitHubActionsRunnersK8sCluster_westeurope \
  --name GitHub-Actions-OH_Cluster_IP

# Delete everything

az group delete --name GitHubActionsRunners