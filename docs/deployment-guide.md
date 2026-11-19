# 部署指南（Deployment Guide）

> 本指南给出从零部署到验证的完整步骤。所有命令使用**相对路径**或**占位符**；
> 部署前请核对目标区域的规格与可用区。

## 0. 前置准备

| 工具 | 版本要求 | 用途 |
|---|---|---|
| Terraform | `>= 1.5.0` | IaC 编排 |
| huaweicloud Provider | `~> 1.70` | 华为云资源 |
| kubectl | `>= 1.28` | 操作 CCE 集群 |
| docker | 任意较新版本 | 构建并推送镜像 |
| 华为云账号 + AK/SK | 已完成实名 | 资源创建，凭据在本地终端临时设置 |

### 部署前设置环境变量

```bash
export HW_ACCESS_KEY="<AK>"
export HW_SECRET_KEY="<SK>"
# DDS 密码也建议在本地终端临时设置，避免写入文件
export TF_VAR_dds_password="<强密码>"
```

## 1. 部署基础设施（Terraform）

```bash
cd infra
terraform init
terraform plan
terraform apply -auto-approve
```

⚠️ **区域规格复核（重要）**：本仓库在 `variables.tf` / `main.tf` 中写死了部分规格（如 DDS `dds.mongodb.s6.medium.4.repset`、CCE `cce.s1.small`、节点 `s6.large.2`、可用区字母 `a`/`b`）。
**apply 前请确认目标 region 这些规格与可用区真实可用**（不同 region 的 flavor 命名 / 可用区字母可能不同）。
若不适用，修改 `variables.tf` 中的规格与 `main.tf` 的 `availability_zone` 后再 `plan`。

> **公网入口提示**：本架构的 ELB 绑定了公网 IP，部署完成后应用将具备**公网可访问入口**。
> 部署前请确认公网入口与资源用量符合预期。

部署成功后记录关键输出：

```bash
terraform output
# 关注：app_url（公网地址）、elb_id（供第 5 节核对）、
#       dds_connection（DDS 端点列表，敏感）、dds_user、cce_kubeconfig_cmd
```

## 2. 获取 CCE kubeconfig

```bash
$(terraform output -raw cce_kubeconfig_cmd)
# 验证集群可达
kubectl get nodes
```

## 3. 构建并推送镜像到 SWR

```bash
cd src
export REGION=cn-north-4
export SWR_ORG=<你的 SWR 组织名>
export SWR_USER=<SWR 登录指令中的用户名>
export SWR_PASSWORD=<SWR 登录指令中的密码>
./build-and-push.sh
```

## 4. 配置应用 Secret

编辑 `src/k8s/secret.yaml`，将占位符改为真实值：

- `MONGO_HOSTS`：来自 `terraform output -raw dds_connection`（形如 `10.20.1.10:8635,10.20.1.11:8635,10.20.1.12:8635`）
- `MONGO_USER`：来自 `terraform output -raw dds_user`（默认 `rwuser`）
- `MONGO_PASSWORD`：即 `TF_VAR_dds_password` 的值
- `BREAK_APP`：`"false"`（演练故障时改为 `"true"`）

## 5. 部署工作负载

```bash
kubectl apply -f src/k8s/secret.yaml
kubectl apply -f src/k8s/deployment.yaml
kubectl get pods -w
```

> Service 使用 **NodePort 30080** 暴露应用（容器端口 8080）。Terraform 已创建独享型 ELB（HTTP :80 监听器 + 轮询池），并将 CCE 节点 `IP:30080` 注册为后端成员（见 `infra/main.tf` 的 `huaweicloud_elb_member`），因此**无需修改任何 ELB 注解**，只需确认 Terraform 已 apply 成功、`terraform output elb_id` 有输出。

> 若 `kubectl get svc` 显示的 NodePort 不是 30080（被占用时平台可能分配其他端口），需同步修改 `infra/main.tf` 中 `huaweicloud_elb_member` 的 `protocol_port` 后重新 apply，保证两端一致。

## 6. 验证

```bash
# 应用公网地址（来自 terraform output app_url）
curl -i http://<app_url>/health      # 期望 200 {"status":"ok"}
curl -s http://<app_url>/            # 期望销售仪表盘 HTML
curl -s "http://<app_url>/?q=<script>alert(1)</script>"  # 演示反射型 XSS（请勿对外）
```

## 7. 演练故障开关（可选）

```bash
kubectl set env deployment/nimbus-app BREAK_APP=true
curl -i http://<app_url>/            # 数据页应返回 500，/health 仍为 200
# 观察 CES 中 DDS CPU 告警/应用日志（LTS）是否反映异常
kubectl set env deployment/nimbus-app BREAK_APP=false
```

## 8. 清理

```bash
kubectl delete -f src/k8s/deployment.yaml
kubectl delete -f src/k8s/secret.yaml
cd infra && terraform destroy -auto-approve
```

> 清理后请到控制台确认无残留资源（如手工上传的镜像、手动创建的带宽等）。
