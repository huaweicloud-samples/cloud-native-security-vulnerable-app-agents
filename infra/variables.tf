# ============================================================================
# 变量定义 - 华为云演示沙箱应用
# 所有涉及规格的变量均显式写死，便于部署前核对目标区域规格
# 区域相关规格（ELB flavor ID / 可用区字母 / DDS flavor）按目标 region 实际可调，见 deployment-guide.md。
# ============================================================================

variable "region" {
  description = "华为云区域"
  type        = string
  default     = "cn-north-4" # 北京四
}

variable "project_name" {
  description = "项目名称，用于资源命名前缀"
  type        = string
  default     = "nimbus-demo"
}

variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_a_cidr" {
  description = "子网 A 网段（跨可用区 a）"
  type        = string
  default     = "10.20.1.0/24"
}

variable "subnet_b_cidr" {
  description = "子网 B 网段（跨可用区 b）"
  type        = string
  default     = "10.20.2.0/24"
}

variable "dds_password" {
  description = "DDS（文档数据库）管理员密码"
  type        = string
  sensitive   = true
}

variable "cce_node_password" {
  description = "CCE 节点登录密码（演示用；生产建议 key_pair）"
  type        = string
  sensitive   = true
}

variable "elb_l7_flavor_id" {
  description = "ELB 独享型(dedicated) L7 规格 ID（UUID）。本账号实测无 dedicated 规格（21 个 flavor 全 shared=True），入口使用共享型(shared) ELB，故此变量当前未引用"
  type        = string
  default     = "" # 共享型 ELB 不需要 l7_flavor_id；如未来换 region 开通独享型，再实查 UUID 填入
}

variable "break_app" {
  description = "应用层 BREAK_APP 环境开关：true=故意让数据页 5xx（演示用，部署后立即设为 false 验证业务）"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "应用层数据库名（注入到 k8s Secret 作为 DB_NAME）"
  type        = string
  default     = "nimbus"
}