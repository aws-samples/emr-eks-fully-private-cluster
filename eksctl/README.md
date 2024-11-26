# EKS Private Cluster Setup with Karpenter

This directory contains scripts and configurations for setting up an Amazon EKS cluster with Karpenter for automatic node provisioning, using IAM Roles for Service Accounts (IRSA).

## Prerequisites

- AWS CLI configured with appropriate credentials
- Appropriate AWS IAM permissions
- `eksctl` installed
- `helm` installed
- `kubectl` installed

## Step-by-Step Setup Guide

### 1. Environment Setup

Set the required environment variables, you may change the variables to your own preferences:

```bash
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="1.0.7"
export K8S_VERSION="1.31"
export AWS_PARTITION="aws"
export CLUSTER_NAME="fully-private-cluster"
export AWS_DEFAULT_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
export TEMPOUT="$(mktemp)"
```

### 2. Deploy Karpenter CloudFormation Stack

```bash
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

### 3. Create and Deploy EKS Cluster

Create the cluster configuration inline and deploy:

```bash
cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  serviceAccounts:
  - metadata:
      name: karpenter
      namespace: "${KARPENTER_NAMESPACE}"
    roleName: ${CLUSTER_NAME}-karpenter
    attachPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}
    roleOnly: true

vpc:
  subnets:
    private:
      # Replace with your own subnet IDs
      ap-southeast-1a:
        id: subnet-XXXXXXXXXXXXXXXXX
      ap-southeast-1b:
        id: subnet-XXXXXXXXXXXXXXXXX
      ap-southeast-1c:
        id: subnet-XXXXXXXXXXXXXXXXX

privateCluster:
  enabled: true
  skipEndpointCreation: true # You may change to `false` or remove this line if you did not create the VPC endpoints for the private clusters

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes

managedNodeGroups:
- name: private-cluster-ng
  minSize: 1
  maxSize: 3
  instanceType: m5.xlarge
  privateNetworking: true
  desiredCapacity: 3
  volumeType: gp3

addons:
- name: vpc-cni
  version: latest
- name: coredns
  version: latest
- name: kube-proxy
  version: latest
EOF
```

**Note**: Before deploying the cluster, please make sure you are satisfy with the configs. Especially the VPC subnets and `privateCluster` fields.

Deploy the cluster:

```bash
eksctl create cluster -f cluster.yaml
```

It's very likely that you do not have the access to the EKS cluster due to the networking issue, that's because there is no valid inbound access rule from EKS Control Plane security group. Please add the inbound rule by navigating to the EKS console, find the `Additional security groups` under the `Networking` tab.

### 4. Create ECR Pull Through Cache (Optional)

Create a pull through cache for the ECR public repository. This is optional, but it can help you to pull the image from ECR public registry. You can use the similar approach for other public registries. Learn more about [ECR pull through cache](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-rule.html).

```bash
aws ecr create-pull-through-cache-rule \
     --ecr-repository-prefix ecr-public \
     --upstream-registry-url public.ecr.aws \
     --region ${AWS_DEFAULT_REGION}
```

### 5. Install Karpenter

**Note**: Before installing Karpenter, you may need to put Karpenter image in your own ECR repository. In this example, we will using the ECR pull through cache feature, so we specify the image by setting the `controller.image.repository` field. Please change accordingly for your own use case.

Retrieve the cluster endpoint and Karpenter IAM role ARN:

```bash
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"
export KARPENTER_IMAGE_REPOSITORY="${ECR_URL}/ecr-public/karpenter/controller"  # Change to your own ECR repository if you already have one
```

Install Karpenter:
```bash
helm registry logout public.ecr.aws
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "controller.image.repository=${KARPENTER_IMAGE_REPOSITORY}" \
  --set "settings.isolatedVPC=true" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set "settings.aws.clusterName=${CLUSTER_NAME}" \
  --set "settings.aws.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.aws.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.create=false" \
  --set "serviceAccount.name=karpenter"
```

### 6. Create Instance Profile

This is required for Karpenter setup in private cluster. Because the `EC2NodeClass` resource will refer to the instance profile, so that the Karpenter node can join the cluster.

```bash
aws iam create-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam add-role-to-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
```

### 7. Configure Karpenter Resources

To Create the NodePool and EC2NodeClass configurations. The below is just an example to demonstrate the Karpenter resources are working. You may change the configurations accordingly for your own use case.

```bash
cat <<EOF > karpenter-resources.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h # 30 * 24h = 720h
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: Bottlerocket # You may change to other AMI family depending on your needs
  amiSelectorTerms:
  - alias: bottlerocket@latest # Here we use the latest AMI based on the amiFamily specified.
  instanceProfile: "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" # This is crucial for Karpenter setup in private cluster
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF

kubectl apply -f karpenter-resources.yaml
```

### 8. Verify Karpenter Resources

```bash
kubectl get nodepool,ec2nodeclass
```

You should see something like the following:

```text
NAME                            NODECLASS   NODES   READY   AGE
nodepool.karpenter.sh/default   default     1       True    10h

NAME                                     READY   AGE
ec2nodeclass.karpenter.k8s.aws/default   True    10h
```

Both resources status should be in `True` and `Ready` status.

## Important Notes

### ECR Pull Permissions

Add the following IAM policy to the node role for ECR image pulling:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:CreateRepository",
                "ecr:BatchImportUpstreamImage",
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage"
            ],
            "Resource": "*"
        }
    ]
}
```

### Enable IAM Roles for Service Accounts (IRSA)

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} \
  --region ${REGION} \
  --approve
```

## Troubleshooting

1. If you cannot access the cluster, check the security group rules for the EKS cluster control plane
2. For Karpenter image pulling issues, verify the ECR permissions are correctly configured
3. Ensure all environment variables are properly set before running the commands

## License

MIT. See the [LICENSE](LICENSE) file for details.
