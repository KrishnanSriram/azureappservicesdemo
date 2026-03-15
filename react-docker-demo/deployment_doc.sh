RESOURCE_GROUP="rg-eus2-appservice-dev-001"
APP_NAME="my-app-azure-demo-webapp"
APP_SERVICE_PLAN="my-app-azure-demo-plan"
ACR_NAME="myreactregistry"
IMAGE_NAME="my-app-azure-demo"
TAG="latest"
ACR_URL="myreactregistry.azurecr.io"
LOCATION=""

# create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION


# create ACR instance
az acr create \
  --name $ACR_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic \
  --admin-enabled false

# verify ACR is created
az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --output table


# Log in to ACR
az acr login --name $ACR_NAME

# Build the image
docker build -t $ACR_URL/$IMAGE_NAME:$TAG .

# Push to ACR
docker push $ACR_URL/$IMAGE_NAME:$TAG

# Create App Service Plan (Linux required for containers)
az appservice plan create \
  --name $APP_SERVICE_PLAN \
  --resource-group $RESOURCE_GROUP \
  --is-linux \
  --sku B1

# Create the Web App with the container image
az webapp create \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --plan $APP_SERVICE_PLAN \
  --deployment-container-image-name $ACR_URL/$IMAGE_NAME:$TAG

# Enable SMI on the App Service
az webapp identity assign \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROU

# Capture the principal ID of the managed identity
PRINCIPAL_ID=$(az webapp identity show \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId \
  --output tsv)

echo "Principal ID: $PRINCIPAL_ID"

# Get the ACR resource ID
ACR_RESOURCE_ID=$(az acr show \
  --name $ACR_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id \
  --output tsv)

echo "ACR Resource ID: $ACR_RESOURCE_ID"

# Assign AcrPull role to the managed identity
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope $ACR_RESOURCE_ID

# Tell App Service to use managed identity for ACR auth
az webapp config set \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --generic-configurations '{"acrUseManagedIdentityCreds": true}'

# Point App Service to your container image
az webapp config container set \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --container-image-name $ACR_URL/$IMAGE_NAME:$TAG \
  --container-registry-url https://$ACR_URL

# Set the WEBSITES_PORT app setting to 80
az webapp config appsettings set \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings WEBSITES_PORT=80

# Restart the app
az webapp restart --name $APP_NAME --resource-group $RESOURCE_GROUP

# View live logs to confirm startup
az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP



# For Mac, please make sure you have these setup for docker build
# When you docker build on a Mac with Apple Silicon, Docker builds an arm64 image by default. That image is then pushed to ACR and Azure tries to run it on amd64 — causing the container to exit with code 255 immediately, which is exactly what your logs showed!

# The Fix — Build for the Right Platform
# Add --platform linux/amd64 to your build command:

docker build --platform linux/amd64 \
  -t $ACR_URL/$IMAGE_NAME:$TAG .

# Or we can have it built into dockerfile itself

# ---- Build Stage ----
FROM --platform=linux/amd64 node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Production Stage ----
FROM --platform=linux/amd64 nginx:alpine
RUN if [ -d "/tmp/app/build" ]; then \
      cp -r /tmp/app/build/. /usr/share/nginx/html; \
    elif [ -d "/tmp/app/dist" ]; then \
      cp -r /tmp/app/dist/. /usr/share/nginx/html; \
    else \
      echo "ERROR: No build or dist folder found!" && exit 1; \
    fi && rm -rf /tmp/app
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]


# We can build the same from ACR tasks too. No local Docker build needed at all — your source is sent to Azure, built there, and stored directly in ACR. This also works consistently from any machine (Mac, Fedora, Windows).
az acr build \
  --registry $ACR_NAME \
  --image $IMAGE_NAME:$TAG \
  --platform linux/amd64 \


# Check what arch your last built image was
docker inspect $ACR_URL/$IMAGE_NAME:$TAG | grep Architecture
# Should say "amd64" for Azure compatibility
# If it says "arm64" — that's your culprit