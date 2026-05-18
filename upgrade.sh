#!/usr/bin/env bash
# ==============================================================
# Paper Writing — 升级脚本
#
# 拉取最新镜像 + 重启容器 + 运行数据库迁移
# ==============================================================
set -e

DEPLOY_DIR="${DEPLOY_DIR:-/opt/paper-writing}"
DEPLOY_PROXY_URL="${DEPLOY_PROXY_URL:-http://103.146.53.97:8748}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/Goingu/paper/main}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
info() { echo "${BLUE}[i]${NC} $*"; }
ok()   { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
fail() { echo "${RED}[X]${NC} $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then fail "请用 root 用户运行"; fi
[[ -d "${DEPLOY_DIR}" ]] || fail "未检测到部署目录 ${DEPLOY_DIR}，请先运行 install.sh"
[[ -f "${DEPLOY_DIR}/.env" ]] || fail "未检测到 .env 文件"

cd "${DEPLOY_DIR}"

LICENSE_CODE=$(grep '^LICENSE_CODE=' .env | cut -d= -f2)
[[ -n "${LICENSE_CODE}" ]] || fail ".env 里缺少 LICENSE_CODE"

if [[ -r /etc/machine-id ]]; then
  MACHINE_SEED=$(cat /etc/machine-id)
else
  MACHINE_SEED="$(hostname)"
fi
MACHINE_ID=$(echo -n "paper-writing:${MACHINE_SEED}" | sha256sum | awk '{print $1}')

info "重新获取 GHCR 凭证..."
RESP_FILE=$(mktemp)
HTTP_CODE=$(curl -sS --max-time 30 -w '%{http_code}' -o "${RESP_FILE}" -X POST "${DEPLOY_PROXY_URL}/auth" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"${LICENSE_CODE}\",\"machineId\":\"${MACHINE_ID}\",\"timestamp\":$(($(date +%s)*1000))}" 2>/dev/null) || HTTP_CODE="000"
AUTH_RESP=$(cat "${RESP_FILE}" 2>/dev/null)
rm -f "${RESP_FILE}"

if [[ "${HTTP_CODE}" == "000" ]]; then
  fail "部署代理不可达 (${DEPLOY_PROXY_URL})，请检查网络或联系服务商"
fi

if [[ "${HTTP_CODE}" -ge 400 ]]; then
  ERR=$(echo "${AUTH_RESP}" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail "授权验证失败 (HTTP ${HTTP_CODE}): ${ERR:-未知错误}"
fi

SUCCESS=$(echo "${AUTH_RESP}" | grep -oE '"success":[a-z]*' | head -1 | cut -d: -f2)
if [[ "${SUCCESS}" != "true" ]]; then
  ERR=$(echo "${AUTH_RESP}" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail "授权验证失败: ${ERR:-未知错误}"
fi

REGISTRY=$(echo "${AUTH_RESP}" | grep -oE '"registry":"[^"]*"' | head -1 | cut -d'"' -f4)
GHCR_USER=$(echo "${AUTH_RESP}" | grep -oE '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
GHCR_TOKEN=$(echo "${AUTH_RESP}" | grep -oE '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
BACKEND_PYTHON_IMAGE_RESP=$(echo "${AUTH_RESP}" | grep -oE '"backendPythonImage":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "${GHCR_TOKEN}" | docker login "${REGISTRY}" -u "${GHCR_USER}" --password-stdin >/dev/null

if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

# 兼容老 .env：若没有 BACKEND_PYTHON_IMAGE 键则补上（升级到含 backend-python 的版本）
if ! grep -q '^BACKEND_PYTHON_IMAGE=' .env; then
  IMG="${BACKEND_PYTHON_IMAGE_RESP:-ghcr.io/goingu/paper-writing-standalone/backend-python}"
  echo "BACKEND_PYTHON_IMAGE=${IMG}" >> .env
  info "已在 .env 写入 BACKEND_PYTHON_IMAGE=${IMG}"
fi

info "下载最新 docker-compose.yml..."
curl -fsSL "${REPO_RAW_BASE}/docker-compose.yml" -o docker-compose.yml

info "拉取最新镜像..."
${DC} pull

info "重启容器..."
${DC} up -d --force-recreate backend backend-python frontend

info "等待后端就绪..."
for i in $(seq 1 30); do
  if docker exec pw-backend sh -c 'wget -qO- http://127.0.0.1:3001/public-config' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

info "运行数据库迁移..."
docker exec pw-backend npx prisma migrate deploy || warn "prisma migrate 返回错误"

ok "升级完成"
