# React App → Docker → ACR → Azure App Service

### Secure Deployment Guide using System Managed Identity (SMI)

---

## Prerequisites

- Azure CLI installed & logged in (`az login`)
- Docker installed locally
- Node.js installed

---

## Variables

```bash
RESOURCE_GROUP="rg-eus2-appservice-dev-001"
APP_NAME="my-app-azure-demo-webapp"
APP_SERVICE_PLAN="my-app-azure-demo-plan"
ACR_NAME="myreactregistry"
IMAGE_NAME="my-app-azure-demo"
TAG="latest"
ACR_URL="myreactregistry.azurecr.io"
LOCATION="eastus2"
```

---

## Step 1 — Create Resource Group & ACR

```bash
# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create ACR instance (admin disabled — SMI handles auth)
az acr create \
  --name $ACR_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic \
  --admin-enabled false

# Verify ACR is created
az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --output table
```

---

## Step 2 — Create the Dockerfile

Create a `Dockerfile` in the root of your React project:

```dockerfile
# ---- Build Stage ----
FROM --platform=linux/amd64 node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Production Stage ----
FROM --platform=linux/amd64 nginx:alpine
COPY --from=builder /app /tmp/app
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
```

> The `--platform=linux/amd64` flags ensure the image is always built for Azure's architecture, even when building from a Mac with Apple Silicon (M1/M2/M3).

Create an `nginx.conf` file alongside the Dockerfile:

```nginx
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Handle React Router (SPA routing)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

Create a `.dockerignore` file:

```
node_modules
build
dist
.git
.env
```

---

## Step 3 — Build & Push Image to ACR

Choose **one** of the following options:

### Option A — Linux / Fedora (local build)

```bash
az acr login --name $ACR_NAME
docker build -t $ACR_URL/$IMAGE_NAME:$TAG .
docker push $ACR_URL/$IMAGE_NAME:$TAG
```

### Option B — Mac Apple Silicon (local build, forced amd64)

```bash
az acr login --name $ACR_NAME
docker build --platform linux/amd64 -t $ACR_URL/$IMAGE_NAME:$TAG .
docker push $ACR_URL/$IMAGE_NAME:$TAG
```

### Option C — ACR Tasks (build in the cloud — works from any machine ✅ recommended)

```bash
az acr build \
  --registry $ACR_NAME \
  --image $IMAGE_NAME:$TAG \
  --platform linux/amd64 \
  .
```

> No local Docker build needed. Source is sent to Azure, built there, and stored directly in ACR.

### Verify Architecture (optional — for local builds only)

```bash
docker inspect $ACR_URL/$IMAGE_NAME:$TAG | grep Architecture
# Should output "amd64" — if it says "arm64" the container will fail in Azure
```

---

## Step 4 — Create App Service Plan & Web App

```bash
# Create App Service Plan (Linux required for containers)
az appservice plan create \
  --name $APP_SERVICE_PLAN \
  --resource-group $RESOURCE_GROUP \
  --is-linux \
  --sku B1

# Create the Web App
az webapp create \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --plan $APP_SERVICE_PLAN \
  --deployment-container-image-name $ACR_URL/$IMAGE_NAME:$TAG
```

---

## Step 5 — Enable System Managed Identity (SMI)

```bash
# Enable SMI on the App Service
az webapp identity assign \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP

# Capture the principal ID
PRINCIPAL_ID=$(az webapp identity show \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId \
  --output tsv)
echo "Principal ID: $PRINCIPAL_ID"
```

---

## Step 6 — Grant SMI Access to ACR

```bash
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
```

---

## Step 7 — Configure App Service to Use SMI for ACR

```bash
# Tell App Service to use managed identity for ACR auth (no passwords!)
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
```

> Do **not** pass `--container-registry-user` or `--container-registry-password` — SMI handles authentication without credentials.

---

## Step 8 — Restart & Verify

```bash
# Restart the app
az webapp restart --name $APP_NAME --resource-group $RESOURCE_GROUP

# Stream live logs to confirm startup
az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP

# Open in browser
az webapp browse --name $APP_NAME --resource-group $RESOURCE_GROUP
```

---

## Teardown

To delete everything and start fresh:

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

> `--no-wait` deletes in the background. Wait a few minutes before rerunning the setup.

---

## Architecture Overview

```
React App
   │
   ▼  docker build + push (or az acr build)
Azure Container Registry (ACR)
   │  admin-enabled: false
   ▼  pulls image via SMI token (no passwords)
Azure App Service (Web App)
   └── System Managed Identity → AcrPull role → ACR
```

---

## Common Issues

| Symptom                         | Cause                               | Fix                                                                  |
| ------------------------------- | ----------------------------------- | -------------------------------------------------------------------- |
| Container exits with code 255   | Wrong architecture (arm64 vs amd64) | Use `--platform linux/amd64` or ACR Tasks                            |
| `No build or dist folder found` | Build output path mismatch          | CRA outputs `build/`, Vite outputs `dist/` — Dockerfile handles both |
| Image pull fails                | SMI not assigned AcrPull role       | Re-run Step 6                                                        |
| App loads but routes 404        | Missing SPA fallback in nginx       | Ensure `try_files $uri $uri/ /index.html` is in nginx.conf           |
