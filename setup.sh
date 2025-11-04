#!/bin/bash

# Exit on error, treat unset variables as error, and propagate pipe failures
set -euo pipefail

# Configuration Variables
readonly K8S_VERSION="1.30.0"
readonly CONTAINERD_VERSION="2.0.5"
readonly RUNC_VERSION="1.2.6"
readonly CNI_VERSION="1.6.2"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

# Cleanup trap for errors
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code. Check logs above for details."
    fi
}

trap cleanup_on_error EXIT

log_info "Setting up Kubernetes control plane for AMD64..."
log_info "Kubernetes version: ${K8S_VERSION}"

# Function to check if a process is running
is_running() {
    pgrep -f "$1" >/dev/null 2>&1
}

# Function to download file with retry logic
download_with_retry() {
    local url=$1
    local output=$2
    local retries=0

    while [ $retries -lt $MAX_RETRIES ]; do
        log_info "Downloading $url (attempt $((retries + 1))/$MAX_RETRIES)..."
        if curl -fSL --connect-timeout 30 --max-time 300 "$url" -o "$output"; then
            log_info "Successfully downloaded $url"
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt $MAX_RETRIES ]; then
            log_warn "Download failed, retrying in ${RETRY_DELAY} seconds..."
            sleep $RETRY_DELAY
        fi
    done

    log_error "Failed to download $url after $MAX_RETRIES attempts"
    return 1
}

# Function to validate downloaded file
validate_download() {
    local file=$1
    local min_size=${2:-1000}  # Minimum file size in bytes

    if [ ! -f "$file" ]; then
        log_error "File does not exist: $file"
        return 1
    fi

    local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    if [ "$file_size" -lt "$min_size" ]; then
        log_error "File too small (${file_size} bytes): $file"
        return 1
    fi

    log_info "File validated: $file (${file_size} bytes)"
    return 0
}

# Function to generate secure random token
generate_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head /dev/urandom | tr -dc A-Za-z0-9 | head -c 64
    fi
}

# Function to check if all components are running
check_running() {
    is_running "etcd" && \
    is_running "kube-apiserver" && \
    is_running "kube-controller-manager" && \
    is_running "cloud-controller-manager" && \
    is_running "kube-scheduler" && \
    is_running "kubelet" && \
    is_running "containerd"
}

# Function to kill process if running
stop_process() {
    if is_running "$1"; then
        log_info "Stopping $1..."
        sudo pkill -f "$1" || true
        local timeout=30
        local elapsed=0
        while is_running "$1"; do
            if [ $elapsed -ge $timeout ]; then
                log_warn "Process $1 did not stop gracefully, forcing..."
                sudo pkill -9 -f "$1" || true
                break
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        log_info "$1 stopped"
    fi
}

