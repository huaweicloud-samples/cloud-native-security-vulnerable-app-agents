#!/usr/bin/env bash
#
# 构建并推送演示镜像到华为云容器镜像服务（SWR）。
# 登录凭据在本地终端临时设置，不写入任何文件。
#
# 用法：
#   export REGION=cn-north-4
#   export SWR_ORG=<你的 SWR 组织名>
#   export SWR_USER=<SWR 登录指令中的用户名>
#   export SWR_PASSWORD=<SWR 登录指令中的密码>
#   export SWR_TAG=latest
#   ./build-and-push.sh
#
set -euo pipefail

REGION="${REGION:-cn-north-4}"
SWR_ORG="${SWR_ORG:?请设置 SWR_ORG（SWR 组织名）}"
SWR_TAG="${SWR_TAG:-latest}"
IMAGE="swr.${REGION}.myhuaweicloud.com/${SWR_ORG}/nimbus-app:${SWR_TAG}"

# 登录 SWR（凭据来自本地终端环境变量，不写入文件）
docker login -u "${SWR_USER}" -p "${SWR_PASSWORD}" "swr.${REGION}.myhuaweicloud.com"

docker build -t "${IMAGE}" .
docker push "${IMAGE}"
echo "Pushed ${IMAGE}"
