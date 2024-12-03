#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to print an error message and exit
error_exit() {
  echo "[ERROR] $1"
  exit 1
}

# Set required environment variables
get_env() {
  export NODE_IP=${NODE_IP:-`curl -4 ifconfig.me`}             # Default external IP
  export TLS_HOSTNAME=${TLS_HOSTNAME:-"$NODE_IP".nip.io}    # Deafult hostname for TLS certs
  export ISSUER_EMAIL=${ISSUER_EMAIL:-"info@stunner.cc"}   # Deafult email for Let's Encrypt
  export TURN_USER=${TURN_USER:-"stunner-user"}             # Default TURN username
  export TURN_PASSWORD=${TURN_PASSWORD:-"stunner-password"} # Default TURN password
}

# Update system packages
update_system() {
  echo "[INFO] Updating system packages..."
  sudo apt-get update -y || error_exit "Failed to update package list."
  # sudo apt-get upgrade -y || error_exit "Failed to upgrade packages."
}

# Install dependencies
install_dependencies() {
  echo "[INFO] Installing dependencies..."
  sudo apt-get install -y curl || error_exit "Failed to install curl."
}

# Install K3s as master node
install_k3s() {
  echo "[INFO] Installing K3s master node..."
  curl -sfL https://get.k3s.io | sh -
  
  echo "[INFO] Set up kubectl"
  mkdir -p $HOME/.kube
  sudo cp -i /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
  sudo chown $(id -u):$(id -g) /etc/rancher/k3s/k3s.yaml
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  echo 'source <(kubectl completion bash)' >>~/.bashrc
  echo 'alias k=kubectl' >>~/.bashrc
  echo 'complete -o default -F __start_kubectl k' >>~/.bashrc

  kubectl version
  kubectl get nodes && kubectl get pods -A
 
  # Install Helm
  curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
  echo 'source <(helm completion bash)' >>~/.bashrc
  helm version
  
  echo "[INFO] Waiting for system pods to be created in kube-system namespace..."
  while [ $(kubectl get pods -n kube-system | grep -c Running) -le 1 ]; do
    echo -n "."
    sleep 1
  done
  echo "."
}

# Install Cert Manager
install_certmanager() {
  echo "[INFO] Installing Cert-Manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.yaml
  echo "[INFO] Waiting for cert-manager to be ready..."
  kubectl wait --for=condition=Ready -n cert-manager pod  -l app.kubernetes.io/component=webhook --timeout=90s
 cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: $ISSUER_EMAIL  
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
    - http01:
        ingress:
          class: traefik  
EOF
  kubectl get pods -n cert-manager
  
  # Add cert for STUNner
  kubectl create namespace stunner
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: stunner-cert
  namespace: stunner
spec:
  secretName: stunner-tls  
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  commonName: $TLS_HOSTNAME  
  dnsNames:
  - $TLS_HOSTNAME
EOF
}

# Install and configure STUNner
install_stunner() {
  echo "[INFO] Installing Cert-Manager..."
  helm repo add stunner https://l7mp.io/stunner
  helm repo update
  helm install stunner-gateway-operator stunner/stunner-gateway-operator --create-namespace --namespace=stunner --set stunnerGatewayOperator.dataplane.spec.hostNetwork=true
  
  cat <<EOF | kubectl apply -f -
apiVersion: stunner.l7mp.io/v1
kind: GatewayConfig
metadata:
  name: stunner-gatewayconfig
  namespace: stunner
spec:
  realm: stunner.l7mp.io
  authType: plaintext
  userName: $TURN_USER
  password: $TURN_PASSWORD
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: stunner-gatewayclass
spec:
  controllerName: "stunner.l7mp.io/gateway-operator"
  parametersRef:
    group: "stunner.l7mp.io"
    kind: GatewayConfig
    name: stunner-gatewayconfig
    namespace: stunner
  description: "Public STUNner TURN server"
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    stunner.l7mp.io/enable-mixed-protocol-lb: "true"
  name: public-stunner-server
  namespace: stunner
spec:
  gatewayClassName: stunner-gatewayclass
  listeners:
    - name: default-listener
      port: 3478
      protocol: UDP
    - name: tcp-listener
      port: 3478
      protocol: TURN-TCP
    - name: tls-listener
      port: 5349
      protocol: TURN-TLS
      tls:
        certificateRefs:
        - kind: Secret
          name: stunner-tls
          namespace: stunner
    - name: dtls-listener
      port: 5349
      protocol: TURN-DTLS
      tls:
        certificateRefs:
        - kind: Secret
          name: stunner-tls
          namespace: stunner
---
apiVersion: stunner.l7mp.io/v1
kind: StaticService
metadata:
  name: static-svc
  namespace: stunner
spec:
  prefixes:
    - "0.0.0.0/0" # allow every IP on the Internet
---
apiVersion: stunner.l7mp.io/v1
kind: UDPRoute
metadata:
  name: static-services
  namespace: stunner
spec:
  parentRefs:
    - name: public-stunner-server
  rules:
    - backendRefs:
        - group: stunner.l7mp.io
          kind: StaticService
          name: static-svc
EOF
}

# Main script execution
main() {
  echo "[INFO] Starting K3s setup..."
  get_env
  update_system
  install_dependencies
  install_k3s
  install_certmanager
  install_stunner
  echo "[INFO] K3s setup completed successfully."
}

main "$@"