download_components() {
    log_info "Preparing component download..."

    # Create necessary directories if they don't exist
    local dirs=(
        "./kubebuilder/bin"
        "/etc/cni/net.d"
        "/var/lib/kubelet"
        "/etc/kubernetes/manifests"
        "/var/log/kubernetes"
        "/etc/containerd/"
        "/run/containerd"
    )

    for dir in "${dirs[@]}"; do
        sudo mkdir -p "$dir"
    done

    # Download kubebuilder tools if not present
    if [ ! -f "kubebuilder/bin/etcd" ]; then
        log_info "Downloading kubebuilder tools..."
        download_with_retry \
            "https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-${K8S_VERSION}-linux-amd64.tar.gz" \
            /tmp/kubebuilder-tools.tar.gz
        validate_download /tmp/kubebuilder-tools.tar.gz 1000000
        sudo tar -C ./kubebuilder --strip-components=1 -zxf /tmp/kubebuilder-tools.tar.gz
        rm /tmp/kubebuilder-tools.tar.gz
        sudo chmod -R 755 ./kubebuilder/bin
        log_info "Kubebuilder tools installed successfully"
    else
        log_info "Kubebuilder tools already present, skipping download"
    fi

    if [ ! -f "kubebuilder/bin/kubelet" ]; then
        log_info "Downloading kubelet..."
        download_with_retry \
            "https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/kubelet" \
            /tmp/kubelet
        validate_download /tmp/kubelet 50000000
        sudo mv /tmp/kubelet kubebuilder/bin/kubelet
        sudo chmod 755 kubebuilder/bin/kubelet
        log_info "Kubelet installed successfully"
    else
        log_info "Kubelet already present, skipping download"
    fi

    # Install CNI components if not present
    if [ ! -d "/opt/cni" ]; then
        sudo mkdir -p /opt/cni

        log_info "Installing containerd..."
        download_with_retry \
            "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-static-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
            /tmp/containerd.tar.gz
        validate_download /tmp/containerd.tar.gz 10000000
        sudo tar zxf /tmp/containerd.tar.gz -C /opt/cni/
        rm /tmp/containerd.tar.gz
        log_info "Containerd installed successfully"

        log_info "Installing runc..."
        download_with_retry \
            "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" \
            /tmp/runc
        validate_download /tmp/runc 5000000
        sudo mv /tmp/runc /opt/cni/bin/runc
        log_info "Runc installed successfully"

        log_info "Installing CNI plugins..."
        download_with_retry \
            "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz" \
            /tmp/cni-plugins.tgz
        validate_download /tmp/cni-plugins.tgz 1000000
        sudo tar zxf /tmp/cni-plugins.tgz -C /opt/cni/bin/
        rm /tmp/cni-plugins.tgz
        log_info "CNI plugins installed successfully"

        # Set permissions for all CNI components
        sudo chmod -R 755 /opt/cni
    else
        log_info "CNI components already present, skipping installation"
    fi

    if [ ! -f "kubebuilder/bin/kube-controller-manager" ]; then
        log_info "Downloading additional Kubernetes components..."

        local components=("kube-controller-manager" "kube-scheduler" "cloud-controller-manager")
        for component in "${components[@]}"; do
            log_info "Downloading ${component}..."
            download_with_retry \
                "https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/${component}" \
                "/tmp/${component}"
            validate_download "/tmp/${component}" 50000000
            sudo mv "/tmp/${component}" "kubebuilder/bin/${component}"
            sudo chmod 755 "kubebuilder/bin/${component}"
            log_info "${component} installed successfully"
        done
    else
        log_info "Additional Kubernetes components already present, skipping download"
    fi

    log_info "All components downloaded and validated"
}

setup_configs() {
    log_info "Setting up configurations..."

    # Generate certificates and tokens if they don't exist
    if [ ! -f "/tmp/sa.key" ]; then
        log_info "Generating service account keys..."
        openssl genrsa -out /tmp/sa.key 2048 2>/dev/null
        openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub 2>/dev/null
        log_info "Service account keys generated"
    else
        log_info "Service account keys already exist, skipping generation"
    fi

    if [ ! -f "/tmp/token.csv" ]; then
        log_info "Generating authentication token..."
        TOKEN=$(generate_token)
        echo "${TOKEN},admin,admin,system:masters" > /tmp/token.csv
        chmod 600 /tmp/token.csv
        log_info "Authentication token generated and saved to /tmp/token.csv"
        log_warn "Save this token for authentication: ${TOKEN}"
    else
        log_info "Token file already exists, skipping generation"
    fi

    # Always regenerate and copy CA certificate to ensure it exists
    log_info "Generating CA certificate..."
    openssl genrsa -out /tmp/ca.key 2048 2>/dev/null
    openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt 2>/dev/null
    sudo mkdir -p /var/lib/kubelet/pki
    sudo cp /tmp/ca.crt /var/lib/kubelet/ca.crt
    sudo cp /tmp/ca.crt /var/lib/kubelet/pki/ca.crt
    log_info "CA certificate generated and installed"

    # Set up kubeconfig if not already configured
    if ! sudo kubebuilder/bin/kubectl config current-context 2>/dev/null | grep -q "test-context"; then
        log_info "Configuring kubeconfig..."
        local token=$(grep -oP '^[^,]+' /tmp/token.csv)
        sudo kubebuilder/bin/kubectl config set-credentials test-user --token="${token}"
        sudo kubebuilder/bin/kubectl config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
        sudo kubebuilder/bin/kubectl config set-context test-context --cluster=test-env --user=test-user --namespace=default
        sudo kubebuilder/bin/kubectl config use-context test-context
        log_info "Kubeconfig configured successfully"
    else
        log_info "Kubeconfig already configured, skipping"
    fi

    # Configure CNI
    log_info "Configuring CNI network..."
    cat <<EOF | sudo tee /etc/cni/net.d/10-mynet.conf >/dev/null
{
    "cniVersion": "0.3.1",
    "name": "mynet",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "subnet": "10.22.0.0/16",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ]
    }
}
EOF
    log_info "CNI network configured"

    # Configure containerd
    log_info "Configuring containerd..."
    cat <<EOF | sudo tee /etc/containerd/config.toml >/dev/null
