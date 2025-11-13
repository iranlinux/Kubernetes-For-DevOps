#!/usr/bin/env bash
set -euo pipefail

# ------------------------ CONFIG ------------------------
APP_NAME="nodejs"
NAMESPACE="default"
ISTIO_NS="istio-system"
NODE_IP=$(hostname -I | awk '{print $1}')
NODEJS_NODE_PORT=30080
GRAFANA_NODE_PORT=31031

echo "🚀 Deploying Node.js + Istio + Grafana"
echo "Node IP: ${NODE_IP}"
echo "Node.js NodePort: ${NODEJS_NODE_PORT}"
echo "Grafana NodePort: ${GRAFANA_NODE_PORT}"
echo

# ------------------------ CLEANUP ------------------------
echo "[CLEANUP] Removing previous resources..."
kubectl delete deployment ${APP_NAME} --ignore-not-found
kubectl delete service ${APP_NAME} --ignore-not-found
kubectl delete gateway ${APP_NAME}-gateway --ignore-not-found
kubectl delete virtualservice ${APP_NAME} --ignore-not-found
kubectl delete destinationrule ${APP_NAME}-dr --ignore-not-found
kubectl delete deployment istio-grafana -n ${ISTIO_NS} --ignore-not-found
kubectl delete service istio-grafana -n ${ISTIO_NS} --ignore-not-found
kubectl delete gateway grafana-gateway -n ${ISTIO_NS} --ignore-not-found
kubectl delete virtualservice grafana-vs -n ${ISTIO_NS} --ignore-not-found
echo "[CLEANUP DONE]"
echo

# ------------------------ NODEJS DEPLOYMENT ------------------------
echo "[DEPLOY] Node.js app"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        version: v1
    spec:
      containers:
        - name: ${APP_NAME}
          image: iranlinux/istio-demo:v1
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: ${APP_NAME}
  ports:
    - port: 80
      targetPort: 8080
      nodePort: ${NODEJS_NODE_PORT}
EOF
echo "[OK] Node.js deployed"
echo

# ------------------------ ISTIO CONFIG ------------------------
echo "[DEPLOY] Istio Gateway & routing"
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${APP_NAME}-gateway
  namespace: ${NAMESPACE}
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
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ${APP_NAME}-dr
  namespace: ${NAMESPACE}
spec:
  host: ${APP_NAME}
  subsets:
    - name: v1
      labels:
        version: v1
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  hosts:
    - "*"
  gateways:
    - ${APP_NAME}-gateway
  http:
    - route:
        - destination:
            host: ${APP_NAME}
            port:
              number: 8080
EOF
echo "[OK] Istio routing applied"
echo

# ------------------------ GRAFANA DEPLOYMENT ------------------------
echo "[DEPLOY] Grafana (official upstream 12.2.1, password set on first login)"
cat <<EOF | kubectl apply -f -
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
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: admin
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
      port: 15031
      targetPort: 3000
      nodePort: ${GRAFANA_NODE_PORT}
EOF
echo "[OK] Grafana deployed"
echo

# ------------------------ ISTIO CONFIG FOR GRAFANA ------------------------
echo "[DEPLOY] Istio Gateway & routing for Grafana"
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
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
apiVersion: networking.istio.io/v1beta1
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
echo "[INFO] Waiting for pods to be Ready..."
for ns in ${NAMESPACE} ${ISTIO_NS}; do
  kubectl wait --for=condition=Ready pod --all -n $ns --timeout=180s || true
done

echo "[✅] Deployment complete!"
kubectl get pods -n ${NAMESPACE}
kubectl get pods -n ${ISTIO_NS}
echo
echo "[INFO] Node.js available at: http://${NODE_IP}:${NODEJS_NODE_PORT}"
echo "[INFO] Grafana available at: http://${NODE_IP}:${GRAFANA_NODE_PORT} (first login prompts for admin password)"
