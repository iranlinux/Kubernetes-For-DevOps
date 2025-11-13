#!/usr/bin/env bash
set -euo pipefail

# ------------------------ CONFIG ------------------------
APP_NAME="nodejs"
NAMESPACE="default"
ISTIO_NS="istio-system"
NODE_IP=$(hostname -I | awk '{print $1}')
NODEJS_NODE_PORT=30080
GRAFANA_NODE_PORT=31031
ISTIO_ADDONS_BASE="https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons"

echo "🚀 Deploying Node.js Canary + Istio + Grafana (with dashboards)"
echo "Node IP: ${NODE_IP}"
echo "Node.js NodePort: ${NODEJS_NODE_PORT}"
echo "Grafana NodePort: ${GRAFANA_NODE_PORT}"
echo

# ------------------------ CLEANUP ------------------------
echo "[CLEANUP] Removing previous resources..."
kubectl delete deployment nodejs-v1 nodejs-v2 --ignore-not-found
kubectl delete service nodejs --ignore-not-found
kubectl delete gateway nodejs-gateway --ignore-not-found
kubectl delete virtualservice nodejs --ignore-not-found
kubectl delete destinationrule nodejs --ignore-not-found
kubectl delete deployment istio-grafana -n ${ISTIO_NS} --ignore-not-found
kubectl delete service istio-grafana -n ${ISTIO_NS} --ignore-not-found
kubectl delete deployment prometheus -n ${ISTIO_NS} --ignore-not-found
kubectl delete service prometheus -n ${ISTIO_NS} --ignore-not-found
kubectl delete gateway grafana-gateway -n ${ISTIO_NS} --ignore-not-found
kubectl delete virtualservice grafana-vs -n ${ISTIO_NS} --ignore-not-found
echo "[CLEANUP DONE]"
echo

# ------------------------ NODEJS CANARY DEPLOYMENT ------------------------
echo "[DEPLOY] Node.js Canary Deployments"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nodejs
  labels: 
    app: nodejs
spec:
  type: NodePort
  selector:
    app: nodejs
  ports:
  - name: http
    port: 8080
    nodePort: ${NODEJS_NODE_PORT}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-v1
  labels:
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nodejs
      version: v1
  template:
    metadata:
      labels:
        app: nodejs
        version: v1
    spec:
      containers:
      - name: nodejs
        image: iranlinux/istio-demo:v1
        ports:
        - containerPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-v2
  labels:
    version: v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nodejs
      version: v2
  template:
    metadata:
      labels:
        app: nodejs
        version: v2
    spec:
      containers:
      - name: nodejs
        image: iranlinux/istio-canary-demo:v1
        ports:
        - containerPort: 8080
EOF
echo "[OK] Node.js Canary deployed"
echo

# ------------------------ ISTIO CANARY ROUTING ------------------------
echo "[DEPLOY] Istio Gateway & VirtualService for Node.js"
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: nodejs-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: nodejs
spec:
  hosts:
  - "*"
  gateways:
  - nodejs-gateway
  http:
  - route:
    - destination:
        host: nodejs
        subset: v1
      weight: 50
    - destination:
        host: nodejs
        subset: v2
      weight: 50
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: nodejs
spec:
  host: nodejs
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
EOF
echo "[OK] Istio routing applied"
echo

# ------------------------ PROMETHEUS & GRAFANA ------------------------
echo "[DEPLOY] Istio Prometheus & Grafana Addons (with dashboards)"
kubectl apply -f "${ISTIO_ADDONS_BASE}/prometheus.yaml"
kubectl apply -f "${ISTIO_ADDONS_BASE}/grafana.yaml"

# Patch Grafana service to NodePort
kubectl -n ${ISTIO_NS} patch svc grafana --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
  {\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${GRAFANA_NODE_PORT}}
]" || true

# ------------------------ ISTIO GRAFANA GATEWAY ------------------------
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: grafana-gateway
  namespace: ${ISTIO_NS}
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: ${GRAFANA_NODE_PORT}
      name: http-grafana
      protocol: HTTP
    hosts:
      - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: grafana-vs
  namespace: ${ISTIO_NS}
spec:
  hosts:
  - "*"
  gateways:
  - grafana-gateway
  http:
  - route:
      - destination:
          host: grafana
          port:
            number: 3000
EOF
echo "[OK] Istio routing for Grafana applied"
echo

# ------------------------ WAIT FOR PODS ------------------------
echo "[INFO] Waiting for pods to be Ready (max 60s per pod)..."
for ns in ${NAMESPACE} ${ISTIO_NS}; do
  for pod in $(kubectl get pods -n $ns -o name); do
    kubectl wait --for=condition=Ready $pod -n $ns --timeout=60s || true
  done
done

# ------------------------ FINAL STATUS ------------------------
echo "[✅] Deployment complete!"
echo "Node.js available at: http://${NODE_IP}:${NODEJS_NODE_PORT} (50/50 blue/green)"
echo "Grafana available at: http://${NODE_IP}:${GRAFANA_NODE_PORT} (Istio dashboards auto-loaded)"

