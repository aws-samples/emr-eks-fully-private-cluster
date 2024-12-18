# EMR on EKS Setup Guide

This guide walks through the process of setting up Amazon EMR on EKS and running a Spark job.

## Prerequisites

- AWS CLI configured
- `eksctl` installed
- `kubectl` installed
- An existing EKS cluster, and you have the access to it. For cluster setup, please refer to [EKS Private Cluster Setup with Karpenter](README.md)

## Setup Steps

### 1. Set Environment Variables and Create Namespace

```bash
export CLUSTER_NAME="fully-private-cluster"
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export EMR_JOB_EXECUTION_ROLE_NAME="${CLUSTER_NAME}-emr-eks-JobExecutionRole"
export EMR_NAMESPACE="spark"
```

### 2. Create IAM Identity Mapping

```bash
kubectl create namespace $EMR_NAMESPACE
eksctl create iamidentitymapping --cluster ${CLUSTER_NAME} \
    --namespace ${EMR_NAMESPACE} \
    --service-name "emr-containers" \
    --region ${AWS_REGION}
```

### 3. Create EMR Job Execution Role

#### Create Trust Policy

```bash
cat <<EoF > emr-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticmapreduce.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EoF

aws iam create-role --role-name ${EMR_JOB_EXECUTION_ROLE_NAME} \
    --assume-role-policy-document file://emr-trust-policy.json
```

#### Create Role Policy

```bash
cat <<EoF > emr-JobExecutionRole.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:PutLogEvents",
                "logs:CreateLogStream",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams"
            ],
            "Resource": [
                "arn:aws:logs:*:*:*"
            ]
        }
    ]
}  
EoF

aws iam put-role-policy --role-name ${EMR_JOB_EXECUTION_ROLE_NAME} \
    --policy-name EMR-Containers-Job-Execution \
    --policy-document file://emr-JobExecutionRole.json
```

### 4. Update Role Trust Policy

```bash
aws emr-containers update-role-trust-policy \
    --cluster-name ${CLUSTER_NAME} \
    --namespace spark \
    --role-name ${EMR_JOB_EXECUTION_ROLE_NAME}
```

### 5. Create Virtual Cluster

```bash
aws emr-containers create-virtual-cluster \
--name ${CLUSTER_NAME}-spark \
--container-provider '{
    "id": "'${CLUSTER_NAME}'",
    "type": "EKS",
    "info": {
        "eksInfo": {
            "namespace": "spark"
        }
    }
}'
```

### 6. Create S3 Bucket and Set Environment Variables

```bash
export EMR_VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters \
    --query "virtualClusters[?contains(name, '${CLUSTER_NAME}-spark') && state=='RUNNING'].id" \
    --output text)
export EMR_EXECUTION_ROLE_ARN=$(aws iam get-role \
    --role-name ${EMR_JOB_EXECUTION_ROLE_NAME} \
    --query "Role.Arn" \
    --output text)
```

### 7. Run Sample Spark Job

```bash
aws emr-containers start-job-run \
  --virtual-cluster-id=${EMR_VIRTUAL_CLUSTER_ID} \
  --name=pi \
  --execution-role-arn=${EMR_EXECUTION_ROLE_ARN} \
  --release-label=emr-6.2.0-latest \
  --job-driver='{
    "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/src/main/python/pi.py",
      "sparkSubmitParameters": "--conf spark.executor.instances=1 --conf spark.executor.memory=2G --conf spark.executor.cores=1 --conf spark.driver.cores=1"
    }
  }'
```

or with more resources

```bash
aws emr-containers start-job-run \
  --virtual-cluster-id=${EMR_VIRTUAL_CLUSTER_ID} \
  --name=pi-2 \
  --execution-role-arn=${EMR_EXECUTION_ROLE_ARN} \
  --release-label=emr-6.2.0-latest \
  --job-driver='{
    "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/src/main/python/pi.py",
      "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.executor.memory=2G --conf spark.executor.cores=2 --conf spark.driver.cores=1"
    }
  }'
```

This sample job runs a Python script that calculates π (pi) using Spark.

Use the following command to check the job status:

```bash
echo -e "\nNavigate to EMR virtual cluster console:\n\nhttps://ap-southeast-1.console.aws.amazon.com/emr/home?region=${AWS_DEFAULT_REGION}#/eks/clusters/${EMR_VIRTUAL_CLUSTER_ID}\n"
```

Navigate to the EMR virtual cluster console and check the job status.

### 8. Install Spark Operator (Optional)

```bash
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

helm upgrade --install spark-operator-demo \
  oci://public.ecr.aws/emr-on-eks/spark-operator \
  --set emrContainers.awsRegion=${AWS_REGION} \
  --version 7.3.0 \
  --namespace spark-operator \
  --create-namespace
```

Run a Spark Application

```bash
kubectl apply -f <<EOF -
apiVersion: "sparkoperator.k8s.io/v1beta2"
kind: SparkApplication
metadata:
  name: spark-pi
  namespace: spark-operator
spec:
  type: Scala
  mode: cluster
  image: "public.ecr.aws/emr-on-eks/spark/emr-6.10.0:latest"
  imagePullPolicy: Always
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: "local:///usr/lib/spark/examples/jars/spark-examples.jar"
  sparkVersion: "3.3.1"
  restartPolicy:
    type: Never
  volumes:
    - name: "test-volume"
      hostPath:
        path: "/tmp"
        type: Directory
  driver:
    cores: 1
    coreLimit: "1200m"
    memory: "512m"
    labels:
      version: 3.3.1
    serviceAccount: emr-containers-sa-spark
    volumeMounts:
      - name: "test-volume"
        mountPath: "/tmp"
  executor:
    cores: 1
    instances: 1
    memory: "512m"
    labels:
      version: 3.3.1
    volumeMounts:
      - name: "test-volume"
        mountPath: "/tmp"
EOF
```

## Clean up

```bash
aws emr-containers delete-virtual-cluster \
    --id ${EMR_VIRTUAL_CLUSTER_ID}
```
