#!/usr/bin/env bash
set -euo pipefail

# Config
GRAFANA_NODE_PORT=31031           # valid NodePort (30000-32767)
NODE_IP=$(hostname -I | awk '{print $1}')
NAMESPACES=("default" "istio-system")
ISTIO_ADDONS_BASE="https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons"

echo "[INFO] NODE_IP=${NODE_IP}"
echo "[INFO] GRAFANA_NODE_PORT=${GRAFANA_NODE_PORT}"
echo

# 0) Basic safety checks
if [[ $GRAFANA_NODE_PORT -lt 30000 || $GRAFANA_NODE_PORT -gt 32767 ]]; then
  echo "ERROR: GRAFANA_NODE_PORT must be in 30000-32767 range"; exit 1
fi

# 1) Cleanup previous resources (safe, ignore-not-found)
echo "[CLEANUP] Deleting previous Node.js / Grafana / Prometheus / Istio resources..."
kubectl delete deployment nodejs --ignore-not-found
kubectl delete service nodejs --ignore-not-found
kubectl delete deployment load-gen --ignore-not-found
kubectl delete deployment prometheus -n istio-system --ignore-not-found
kubectl delete service prometheus -n istio-system --ignore-not-found
kubectl delete deployment grafana -n istio-system --ignore-not-found
kubectl delete deployment istio-grafana -n istio-system --ignore-not-found
kubectl delete service istio-grafana -n istio-system --ignore-not-found
kubectl delete gateway nodejs-gateway --ignore-not-found
kubectl delete virtualservice nodejs --ignore-not-found
kubectl delete gateway grafana-gateway -n istio-system --ignore-not-found
kubectl delete virtualservice grafana-vs -n istio-system --ignore-not-found

# Wait a little for resources to actually terminate
sleep 3

# 2) Deploy Node.js test app (simple echo)
echo "[DEPLOY] Creating Node.js service and deployment..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nodejs
  labels:
    app: nodejs
spec:
  selector:
    app: nodejs
  ports:
    - name: http
      port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs
  labels:
    app: nodejs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nodejs
  template:
    metadata:
      labels:
        app: nodejs
    spec:
      containers:
        - name: nodejs
          # reliable small echo server
          image: hashicorp/http-echo:0.2.3
          args:
            - "-text=hello from nodejs"
          ports:
            - containerPort: 8080
EOF

# 3) Ensure namespace default has Istio injection label (so sidecars get injected)
echo "[INFO] Enabling istio-injection label on 'default' namespace..."
kubectl label namespace default istio-injection=enabled --overwrite || true
kubectl get namespace default -o jsonpath='{.metadata.labels.istio-injection}' || true
echo

# 4) Deploy Istio Prometheus addon (official sample)
echo "[DEPLOY] Applying Istio Prometheus addon manifest..."
kubectl apply -f "${ISTIO_ADDONS_BASE}/prometheus.yaml"

# 5) Deploy Istio Grafana addon manifest (this provides dashboards)
echo "[DEPLOY] Applying Istio Grafana addon manifest..."
kubectl apply -f "${ISTIO_ADDONS_BASE}/grafana.yaml"

# 6) Wait for Prometheus rollout in istio-system
echo "[WAIT] Waiting for Prometheus to be Ready..."
kubectl -n istio-system rollout status deployment/prometheus --timeout=240s || true

# 7) Patch / create a NodePort service that points to Grafana deployment created by the addon
#    The Istio grafana addon creates a service 'grafana' in istio-system. We'll create a NodePort wrapper
echo "[PATCH] Exposing Grafana on NodePort ${GRAFANA_NODE_PORT}..."

