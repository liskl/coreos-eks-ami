#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

err_report() {
    echo "Exited with error on line $1"
}
trap 'err_report $LINENO' ERR

IFS=$'\n\t'

function print_help {
    echo "usage: $0 [options] <cluster-name>"
    echo "Bootstraps an instance into an EKS cluster"
    echo ""
    echo "-h,--help print this help"
    echo "--use-max-pods Sets --max-pods for the kubelet when true. (default: true)"
    echo "--b64-cluster-ca The base64 encoded cluster CA content. Only valid when used with --apiserver-endpoint. Bypasses calling \"aws eks describe-cluster\""
    echo "--apiserver-endpoint The EKS cluster API Server endpoint. Only valid when used with --b64-cluster-ca. Bypasses calling \"aws eks describe-cluster\""
    echo "--kubelet-extra-args Extra arguments to add to the kubelet. Useful for adding labels or taints."
    echo "--enable-docker-bridge Restores the docker default bridge network. (default: false)"
    echo "--aws-api-retry-attempts Number of retry attempts for AWS API call (DescribeCluster) (default: 3)"
    echo "--docker-config-json The contents of the /etc/docker/daemon.json file. Useful if you want a custom config differing from the default one in the AMI"
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --use-max-pods)
            USE_MAX_PODS="$2"
            shift
            shift
            ;;
        --b64-cluster-ca)
            B64_CLUSTER_CA=$2
            shift
            shift
            ;;
        --apiserver-endpoint)
            APISERVER_ENDPOINT=$2
            shift
            shift
            ;;
        --kubelet-extra-args)
            KUBELET_EXTRA_ARGS=$2
            shift
            shift
            ;;
        --enable-docker-bridge)
            ENABLE_DOCKER_BRIDGE=$2
            shift
            shift
            ;;
        --aws-api-retry-attempts)
            API_RETRY_ATTEMPTS=$2
            shift
            shift
            ;;
        --docker-config-json)
            DOCKER_CONFIG_JSON=$2
            shift
            shift
            ;;
        --pause-container-account)
            PAUSE_CONTAINER_ACCOUNT=$2
            shift
            shift
            ;;
        --pause-container-version)
            PAUSE_CONTAINER_VERSION=$2
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
CLUSTER_NAME="$1"
set -u

USE_MAX_PODS="${USE_MAX_PODS:-true}"
B64_CLUSTER_CA="${B64_CLUSTER_CA:-}"
APISERVER_ENDPOINT="${APISERVER_ENDPOINT:-}"
KUBELET_EXTRA_ARGS="${KUBELET_EXTRA_ARGS:-}"
ENABLE_DOCKER_BRIDGE="${ENABLE_DOCKER_BRIDGE:-false}"
API_RETRY_ATTEMPTS="${API_RETRY_ATTEMPTS:-3}"
DOCKER_CONFIG_JSON="${DOCKER_CONFIG_JSON:-}"
PAUSE_CONTAINER_VERSION="${PAUSE_CONTAINER_VERSION:-3.1}"

function get_pause_container_account_for_region () {
    local region="$1"
    case "${region}" in
    ap-east-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-800184023465}";;
    *)
        echo "${PAUSE_CONTAINER_ACCOUNT:-602401143452}";;
    esac
}

