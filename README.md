# Adopting GitHub Actions at scale in the Enterprise

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

> GitHub Office Hours: Adopting GitHub Actions at scale in the Enterprise

This repository contains the scripts and configuration files for the GitHub Actions at scale in the Enterprise office hours video series.

## Agenda

*All episodes were followed by a live Q&A.*

**Episode 1:**

<a href="https://www.youtube.com/watch?v=OhNroaLxMzc" target="_blank"><img src="./images/episode_1.png" width="70%" /></a>

- Setup and configure AKS
- Deploy and attach an Application Gateway as our Ingress Controller

**Episode 2:**

<a href="https://www.youtube.com/watch?v=8Lw8CjEV-FA" target="_blank"><img src="./images/episode_2.png" width="70%" /></a>

- Configure cert-manager for TLS termination
- Create a GitHub App
- Install & configure actions-runner-controller
- Demonstrate auto-scaling

**Episode 3:**

<a href="https://www.youtube.com/watch?v=9kE8FsQSnDU" target="_blank"><img src="./images/episode_3.png" width="70%" /></a>

- Configure our Web Application Firewall (WAF)
- Enable and use Docker in Docker
- Create a custom self-hosted runner image
- Install multiple actions-runner-controllers for different namespaces

## Reference Architecture

![Reference architecture diagram](./images/GitHub-Actions_shr-arch-ref_v03BD-Azure.png)

