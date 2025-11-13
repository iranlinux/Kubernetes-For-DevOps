#!/usr/bin/env bash
set -euo pipefail

# ------------------------ CONFIG ------------------------
APP_NAME="nodejs"
NAMESPACE="default"
ISTIO_NS="istio-system"
NODE_IP=$(hostname -I | awk '{print $1}')
NODEJS_NODE_PORT=30080
GRAFANA_NODE_PORT=31031

echo "🚀 Deploying Node.js Canary + Istio + Grafana"
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

# ------------------------ ISTIO GATEWAY & CANARY ROUTING ------------------------
echo "[DEPLOY] Istio Gateway & VirtualService for Canary"
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

# ------------------------ GRAFANA DEPLOYMENT ------------------------
echo "[DEPLOY] Grafana"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-grafana
  namespace: ${ISTIO_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:12.2.1
          ports:
            - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: istio-grafana
  namespace: ${ISTIO_NS}
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - name: http
      port: 3000
      targetPort: 3000
      nodePort: ${GRAFANA_NODE_PORT}
EOF
echo "[OK] Grafana deployed"
echo

# ------------------------ ISTIO ROUTING FOR GRAFANA ------------------------
echo "[DEPLOY] Istio Gateway & routing for Grafana"
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
          host: istio-grafana
          port:
            number: 3000
EOF
echo "[OK] Istio routing for Grafana applied"
echo

# ------------------------ WAIT FOR PODS ------------------------
echo "[INFO] Waiting for pods to be Ready (max 30s per pod)..."
for ns in ${NAMESPACE} ${ISTIO_NS}; do
  for pod in $(kubectl get pods -n $ns -o name); do
    kubectl wait --for=condition=Ready $pod -n $ns --timeout=30s || true
  done
done

echo "[✅] Deployment complete!"
echo "Node.js available at: http://${NODE_IP}:${NODEJS_NODE_PORT} (50/50 blue/green)"
echo "Grafana available at: http://${NODE_IP}:${GRAFANA_NODE_PORT} (set admin password on first login)"