# if a service 'grafana' exists, patch it to NodePort and set nodePort (if allowed).
if kubectl -n istio-system get svc grafana >/dev/null 2>&1; then
  # prefer patch if possible
  echo "[PATCH] Patching existing 'grafana' service to NodePort (if necessary)..."
  kubectl -n istio-system patch svc grafana --type='json' -p="[{
    \"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"
  }]" || true

  # set nodePort for the grafana service port (port may be 3000)
  # find service port index and patch nodePort
  GRAF_PORT_IDX=$(kubectl -n istio-system get svc grafana -o json | jq -r '.spec.ports | to_entries[] | select(.value.port==3000) | .key' 2>/dev/null || echo "")
  if [[ -n "$GRAF_PORT_IDX" ]]; then
    # build JSON patch to add nodePort
    kubectl -n istio-system patch svc grafana --type='json' -p="[{
      \"op\":\"add\",\"path\":\"/spec/ports/${GRAF_PORT_IDX}/nodePort\",\"value\":${GRAFANA_NODE_PORT}
    }]" || true
  else
    # fallback: create a new NodePort service named istio-grafana
    echo "[INFO] Creating istio-grafana NodePort service (fallback)..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-grafana
  namespace: istio-system
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: ${GRAFANA_NODE_PORT}
EOF
  fi
else
  # Create NodePort service pointing to grafana selector
  echo "[CREATE] Creating istio-grafana NodePort service..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-grafana
  namespace: istio-system
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: ${GRAFANA_NODE_PORT}
EOF
fi

# 8) Create Istio Gateway and VirtualService for Node.js and Grafana to allow access via ingressgateway
echo "[APPLY] Creating Gateway and VirtualService resources..."

kubectl apply -f - <<EOF
# Node.js Gateway & VirtualService (default namespace)
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: nodejs-gateway
  namespace: default
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
kind: VirtualService
metadata:
  name: nodejs
  namespace: default
spec:
  hosts:
    - "*"
  gateways:
    - nodejs-gateway
  http:
    - match:
        - uri:
            prefix: "/"
      route:
        - destination:
            host: nodejs
            port:
              number: 8080

# Grafana Gateway & VirtualService (istio-system)
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: grafana-gateway
  namespace: istio-system
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
  namespace: istio-system
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

# 9) Deploy a simple load generator to create traffic so Istio/Prometheus collect metrics
echo "[DEPLOY] Deploying a lightweight load generator (continually curls / )..."
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-gen
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: load-gen
  template:
    metadata:
      labels:
        app: load-gen
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.4.0
          command: ["/bin/sh","-c"]
          # loop forever and hit the nodejs service through the mesh (via cluster IP)
          args:
            - "while true; do sleep 2; curl -sS http://nodejs:8080 >/dev/null; done"
EOF

# 10) Wait for deployments (use rollout status)
echo "[WAIT] Waiting for nodejs rollout..."
kubectl -n default rollout status deployment/nodejs --timeout=180s || echo "[WARN] nodejs rollout timed out or failed"

echo "[WAIT] Waiting for grafana/prometheus rollouts in istio-system..."
kubectl -n istio-system rollout status deployment/prometheus --timeout=180s || echo "[WARN] prometheus rollout timed out or failed"
# Wait for grafana deployment (addon may be named grafana)
if kubectl -n istio-system get deployment grafana >/dev/null 2>&1; then
  kubectl -n istio-system rollout status deployment/grafana --timeout=180s || echo "[WARN] grafana rollout timed out or failed"
fi
if kubectl -n istio-system get deployment istio-grafana >/dev/null 2>&1; then
  kubectl -n istio-system rollout status deployment/istio-grafana --timeout=180s || echo "[WARN] istio-grafana rollout timed out or failed"
fi

# 11) Final status
echo
echo "[RESULTS] Pods in default namespace:"
kubectl get pods -n default -o wide
echo
echo "[RESULTS] Pods in istio-system namespace:"
kubectl get pods -n istio-system -o wide
echo
echo "[RESULTS] Services in istio-system:"
kubectl get svc -n istio-system

echo
echo "✅ Grafana (NodePort) should be reachable at:"
echo "   http://${NODE_IP}:${GRAFANA_NODE_PORT}  (or via ingressgateway NodePort if you prefer)"
echo
echo "If the Grafana UI shows empty dashboards initially, wait ~30-90s for Prometheus to scrape metrics and for dashboards to fill."
