# ============================================================================
# 华为云演示沙箱应用 - 主入口 Terraform
# 架构：VPC + 公网子网 + IGW(自动注入 0.0.0.0/0 默认路由) / 独享型 ELB(L7, 公网入口) + CCE 托管 K8s(节点 NodePort 30080 作 ELB 后端) / DDS 文档数据库（MongoDB 兼容） / LTS 日志 + CES 告警
# 入口链路：独享型 ELB 公网 EIP → HTTP 80 listener → ROUND_ROBIN pool → CCE 节点 NodePort 30080 成员
# 说明：SDK 实测 cn-north-4 该账号独享型 ELB 可建（不显式传子网由系统自动分配），共享型不可用；本架构**不需要 NAT 网关**
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.70"
    }
  }

  backend "local" {
    # 生产环境建议改用 OBS 远端后端
  }
}

provider "huaweicloud" {
  region = var.region
  # 访问密钥在本地终端设置，仓库内不出现真实值
  # export HW_ACCESS_KEY="<你的访问密钥>"
  # export HW_SECRET_KEY="<你的私有密钥>"
}

# ============================================================================
# 网络层
# 关键约束：华为云每个 VPC 仅允许 1 张路由表（默认表），IGW add_route=true 自动向默认表注入 IPv4 0.0.0.0/0 → igw
# ============================================================================

resource "huaweicloud_vpc" "main" {
  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
}

resource "huaweicloud_vpc_subnet" "a" {
  name              = "${var.project_name}-subnet-a"
  vpc_id            = huaweicloud_vpc.main.id
  cidr              = var.subnet_a_cidr
  gateway_ip        = cidrhost(var.subnet_a_cidr, 1)
  availability_zone = "${var.region}a"
}

resource "huaweicloud_vpc_subnet" "b" {
  name              = "${var.project_name}-subnet-b"
  vpc_id            = huaweicloud_vpc.main.id
  cidr              = var.subnet_b_cidr
  gateway_ip        = cidrhost(var.subnet_b_cidr, 1)
  availability_zone = "${var.region}b"
}

resource "huaweicloud_vpc_internet_gateway" "igw" {
  name      = "${var.project_name}-igw"
  vpc_id    = huaweicloud_vpc.main.id
  add_route = true

  depends_on = [huaweicloud_vpc_subnet.a, huaweicloud_vpc_subnet.b]
}

# ============================================================================
# 安全组
# ============================================================================

resource "huaweicloud_networking_secgroup" "nodeport" {
  name        = "${var.project_name}-nodeport-sg"
  description = "CCE 节点入站 NodePort 30080（ELB 后端成员 / 健康检查源 100.125.0.0/16 已含于 0.0.0.0/0）"
}

resource "huaweicloud_networking_secgroup_rule" "nodeport_8080" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30080
  port_range_max    = 30080
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = huaweicloud_networking_secgroup.nodeport.id
}

# ============================================================================
# DDS (文档数据库 8635) 入站放行 —— 保证业务数据层连通性
# 根因：DDS 实例复用了本 nodeport SG，而该 SG 默认仅放行 NodePort 30080。
#       CCE Pod 经 vpc-router 出网访问 DDS，源 IP 为 Pod CIDR(172.16.0.0/16)，
#       因此必须同时放行 Pod CIDR 与 VPC 网段(节点/子网 10.20.0.0/16)。
# 该规则为纯防火墙策略变更，不新增任何资源。
# ============================================================================
resource "huaweicloud_networking_secgroup_rule" "dds_ingress_pods" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8635
  port_range_max    = 8635
  remote_ip_prefix  = "172.16.0.0/16"
  security_group_id = huaweicloud_networking_secgroup.nodeport.id
}

resource "huaweicloud_networking_secgroup_rule" "dds_ingress_vpc" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8635
  port_range_max    = 8635
  remote_ip_prefix  = var.vpc_cidr
  security_group_id = huaweicloud_networking_secgroup.nodeport.id
}

# ============================================================================
# 文档数据库（DDS， MongoDB 兼容） - 演示用 notes/leads 存储
# datastore.type 实际接受值：DDS-Community（社区版）/ DDS-Enhanced（增强版，写空）
# 实测 cn-north-4 社区版可用：versions=[4.0,4.2,4.4,5.0]，含 spec_code dds.mongodb.s6.medium.4.repset
# ============================================================================

resource "huaweicloud_dds_instance" "main" {
  name              = "${var.project_name}-dds"
  mode              = "ReplicaSet"
  vpc_id            = huaweicloud_vpc.main.id
  subnet_id         = huaweicloud_vpc_subnet.a.id
  security_group_id = huaweicloud_networking_secgroup.nodeport.id
  availability_zone = "${var.region}a"
  password          = var.dds_password

  datastore {
    type           = "DDS-Community"
    version        = "4.4"
    storage_engine = "rocksDB"
  }

  flavor {
    type      = "replica"                        # ReplicaSet 副本集模式
    num       = 3                                # 副本集 3 节点
    spec_code = "dds.mongodb.s6.medium.4.repset" # 2vCPU / 4GiB。完整名称带 .repset 后缀
    storage   = "ULTRAHIGH"
    size      = 10
  }

  tags = {
    project = var.project_name
  }
}

