# EKS cluster via the community module. Nodes run in the private subnets; IRSA is
# enabled so pods (e.g. document-service for S3) can assume IAM roles. The
# control-plane and node IAM roles come from the iam module (Phase 8).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 24.20"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_irsa                              = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Reuse the control-plane role created by the iam module.
  create_iam_role = false
  iam_role_arn    = var.cluster_role_arn

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  eks_managed_node_groups = {
    default = {
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      # Reuse the node role created by the iam module.
      create_iam_role = false
      iam_role_arn    = var.node_role_arn
    }
  }

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# EBS CSI driver — the managed add-on that lets PVCs provision EBS volumes
# (Postgres/Kafka + the observability stack all need PVCs). Installed as a
# standalone aws_eks_addon (rather than inside cluster_addons) so its IRSA role
# can reference the cluster's OIDC provider without a dependency cycle.
# The gp3 StorageClass itself is applied via GitOps (Terraform stays AWS-only).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  # Needs nodes to schedule the controller/daemonset onto.
  depends_on = [module.eks]
}