version = 3

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "native"
  disable_snapshot_annotations = true

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false
EOF
    log_info "Containerd configured"

    # Ensure containerd data directory exists with correct permissions
    sudo mkdir -p /var/lib/containerd
    sudo chmod 711 /var/lib/containerd

    # Configure kubelet
    log_info "Configuring kubelet..."
    cat << EOF | sudo tee /var/lib/kubelet/config.yaml >/dev/null
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubelet/ca.crt"
authorization:
  mode: AlwaysAllow
clusterDomain: "cluster.local"
clusterDNS:
  - "10.0.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
failSwapOn: false
seccompDefault: true
serverTLSBootstrap: false
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
staticPodPath: "/etc/kubernetes/manifests"
EOF
    log_info "Kubelet configured"

    # Create required directories with proper permissions
    local kubelet_dirs=(
        "/var/lib/kubelet/pods:750"
        "/var/lib/kubelet/plugins:750"
        "/var/lib/kubelet/plugins_registry:750"
    )

    for dir_perm in "${kubelet_dirs[@]}"; do
        local dir="${dir_perm%%:*}"
        local perm="${dir_perm##*:}"
        sudo mkdir -p "$dir"
        sudo chmod "$perm" "$dir"
    done

    # Ensure proper permissions
    sudo chmod 644 /var/lib/kubelet/ca.crt
    sudo chmod 644 /var/lib/kubelet/config.yaml

    # Generate self-signed kubelet serving certificate if not present
    if [ ! -f "/var/lib/kubelet/pki/kubelet.crt" ] || [ ! -f "/var/lib/kubelet/pki/kubelet.key" ]; then
        log_info "Generating self-signed kubelet serving certificate..."
        sudo openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout /var/lib/kubelet/pki/kubelet.key \
            -out /var/lib/kubelet/pki/kubelet.crt \
            -days 365 \
            -subj "/CN=$(hostname)" 2>/dev/null
        sudo chmod 600 /var/lib/kubelet/pki/kubelet.key
        sudo chmod 644 /var/lib/kubelet/pki/kubelet.crt
        log_info "Kubelet serving certificate generated"
    else
        log_info "Kubelet certificates already exist, skipping generation"
    fi

    log_info "Configuration setup complete"
}

