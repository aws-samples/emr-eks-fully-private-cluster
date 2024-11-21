
# Karpenter default EC2NodeClass and NodePool
locals {
  karpenter_node_profile = split("/", aws_iam_instance_profile.karpenter.arn)[1]
}

resource "kubectl_manifest" "karpenter_default_ec2_node_class" {
  yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: spark-with-ebs
spec:
  amiSelectorTerms:
  - alias: bottlerocket@latest
  blockDeviceMappings:
  - deviceName: "/dev/xvda"
    ebs:
      encrypted: true
      volumeSize: 100Gi
      volumeType: gp3
  detailedMonitoring: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  instanceProfile: "${local.karpenter_node_profile}"
  securityGroupSelectorTerms:
  - tags:
      Name: "${local.name}-node"
      Blueprint: "${local.name}"
  subnetSelectorTerms:
  - tags:
      Name: "${local.name}-private*"
      karpenter.sh/discovery: "${local.name}"
  tags:
    Name: karpenter-spark-with-ebs
YAML
  depends_on = [
    module.eks.cluster,
    module.eks_blueprints_addons.karpenter,
  ]
}


resource "kubectl_manifest" "karpenter_default_node_pool" {
  yaml_body = <<YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  labels:
    app.kubernetes.io/managed-by: Helm
  name: spark-with-ebs
spec:
  disruption:
    budgets:
    - nodes: 10%
    consolidateAfter: 30s
    consolidationPolicy: WhenEmpty
  limits:
    cpu: 1000
    memory: 1000Gi
  template:
    metadata:
      labels:
        NodeGroupType: spark-with-ebs
        NodePool: spark-with-ebs
        provisioner: spark-with-ebs
        type: karpenter
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: spark-with-ebs
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c"]
      - key: karpenter.k8s.aws/instance-family
        operator: In
        values: ["c5"]
      - key: karpenter.k8s.aws/instance-cpu
        operator: In
        values: ["4", "8", "16", "32"]
      - key: karpenter.k8s.aws/instance-hypervisor
        operator: In
        values: ["nitro"]
      - key: karpenter.k8s.aws/instance-generation
        operator: Gt
        values: ["2"]
      terminationGracePeriod: 48h
  weight: 100
YAML
  depends_on = [
    module.eks.cluster,
    module.eks_blueprints_addons.karpenter,
    kubectl_manifest.karpenter_default_ec2_node_class,
  ]
}
