locals {
  mng_defaults = {
    dedicated_node_role = null
    instance_type       = "t3.xlarge"
    gpu_accelerator     = ""
    gpu_count           = 0
    min_size            = 0
    max_size            = 1
    root_disk_size_gb   = 20
    local_ssd_size_gb   = 0
    spot                = false
    subnet_ids          = module.vpc.private_subnets
  }
  mngs = {
    services = {
      max_size = 3
      min_size = 1
    }
    worker-on-demand = {
      dedicated_node_role = "worker"
      min_size            = 1
      max_size            = 5
      root_disk_size_gb   = 500
    }
    worker-spot = {
      dedicated_node_role = "worker"
      min_size            = 1
      max_size            = 10
      root_disk_size_gb   = 500
      spot                = true
    }
    worker-large-on-demand = {
      dedicated_node_role = "worker"
      instance_type       = "t3.2xlarge"
      max_size            = 5
      root_disk_size_gb   = 500
    }
    worker-large-spot = {
      dedicated_node_role = "worker"
      instance_type       = "t3.2xlarge"
      max_size            = 10
      root_disk_size_gb   = 500
      spot                = true
    }
    worker-gpu-on-demand = {
      dedicated_node_role = "worker"
      instance_type       = "g4dn.metal"
      gpu_accelerator     = "nvidia-tesla-t4"
      gpu_count           = 8
      max_size            = 3
      local_ssd_size_gb   = 1800
      root_disk_size_gb   = 200
    }
  }
  _mngs_with_defaults = {
    for k, v in local.mngs : k => merge(local.mng_defaults, v)
  }
  # Autoscaling Group tags must be managed separately for Cluster Autoscaler
  # to correctly scale node pools from 0.
  # See: https://github.com/terraform-aws-modules/terraform-aws-eks/issues/1886
  # See: https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md#auto-discovery-setup
  _mngs_asg_tags = {
    for k, v in local._mngs_with_defaults : k => merge(
      # Spot
      v.spot ? {
        "k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/capacityType" = "SPOT"
        } : {
        "k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/capacityType" = "ON_DEMAND"
      },
      # Ephemeral storage
      {
        "k8s.io/cluster-autoscaler/node-template/resources/ephemeral-storage" = v.local_ssd_size_gb > 0 ? "${v.local_ssd_size_gb}G" : "${v.root_disk_size_gb}G"
      },
      # GPUs
      v.gpu_count == 0 ? {} : {
        "k8s.io/cluster-autoscaler/node-template/label/k8s.amazonaws.com/accelerator" = v.gpu_accelerator
        "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"            = tostring(v.gpu_count)
        "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"                = "present:NoSchedule"
      },
      # Dedicated node role
      v.dedicated_node_role == null ? {} : {
        "k8s.io/cluster-autoscaler/node-template/label/flyte.org/node-role" = v.dedicated_node_role
        "k8s.io/cluster-autoscaler/node-template/taint/flyte.org/node-role" = "${v.dedicated_node_role}:NoSchedule"
      }
    )
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.10.0"

  cluster_name                    = local.name_prefix
  cluster_version                 = "1.24"
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  enable_irsa                     = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    for k, v in local._mngs_with_defaults : k => {
      desired_size = v.min_size
      max_size     = v.max_size
      min_size     = v.min_size

      ami_type = v.gpu_count == 0 ? null : "AL2_x86_64_GPU"
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = v.root_disk_size_gb
          }
        }
      }
      capacity_type  = v.spot ? "SPOT" : "ON_DEMAND"
      instance_types = [v.instance_type]
      labels = merge(
        v.gpu_count == 0 ? {} : {
          "k8s.amazonaws.com/accelerator" = v.gpu_accelerator
        },
        v.dedicated_node_role == null ? {} : {
          "flyte.org/node-role" = v.dedicated_node_role
        }
      )
      # Setup local SSDs
      pre_bootstrap_user_data = v.local_ssd_size_gb > 0 ? file("${path.module}/setup_local_ssd.sh") : ""
      subnet_ids              = v.subnet_ids
      tags = {
        "k8s.io/cluster-autoscaler/enabled"              = true
        "k8s.io/cluster-autoscaler/${local.name_prefix}" = true
      }
      taints = concat(
        v.gpu_count == 0 ? [] : [
          {
            key    = "nvidia.com/gpu"
            value  = "present"
            effect = "NO_SCHEDULE"
          }
        ],
        v.dedicated_node_role == null ? [] : [
          {
            key    = "flyte.org/node-role"
            value  = v.dedicated_node_role
            effect = "NO_SCHEDULE"
          }
        ]
      )
    }
  }
}

resource "aws_autoscaling_group_tag" "eks_managed_node_group_asg_tag" {
  # Create a unique identifier for each tag by stripping
  # "k8s.io/cluster-autoscaler/node-template/" and adding as a suffix to the name of
  # the managed node group
  for_each = merge([
    for mng, tags in local._mngs_asg_tags : {
      for tag_key, tag_value in tags : "${mng}-${replace(tag_key, "k8s.io/cluster-autoscaler/node-template/", "")}" => {
        mng   = mng
        key   = tag_key
        value = tag_value
      }
    }
  ]...)

  autoscaling_group_name = one(module.eks.eks_managed_node_groups[each.value.mng].node_group_autoscaling_group_names)

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = false
  }

  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "default" {
  name = module.eks.cluster_name
}

data "aws_iam_policy" "cloudwatch_agent_server_policy" {
  name = "CloudWatchAgentServerPolicy"
}

module "aws_cloudwatch_metrics_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.11.2"

  role_name = "${local.name_prefix}-aws-cloudwatch-metrics"
  role_policy_arns = {
    default = data.aws_iam_policy.cloudwatch_agent_server_policy.arn
  }

  oidc_providers = {
    default = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-cloudwatch-metrics"]
    }
  }
}

data "aws_iam_policy_document" "aws_for_fluent_bit_policy" {
  source_policy_documents = [data.aws_iam_policy.cloudwatch_agent_server_policy.policy]

  # Fluent-bit CloudWatch plugin manages log groups and retention policies
  statement {
    actions = [
      "logs:DeleteRetentionPolicy",
      "logs:PutRetentionPolicy"
    ]
    resources = ["*"]
  }
}



module "aws_load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.11.2"

  role_name                              = "${local.name_prefix}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.11.2"

  role_name                        = "${local.name_prefix}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    default = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-cluster-autoscaler"]
    }
  }
}

resource "helm_release" "aws_cloudwatch_metrics" {
  namespace = "kube-system"
  wait      = true
  timeout   = 600

  name = "aws-cloudwatch-metrics"

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-cloudwatch-metrics"
  version    = "0.0.8"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_cloudwatch_metrics_irsa_role.iam_role_arn
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
}

resource "helm_release" "aws_cluster_autoscaler" {
  namespace = "kube-system"
  wait      = true
  timeout   = 600

  name = "aws-cluster-autoscaler"

  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.24.0"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = data.aws_region.current.name
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_autoscaler_irsa_role.iam_role_arn
  }
}



resource "helm_release" "aws_load_balancer_controller" {
  namespace = "kube-system"
  wait      = true
  timeout   = 600

  name = "aws-load-balancer-controller"

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.4.7"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_load_balancer_controller_irsa_role.iam_role_arn
  }
}