start() {
    log_info "Starting Kubernetes control plane..."

    if check_running; then
        log_info "Kubernetes components are already running"
        return 0
    fi

    HOST_IP=$(hostname -I | awk '{print $1}')
    log_info "Using host IP: ${HOST_IP}"

    # Download components if needed
    download_components

    # Setup configurations
    setup_configs

    # Start components if not running
    if ! is_running "etcd"; then
        log_info "Starting etcd..."
        sudo kubebuilder/bin/etcd \
            --advertise-client-urls http://$HOST_IP:2379 \
            --listen-client-urls http://0.0.0.0:2379 \
            --data-dir ./etcd \
            --listen-peer-urls http://0.0.0.0:2380 \
            --initial-cluster default=http://$HOST_IP:2380 \
            --initial-advertise-peer-urls http://$HOST_IP:2380 \
            --initial-cluster-state new \
            --initial-cluster-token test-token > /var/log/kubernetes/etcd.log 2>&1 &
        log_info "etcd started"
    fi

    # Wait for etcd to be ready
    log_info "Waiting for etcd to be ready..."
    local etcd_ready=false
    for i in {1..30}; do
        if curl -s http://${HOST_IP}:2379/health >/dev/null 2>&1; then
            etcd_ready=true
            break
        fi
        sleep 1
    done

    if [ "$etcd_ready" = false ]; then
        log_error "etcd failed to become ready"
        return 1
    fi
    log_info "etcd is ready"

    if ! is_running "kube-apiserver"; then
        log_info "Starting kube-apiserver..."
        log_info "Using application/vnd.kubernetes.protobuf for better performance"
        sudo kubebuilder/bin/kube-apiserver \
            --etcd-servers=http://$HOST_IP:2379 \
            --service-cluster-ip-range=10.0.0.0/24 \
            --bind-address=0.0.0.0 \
            --secure-port=6443 \
            --advertise-address=$HOST_IP \
            --authorization-mode=AlwaysAllow \
            --token-auth-file=/tmp/token.csv \
            --enable-priority-and-fairness=false \
            --allow-privileged=true \
            --profiling=false \
            --storage-backend=etcd3 \
            --storage-media-type=application/json \
            --v=0 \
            --cloud-provider=external \
            --service-account-issuer=https://kubernetes.default.svc.cluster.local \
            --service-account-key-file=/tmp/sa.pub \
            --service-account-signing-key-file=/tmp/sa.key > /var/log/kubernetes/kube-apiserver.log 2>&1 &
        log_info "kube-apiserver started"
    fi

    # Wait for kube-apiserver to be ready
    log_info "Waiting for kube-apiserver to be ready..."
    local api_ready=false
    for i in {1..60}; do
        if curl -sk https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
            api_ready=true
            break
        fi
        sleep 1
    done

    if [ "$api_ready" = false ]; then
        log_error "kube-apiserver failed to become ready"
        return 1
    fi
    log_info "kube-apiserver is ready"

    if ! is_running "containerd"; then
        log_info "Starting containerd..."
        export PATH=$PATH:/opt/cni/bin:kubebuilder/bin
        sudo PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml > /var/log/kubernetes/containerd.log 2>&1 &
        log_info "containerd started"
    fi

    if ! is_running "kube-scheduler"; then
        log_info "Starting kube-scheduler..."
        sudo kubebuilder/bin/kube-scheduler \
            --kubeconfig=/root/.kube/config \
            --leader-elect=false \
            --v=2 \
            --bind-address=0.0.0.0 > /var/log/kubernetes/kube-scheduler.log 2>&1 &
        log_info "kube-scheduler started"
    fi

    # Set up kubelet kubeconfig
    sudo cp /root/.kube/config /var/lib/kubelet/kubeconfig
    export KUBECONFIG=~/.kube/config
    cp /tmp/sa.pub /tmp/ca.crt

    # Create service account and configmap if they don't exist
    log_info "Creating default service account and configmap..."
    sudo kubebuilder/bin/kubectl create sa default 2>/dev/null || true
    sudo kubebuilder/bin/kubectl create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt -n default 2>/dev/null || true


    if ! is_running "kubelet"; then
        log_info "Starting kubelet..."
        sudo PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet \
            --kubeconfig=/var/lib/kubelet/kubeconfig \
            --config=/var/lib/kubelet/config.yaml \
            --root-dir=/var/lib/kubelet \
            --cert-dir=/var/lib/kubelet/pki \
            --tls-cert-file=/var/lib/kubelet/pki/kubelet.crt \
            --tls-private-key-file=/var/lib/kubelet/pki/kubelet.key \
            --hostname-override=$(hostname) \
            --pod-infra-container-image=registry.k8s.io/pause:3.10 \
            --node-ip=$HOST_IP \
            --cloud-provider=external \
            --cgroup-driver=cgroupfs \
            --max-pods=4  \
            --v=1 > /var/log/kubernetes/kubelet.log 2>&1 &
        log_info "kubelet started"
    fi

    # Wait for kubelet to register node
    log_info "Waiting for node to be registered..."
    local node_ready=false
    for i in {1..30}; do
        if sudo kubebuilder/bin/kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; then
            node_ready=true
            break
        fi
        sleep 2
    done

    if [ "$node_ready" = false ]; then
        log_warn "Node registration timeout, continuing anyway..."
    else
        log_info "Node registered successfully"
    fi

    # Label the node so static pods with nodeSelector can be scheduled
    NODE_NAME=$(hostname)
    log_info "Labeling node ${NODE_NAME}..."
    sudo kubebuilder/bin/kubectl label node "$NODE_NAME" node-role.kubernetes.io/master="" --overwrite 2>/dev/null || true

    if ! is_running "kube-controller-manager"; then
        log_info "Starting kube-controller-manager..."
        sudo PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kube-controller-manager \
            --kubeconfig=/var/lib/kubelet/kubeconfig \
            --leader-elect=false \
            --cloud-provider=external \
            --service-cluster-ip-range=10.0.0.0/24 \
            --cluster-name=kubernetes \
            --root-ca-file=/var/lib/kubelet/ca.crt \
            --service-account-private-key-file=/tmp/sa.key \
            --use-service-account-credentials=true \
            --v=2 > /var/log/kubernetes/kube-controller-manager.log 2>&1 &
        log_info "kube-controller-manager started"
    fi

    log_info "Waiting for all components to be ready..."
    sleep 10

    log_info "Verifying setup..."
    log_info "Cluster nodes:"
    sudo kubebuilder/bin/kubectl get nodes || log_warn "Failed to get nodes"

    log_info "All resources:"
    sudo kubebuilder/bin/kubectl get all -A || log_warn "Failed to get resources"

    log_info "Component statuses:"
    sudo kubebuilder/bin/kubectl get componentstatuses 2>/dev/null || log_warn "Component status check not available"

    log_info "API server readiness:"
    sudo kubebuilder/bin/kubectl get --raw='/readyz?verbose' || log_warn "API server readiness check failed"

    log_info "Kubernetes control plane started successfully!"
    log_info "Logs are available in /var/log/kubernetes/"
}

