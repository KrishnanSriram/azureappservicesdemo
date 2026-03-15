# ---- Build Stage ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Production Stage ----
FROM nginx:alpine

# Copy whichever output folder exists (build = CRA, dist = Vite)
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