# ============================================================================
# IAM Agency（CCE 节点代理） - 用于访问 SWR / OBS / AOM
# ============================================================================

resource "huaweicloud_iam_agency" "cce" {
  name                   = "${var.project_name}-cce-agency"
  description            = "CCE 节点代理（委托给 op_svc_cce），用于访问 SWR / OBS / AOM"
  duration               = "FOREVER"
  delegated_service_name = "op_svc_cce"

  project_role {
    project = var.region
    roles = [
      "SWR Admin",
      "OBS OperateAccess",
      "AOM FullAccess",
    ]
  }
}

# ============================================================================
# 容器集群（CCE） + 节点池
# v1.36 推荐 OS：Huawei Cloud EulerOS 2.0
# ============================================================================

# CCE apiserver 公网 EIP（按需、按流量），用于本机 kubectl 直连集群
resource "huaweicloud_vpc_eip" "cce_api" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.project_name}-cce-api-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_cce_cluster" "main" {
  name                   = "${var.project_name}-cce"
  cluster_type           = "VirtualMachine"
  flavor_id              = "cce.s1.small"
  vpc_id                 = huaweicloud_vpc.main.id
  subnet_id              = huaweicloud_vpc_subnet.a.id
  container_network_type = "vpc-router"
  eip                    = huaweicloud_vpc_eip.cce_api.address
  agency_name            = "CCEAutoClusterAgency"

  masters {
    availability_zone = "${var.region}a"
  }
}

resource "huaweicloud_cce_node_pool" "main" {
  cluster_id         = huaweicloud_cce_cluster.main.id
  name               = "${var.project_name}-nodepool"
  flavor_id          = "s6.large.2"
  availability_zone  = "${var.region}a"
  initial_node_count = 1
  subnet_id          = huaweicloud_vpc_subnet.a.id
  password           = var.cce_node_password
  os                 = "Huawei Cloud EulerOS 2.0" # v1.36 实测可用

  root_volume {
    size       = 40
    volumetype = "SSD"
  }

  data_volumes {
    size       = 100
    volumetype = "SSD"
  }
}

# ============================================================================
# 公网入口：独享型 ELB（L7）
# 链路：ELB 公网 EIP → HTTP 80 listener → ROUND_ROBIN pool → CCE 节点 NodePort 30080
# SDK 实测：不显式传子网，由系统自动分配（显式传子网触发 ELB.8904）
# ============================================================================

# 公网 EIP（绑到 ELB 作为入口），流量按需计量
resource "huaweicloud_vpc_eip" "elb_entry" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.project_name}-elb-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_elb_loadbalancer" "main" {
  name              = "${var.project_name}-elb"
  availability_zone = ["${var.region}a"]
  vpc_id            = huaweicloud_vpc.main.id
  ipv4_subnet_id    = huaweicloud_vpc_subnet.a.ipv4_subnet_id
  backend_subnets   = [huaweicloud_vpc_subnet.a.id]
  ipv4_eip_id       = huaweicloud_vpc_eip.elb_entry.id
  # 独享型 ELB 规格（cn-north-4 实测创建时由 API 分配，写回以消除 state drift；
  # 否则 apply 会尝试将 l4/l7 flavor 置空，触发 ELB.8959 拒绝）
  l4_flavor_id = "ec6df27e-8ae9-45e3-828f-a6de45e3e109"
  l7_flavor_id = "66da67e5-e36b-4c9a-8c06-197ae9e92988"
}

resource "huaweicloud_elb_listener" "main" {
  name            = "${var.project_name}-elb-listener"
  protocol        = "HTTP"
  protocol_port   = 80
  loadbalancer_id = huaweicloud_elb_loadbalancer.main.id
  default_pool_id = huaweicloud_elb_pool.main.id
}

resource "huaweicloud_elb_pool" "main" {
  name            = "${var.project_name}-elb-pool"
  protocol        = "HTTP"
  lb_method       = "ROUND_ROBIN"
  loadbalancer_id = huaweicloud_elb_loadbalancer.main.id
}

# 读取 CCE 节点私有 IP（作为 ELB 后端成员）；依赖节点池创建后延迟至 apply 阶段读取
data "huaweicloud_cce_nodes" "main" {
  cluster_id = huaweicloud_cce_cluster.main.id
  depends_on = [huaweicloud_cce_node_pool.main]
}

resource "huaweicloud_elb_member" "nodes" {
  count         = huaweicloud_cce_node_pool.main.initial_node_count
  address       = data.huaweicloud_cce_nodes.main.nodes[count.index].private_ip
  protocol_port = 30080
  pool_id       = huaweicloud_elb_pool.main.id
  subnet_id     = huaweicloud_vpc_subnet.a.ipv4_subnet_id
  weight        = 1
}