stop() {
    log_info "Stopping Kubernetes components..."
    local components=(
        "cloud-controller-manager"
        "gce_metadata_server"
        "kube-controller-manager"
        "kubelet"
        "kube-scheduler"
        "kube-apiserver"
        "containerd"
        "etcd"
    )

    for component in "${components[@]}"; do
        stop_process "$component"
    done

    log_info "All components stopped successfully"
}

cleanup() {
    stop
    log_info "Cleaning up data directories..."

    local cleanup_paths=(
        "./etcd"
        "/var/lib/kubelet/*"
        "/run/containerd/*"
        "/tmp/sa.key"
        "/tmp/sa.pub"
        "/tmp/token.csv"
        "/tmp/ca.key"
        "/tmp/ca.crt"
    )

    for path in "${cleanup_paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            sudo rm -rf "$path"
            log_info "Removed $path"
        fi
    done

    log_info "Cleanup complete"
}

status() {
    log_info "Checking Kubernetes component status..."

    local components=(
        "etcd"
        "kube-apiserver"
        "kube-controller-manager"
        "kube-scheduler"
        "kubelet"
        "containerd"
    )

    local all_running=true
    for component in "${components[@]}"; do
        if is_running "$component"; then
            log_info "${component}: ${GREEN}running${NC}"
        else
            log_warn "${component}: ${RED}not running${NC}"
            all_running=false
        fi
    done

    if [ "$all_running" = true ]; then
        log_info "All components are running"
        return 0
    else
        log_warn "Some components are not running"
        return 1
    fi
}

# Main script logic
case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    cleanup)
        cleanup
        ;;
    status)
        status
        ;;
    restart)
        log_info "Restarting Kubernetes control plane..."
        stop
        sleep 5
        start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|cleanup}"
        echo ""
        echo "Commands:"
        echo "  start    - Start all Kubernetes components"
        echo "  stop     - Stop all running Kubernetes components"
        echo "  restart  - Restart all Kubernetes components"
        echo "  status   - Check status of all components"
        echo "  cleanup  - Stop and remove all data and configurations"
        exit 1
        ;;
esac