if [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is not defined"
    exit  1
fi

ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
AWS_DEFAULT_REGION=$(echo $ZONE | awk '{print substr($0, 1, length($0)-1)}')

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
    ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
    ARCH="arm64"
else
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi

### kubelet kubeconfig

CA_CERTIFICATE_DIRECTORY=/etc/kubernetes/pki
CA_CERTIFICATE_FILE_PATH=$CA_CERTIFICATE_DIRECTORY/ca.crt
mkdir -p $CA_CERTIFICATE_DIRECTORY
if [[ -z "${B64_CLUSTER_CA}" ]] && [[ -z "${APISERVER_ENDPOINT}" ]]; then
    DESCRIBE_CLUSTER_RESULT=$(docker run --rm cfn-helper aws eks describe-cluster \
        --region=${AWS_DEFAULT_REGION} \
        --name=${CLUSTER_NAME} \
        --output=text \
        --query 'cluster.{certificateAuthorityData: certificateAuthority.data, endpoint: endpoint}') ## > $DESCRIBE_CLUSTER_RESULT
    B64_CLUSTER_CA=$(echo $DESCRIBE_CLUSTER_RESULT | awk '{print $1}')
    APISERVER_ENDPOINT=$(echo $DESCRIBE_CLUSTER_RESULT | awk '{print $2}')
fi

echo $B64_CLUSTER_CA | base64 -d > $CA_CERTIFICATE_FILE_PATH

sed -i s,CLUSTER_NAME,$CLUSTER_NAME,g /var/lib/kubelet/kubeconfig
sed -i s,MASTER_ENDPOINT,$APISERVER_ENDPOINT,g /var/lib/kubelet/kubeconfig
/opt/bin/kubectl config \
    --kubeconfig /var/lib/kubelet/kubeconfig \
    set-cluster \
    kubernetes \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --server=$APISERVER_ENDPOINT

### kubelet.service configuration

MAC=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ -s | head -n 1 | sed 's/\/$//')
TEN_RANGE=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-blocks | grep -c '^10\..*' || true )
DNS_CLUSTER_IP=10.100.0.10
if [[ "$TEN_RANGE" != "0" ]] ; then
    DNS_CLUSTER_IP=172.20.0.10;
fi

KUBELET_CONFIG=/etc/kubernetes/kubelet/kubelet-config.json
echo "$(jq ".clusterDNS=[\"$DNS_CLUSTER_IP\"]" $KUBELET_CONFIG)" > $KUBELET_CONFIG

INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)

if [[ "$USE_MAX_PODS" = "true" ]]; then
    MAX_PODS_FILE="/etc/eks/eni-max-pods.txt"
    set +o pipefail
    MAX_PODS=$(grep ^$INSTANCE_TYPE $MAX_PODS_FILE | awk '{print $2}')
    set -o pipefail
    if [[ -n "$MAX_PODS" ]]; then
        echo "$(jq ".maxPods=$MAX_PODS" $KUBELET_CONFIG)" > $KUBELET_CONFIG
    else
        echo "No entry for $INSTANCE_TYPE in $MAX_PODS_FILE. Not setting max pods for kubelet"
    fi
fi

cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubelet-args.conf
[Service]
Environment='KUBELET_ARGS=--node-ip=$INTERNAL_IP --pod-infra-container-image=$(get_pause_container_account_for_region "${AWS_DEFAULT_REGION}").dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/eks/pause-${ARCH}:$PAUSE_CONTAINER_VERSION'
EOF

if [[ -n "$KUBELET_EXTRA_ARGS" ]]; then
    cat <<EOF > /etc/systemd/system/kubelet.service.d/30-kubelet-extra-args.conf
[Service]
Environment='KUBELET_EXTRA_ARGS=$KUBELET_EXTRA_ARGS'
EOF
fi

# Replace with custom docker config contents.
if [[ -n "$DOCKER_CONFIG_JSON" ]]; then
    echo "$DOCKER_CONFIG_JSON" > /etc/docker/daemon.json
    systemctl restart docker
fi

if [[ "$ENABLE_DOCKER_BRIDGE" = "true" ]]; then
    # Enabling the docker bridge network. We have to disable live-restore as it
    # prevents docker from recreating the default bridge network on restart
    echo "$(jq '.bridge="docker0" | ."live-restore"=false' /etc/docker/daemon.json)" > /etc/docker/daemon.json
    systemctl restart docker
fi
mkdir -p /var/lib/kubelet/device-plugins

systemctl daemon-reload
systemctl enable kubelet
systemctl start kubelet
