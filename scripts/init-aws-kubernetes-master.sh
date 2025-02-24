!/bin/bash

exec &> /var/log/init-aws-kubernetes-master.log

set -o verbose
set -o errexit
set -o pipefail

export KUBEADM_TOKEN=${kubeadm_token}
#export DNS_NAME=${dns_name}
export IP_ADDRESS=${ip_address}
export CLUSTER_NAME=${cluster_name}
export ASG_NAME=${asg_name}
export ASG_MIN_NODES="${asg_min_nodes}"
export ASG_MAX_NODES="${asg_max_nodes}"
export AWS_REGION=${aws_region}
export AWS_SUBNETS="${aws_subnets}"
export ADDONS="${addons}"
export KUBERNETES_VERSION="1.20.0"

# Set this only after setting the defaults
set -o nounset

# We needed to match the hostname expected by kubeadm an the hostname used by kubelet
FULL_HOSTNAME="$(curl -s http://169.254.169.254/latest/meta-data/hostname)"

# Make DNS lowercase
#DNS_NAME=$(echo "$DNS_NAME" | tr 'A-Z' 'a-z')

# Install AWS CLI client
#ap install -y python2-pip
#pip install awscli --upgrade

# Tag subnets
#for SUBNET in $AWS_SUBNETS
#do
#  aws ec2 create-tags --resources $SUBNET --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared --region $AWS_REGION
#done
apt-get update
apt-get install -y apt-transport-https curl
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
# Install docker
apt-get update
apt-get update & apt-get install -y docker.io kubelet kubeadm kubernetes-cni

#curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
#echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes components
# sudo cat <<EOF > /etc/yum.repos.d/kubernetes.repo
# [kubernetes]
# name=Kubernetes
# baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
# enabled=1
# gpgcheck=1
# repo_gpgcheck=1
# gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
#         https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
# EOF

# setenforce returns non zero if already SE Linux is already disabled
# is_enforced=$(getenforce)
# if [[ $is_enforced != "Disabled" ]]; then
#   setenforce 0
#   sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config

# fi

#apt-get install -y kubelet kubeadm kubernetes-cni

# Start services
#systemctl enable docker
#systemctl start docker
#systemctl enable kubelet
#systemctl start kubelet

# Set settings needed by Docker
#sysctl net.bridge.bridge-nf-call-iptables=1
#sysctl net.bridge.bridge-nf-call-ip6tables=1

# Fix certificates file on CentOS
#if cat /etc/*release | grep ^NAME= | grep Ubuntu ; then
#    rm -rf /etc/ssl/certs/ca-certificates.crt/
#    cp /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
#fi

# Initialize the master
cat >/tmp/kubeadm.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: $KUBEADM_TOKEN
  ttl: 0s
  usages:
  - signing
  - authentication
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  kubeletExtraArgs:
    cloud-provider: aws
    read-only-port: "10255"
  name: $FULL_HOSTNAME
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
apiServer:
  certSANs:
  - $IP_ADDRESS
  extraArgs:
    cloud-provider: aws
  timeoutForControlPlane: 5m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager:
  extraArgs:
    cloud-provider: aws
dns:
  type: CoreDNS
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: k8s.gcr.io
kubernetesVersion: v$KUBERNETES_VERSION
networking:
# podNetworkCidr: 192.168.0.0/16
  dnsDomain: cluster.local
  podSubnet: ""
  serviceSubnet: 10.96.0.0/12
scheduler: {}
---
EOF

kubeadm reset --force
kubeadm init --config /tmp/kubeadm.yaml

# Use the local kubectl config for further kubectl operations
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install calico
kubectl apply -f /tmp/calico.yaml

# Allow the user to administer the cluster
kubectl create clusterrolebinding admin-cluster-binding --clusterrole=cluster-admin --user=admin

# Prepare the kubectl config file for download to cient (IP address)
export KUBECONFIG_OUTPUT=/home/ubuntu/kubeconfig_ip
kubeadm alpha kubeconfig user --client-name admin --config /tmp/kubeadm.yaml > $KUBECONFIG_OUTPUT
chown ubuntu:ubuntu $KUBECONFIG_OUTPUT
chmod 0600 $KUBECONFIG_OUTPUT

cp /home/ubuntu/kubeconfig_ip /home/ubuntu/kubeconfig
#sed -i "s/server: https:\/\/$IP_ADDRESS:6443/server: https:\/\/$DNS_NAME:6443/g" /home/ubuntu/kubeconfig
chown ubuntu:ubuntu /home/ubuntu/kubeconfig
chmod 0600 /home/ubuntu/kubeconfig

# Load addons
for ADDON in $ADDONS
do
  curl $ADDON | envsubst > /tmp/addon.yaml
  kubectl apply -f /tmp/addon.yaml
  rm /tmp/addon.yaml
done
touch /home/ubuntu/completed