## Pre-Requisites
- Azure Subscription with at least [Contributor](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#contributor) + [User Access Administrator](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#user-access-administrator) built-in roles. You will be performing role assignments when using the Azure Application Gateway with AKS and when integrating Azure Container Registry with AKS. If you need an Azure subscription, [you can register for a free account with $200 credit](https://azure.microsoft.com/en-us/free/) or if you have [Visual Studio Enterprise](https://azure.microsoft.com/en-us/pricing/member-offers/credit-for-visual-studio-subscribers/) then you can redeem a monthly credit.

## Folder Structure

```text
.
├── LICENSE
├── README.md
├── actions-runner-controller
│   ├── alt-namespace
│   │   ├── autoscale_webhook.yaml
│   │   └── values.yaml.example
│   ├── autoscale_webhook.yaml
│   ├── dind_deployment.yaml
│   ├── go-runners-autoscale_webhook.yaml
│   ├── multi_namespace_values.yaml
│   └── values.yaml.example
├── apps
│   └── test-app.yaml
├── cert-manager
│   ├── cluster-issuer-prod.yaml
│   └── cluster-issuer-staging.yaml
├── custom-runners
│   └── Dockerfile
├── ingress
│   ├── altns-ingress.yaml
│   ├── ingress-tls-runners.yaml
│   ├── ingress-tls.yaml
│   ├── ingress.yaml
│   └── multi-namespaces-ingress.yaml
└── sample-workflows
    ├── custom-runner.yaml
    ├── docker_job.yaml
    ├── matrix_jobs.yaml
    ├── multi_job.yaml
    └── single_job.yml
```

- `actions-runner-controller/`: contains the actions-runner-controller configuration and helm chart values file for the default namespace
- `actions-runner-controller/alt-namespace/`: contains the actions-runner-controller configuration and helm chart values file for the alternate namespace
- `apps/`: contains the sample applications used for sanity checks
- `cert-manager/`: contains the cert-manager configuration
- `custom-runners/`: contains the Dockerfile of a custom runner image
- `ingress/`: contains the ingress controller configuration
- `sample-workflows/`: contains the sample workflows used for sanity checks

## Setup

:warning: *All the below assumes you are running `Bash`.*

### Install az cli

```bash
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
```

### Install kubectl (latest stable version)

```bash
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
```

### Install Helm

```bash

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

```

### Setup AKS via Azure CLI

```bash
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
# (OPTIONAL)
az aks scale \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --node-count 1

# Check progress
watch -n 3 kubectl get nodes

```

### Create ACR

```bash
###############################################################################
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

# 2. Do the check
  # REPLACE VALUE OF LOGIN_SERVER WITH YOUR ACR FQDN
az aks check-acr \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster \
  --acr $ACR_URL
```

### Enable application gateway for our AKS cluster

```bash
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
```

### Create and deploy a simple testing app

```bash
kubectl apply -f apps/test-app.yaml --namespace default
kubectl apply -f ingress/ingress.yaml --namespace default

# !!! IMPORTANT !!!
#
# Add a DNS alias for the public ip manually before proceeding
#
# !!! IMPORTANT !!!

# Fetch the DNS alias
APGW_FQDN=$(az network public-ip show \
  --resource-group GitHubActionsRunners \
  --name APGWPublicIp \
  --query dnsSettings.fqdn \
  --output tsv) \
  && echo $APGW_FQDN

curl -G https://${APGW_FQDN}

```

### Create Cert Manager and setup TLS termination

```bash
ACR_URL=$(az acr show \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsOHACR \
  --query loginServer \
  --output tsv) \
  && echo $ACR_URL
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
kubectl apply -f ingress/ingress-tls.yaml -n default
```

### Setup actions-runner-controller

```bash
# !!! IMPORTANT !!!
#
# Setup a GitHub App manually before proceeding
#
# # Permissions 
# - Actions: Read-only
# - Contents: Read-only
# - Metadata: Read-only
# - Self-hosted runners: Read and Write
# 
# # Webhook events
# - Workflow job
# - Workflow dispatch
# - Workflow run
#
# !!! IMPORTANT !!!

# Fetch the installation id
# This requires the setup of:
# - https://cli.github.com/
# - https://github.com/link-/gh-token
gh token installations -i <APPLICATION_ID> -k <PATH_TO_PKEY>

# !!! IMPORTANT !!!
#
# Update the values.yaml file with the appropriate values
#
# !!! IMPORTANT !!!

# Install actions-runner-controller
# Add the actions-runner-controller Helm chart repository
helm repo add \
  actions-runner-controller \
  https://actions-runner-controller.github.io/actions-runner-controller

# Update your local Helm chart repository cache
helm repo update

# Install the actions-runner-controller Helm chart
helm upgrade --install \
  -f actions-runner-controller/values.yaml \
  --namespace default \
  --create-namespace \
  --wait \
  actions-runner-controller \
  actions-runner-controller/actions-runner-controller

#
# Update the ingress/ingress-tls-runners.yaml with the appropriate 
# hostname and the actions-runner-controller service name
#

# Update the ingress controller
kubectl apply -f ingress/ingress-tls-runners.yaml --namespace default

# Create a new runner deployment
kubectl apply -f actions-runner-controller/autoscale_webhook.yaml --namespace default

# Execute some sample runs
```

### Start / Stop AKS

```bash
# Stop AKS
az aks stop \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster

# Stop application gateway
az network application-gateway stop \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersAPGW

# Start AKS
az aks start \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersK8sCluster

# Start application gateway
az network application-gateway start \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsRunnersAPGW

# !!! IMPORTANT !!!
#
# Remember, when you start the application gateway, you need to 
# reapply the Ingress configuration, otherwise you'll get 502 errors
#
# !!! IMPORTANT !!!
```

## Advanced Configuration

### Configuring our Web Application Firewall (WAF)

Described in the video

### Enable and use Docker in Docker

This is as simple as updating the runner deployment with these properties:

```yaml
spec:
  replicas: 0
  template:
    spec:
      organization: Inner-Sanctum
      labels:
        - azure
        - docker
      image: summerwind/actions-runner-dind
      dockerdWithinRunnerContainer: true
```

Then create the new DinD enabled deployment:

```bash
kubectl apply -f actions-runner-controller/dind_deployment.yaml --namespace default
```

### Creating custom self-hosted runner images

Start by editing `custom-runners/Dockerfile` to include the dependencies you need in your runners:

```Dockerfile
FROM summerwind/actions-runner:latest

# This will be a good place to add your CA bundle if you're using
# a custom CA.

# If you have proxy configurations, you can also add them here

# Change the work dir to tmp because these are disposable files
WORKDIR /tmp

# EXAMPLE
# Install a stable version of Go
# and verify checksum of the tarball
# 
# Go releases URL: https://go.dev/dl/
#
RUN curl -OL https://go.dev/dl/go1.17.6.linux-amd64.tar.gz && \
    echo "231654bbf2dab3d86c1619ce799e77b03d96f9b50770297c8f4dff8836fc8ca2  go1.17.6.linux-amd64.tar.gz" | sha256sum -c - && \
    sudo tar -C /usr/local -xvf go1.17.6.linux-amd64.tar.gz && \
    export PATH=$PATH:/usr/local/go/bin && \
    go version
```

Then we need to tag and push the image to our Azure Container Registry:

```bash
# Fetch ACR's FQDN
ACR_URL=$(az acr show \
  --resource-group GitHubActionsRunners \
  --name GitHubActionsOHACR \
  --query loginServer \
  --output tsv) \
  && echo $ACR_URL

# Login to ACR
az acr login --name GitHubActionsOHACR

# Verify we're logged in
cat ~/.docker/config.json | jq ".auths"

# You need to be in the root directory of this repository for this to work
# Build and tag the new runner image
docker build --tag $ACR_URL/runner-image:go1.17.6 --file $(pwd)/custom-runners/Dockerfile .

# List the image and verify the tag
docker image list

# Push the image to ACR
docker push $ACR_URL/runner-image:go1.17.6

# !!! IMPORTANT !!!
# 
# Edit the actions-runner-controller/go-runners-autoscale_webhook.yaml to point
# to the correct container image and tag
#
# !!! IMPORTANT !!!

# Now we need to create a new deployment for the custom runners:
kubectl apply -f actions-runner-controller/go-runners-autoscale_webhook.yaml --namespace default

# Run a test with the custom-runner.yaml workflow
```

### Setup multiple actions-runner-controllers in different namespaces

```bash
# Create the new namespace
kubectl create namespace altns

# !!! IMPORTANT !!!
#
# In order to configure multiple actions-runner-controllers in different
# namesapces we have to introduce changes to these keys in the values.yaml
# Replace "altns" with the name of your namespace
#
# - nameOverride: "altns"
# - fullnameOverride: "altns-actions-runner-controller"
# - scope.singleNamespace: true
# - scope.watchNamespace: "altns"
# - githubWebhookServer.nameOverride: "altns"
# - githubWebhookServer.fullnameOverride: "altns-github-webhook-server"
#
# !!! IMPORTANT !!!

# Update the previous installation of actions-runner-controller in the
# default namespace to support multi-namespace installations
helm upgrade --install \
  -f actions-runner-controller/multi_namespace_values.yaml \
  --namespace default \
  --wait \
  actions-runner-controller \
  actions-runner-controller/actions-runner-controller

# Install a new actions-runner-controller in the altns namespace
helm upgrade --install \
  -f actions-runner-controller/alt-namespace/values.yaml \
  --namespace altns \
  --wait \
  actions-runner-controller \
  actions-runner-controller/actions-runner-controller

# !!! IMPORTANT !!!
#
# Update enterprise and organization settings to allow the "Default" group 
# to be used by all organizations and repositories
#
# !!! IMPORTANT !!!

# Deploy new ingress configurations
kubectl apply -f ingress/multi-namespaces-ingress.yaml --namespace default
# altns ingress configuration
kubectl apply -f ingress/altns-ingress.yaml --namespace altns

# !!! IMPORTANT !!!
#
# Configure the Enterprise webhooks manually
# https://github.com/enterprises/:ENTERPRISE_NAME/settings/hooks
#
# !!! IMPORTANT !!!

# Deploy actions-runner-controllers
kubectl apply -f actions-runner-controller/alt-namespace/autoscale_webhook.yaml
```

### NUKE THE SETUP

This will destroy the resource group and all the services associated with it (i.e. everything created above).

```bash
az group delete --name GitHubActionsRunners
```

## References

- **Adopting GitHub Actions for Enterprise Guide:**
  - GitHub Enterprise Cloud: <https://docs.github.com/en/enterprise-cloud@latest/admin/guides>
  - GitHub Enterprise Server: <https://docs.github.com/en/enterprise-server@latest/admin/guides>
- **Azure AKS docs:** <https://docs.microsoft.com/en-us/azure/aks/>
- **Azure Application Gateway docs:** <https://docs.microsoft.com/en-us/azure/application-gateway/>
- **Azure CLI docs:** <https://docs.microsoft.com/en-us/cli/azure/>