# ============================================================================
# 可观测：LTS 日志组/流 + CES 告警
# ============================================================================

resource "huaweicloud_lts_group" "app" {
  group_name  = "${var.project_name}-lts"
  ttl_in_days = 7
}

resource "huaweicloud_lts_stream" "app" {
  group_id    = huaweicloud_lts_group.app.id
  stream_name = "${var.project_name}-app"
  ttl_in_days = 7
}

# 通知主题（CES 告警 notification 必填 SMN URN）
resource "huaweicloud_smn_topic" "alarms" {
  name         = "${var.project_name}-alarms"
  display_name = "${var.project_name} alarms"
}

resource "huaweicloud_ces_alarmrule" "dds_cpu" {
  alarm_name        = "${var.project_name}-dds-cpu"
  alarm_type        = "MULTI_INSTANCE" # 资源组级监控，对 DDS 实例生效
  alarm_enabled     = true
  alarm_description = "DDS CPU 使用率过高时告警（演示运维排查信号）"

  metric {
    namespace   = "SYS.DDS"
    metric_name = "mongo031_cpu_usage"
  }

  condition {
    period              = 300
    filter              = "average"
    comparison_operator = ">"
    value               = 80
    unit                = "%"
    count               = 3
  }

  resources {
    dimensions {
      name  = "mongodb_instance_id"
      value = huaweicloud_dds_instance.main.id
    }
    dimensions {
      name  = "mongodb_node_id"
      value = huaweicloud_dds_instance.main.nodes[0].id
    }
  }

  alarm_actions {
    type              = "notification"
    notification_list = [huaweicloud_smn_topic.alarms.topic_urn]
  }

  depends_on = [huaweicloud_smn_topic.alarms, huaweicloud_dds_instance.main]
}

# ============================================================================
# 输出
# ============================================================================

output "app_url" {
  description = "演示应用公网地址（独享型 ELB 公网入口，HTTP 80 → 节点 NodePort 30080）"
  value       = "http://${huaweicloud_vpc_eip.elb_entry.address}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = huaweicloud_vpc.main.id
}

output "subnet_a_id" {
  description = "子网 A ID"
  value       = huaweicloud_vpc_subnet.a.id
}

output "dds_connection" {
  description = "DDS 连接端点列表（host:port，注入到应用 Secret，敏感）"
  value       = [for node in huaweicloud_dds_instance.main.nodes : "${node.private_ip}:${huaweicloud_dds_instance.main.port}"]
  sensitive   = true
}

output "dds_address" {
  description = "DDS 内网地址列表"
  value       = huaweicloud_dds_instance.main.nodes[*].private_ip
  sensitive   = true
}

output "dds_user" {
  description = "DDS 管理员账号（文档数据库 MongoDB 兼容，默认 rwuser）"
  value       = "rwuser"
}

output "cce_cluster_id" {
  description = "CCE 集群 ID"
  value       = huaweicloud_cce_cluster.main.id
}

output "cce_node_pool_id" {
  description = "CCE 节点池 ID"
  value       = huaweicloud_cce_node_pool.main.id
}

output "cce_kubeconfig_cmd" {
  description = "获取 CCE kubeconfig 的命令"
  value       = "huaweicloud cce cluster get --cluster-id ${huaweicloud_cce_cluster.main.id} --region ${var.region}"
}

output "alarm_name" {
  description = "DDS CPU 告警规则名称"
  value       = huaweicloud_ces_alarmrule.dds_cpu.alarm_name
}

output "smn_topic_urn" {
  description = "告警通知主题 URN"
  value       = huaweicloud_smn_topic.alarms.topic_urn
}

output "elb_entry_eip" {
  description = "ELB 入口公网 IP"
  value       = huaweicloud_vpc_eip.elb_entry.address
}

output "elb_id" {
  description = "独享型 ELB 实例 ID"
  value       = huaweicloud_elb_loadbalancer.main.id
}

# ============================================================================
# 依赖分发桶（验证态临时方案）
# CCE 节点无公网出口，应用运行时依赖(flask/gunicorn/pymongo)无法从公网 PyPI 安装，
# 改为预先下载 Linux wheel -> 上传此 OBS 桶 -> Pod 从 OBS 内网 endpoint 拉取安装。
# 生产态：直接使用含依赖的 SWR 镜像，无需本桶与 deployment 的 OBS 下载步骤。
# ============================================================================
resource "huaweicloud_obs_bucket" "pypi" {
  bucket = "nimbus-demo-pypi-cc2cb3d0"
  acl    = "public-read"
  tags = {
    project = var.project_name
    purpose = "pypi-mirror-verify"
  }
}

output "pypi_bucket" {
  description = "依赖分发 OBS 桶名"
  value       = huaweicloud_obs_bucket.pypi.bucket
}
