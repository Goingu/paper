#!/usr/bin/env bash
# ==============================================================
# Paper Writing — 一键部署脚本
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/Goingu/paper/main/install.sh | bash -s 激活码 邮箱 密码
#   或:
#   wget -qO- https://raw.githubusercontent.com/Goingu/paper/main/install.sh | bash -s 激活码 邮箱 密码
#
# 参数:
#   激活码 - 必填，购买后获得的激活码
#   邮箱   - 可选，管理员邮箱（默认 admin@paperbanana.com）
#   密码   - 可选，管理员密码（至少 8 位，不填则自动生成）
# ==============================================================
set -e

# --- 可配置项 -------------------------------------------------
DEPLOY_DIR="${DEPLOY_DIR:-/opt/paper-writing}"
DEPLOY_PROXY_URL="${DEPLOY_PROXY_URL:-http://103.146.53.97:8748}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/Goingu/paper/main}"
FRONTEND_PORT="${FRONTEND_PORT:-8090}"
DB_PORT="${DB_PORT:-5433}"
REDIS_PORT="${REDIS_PORT:-6381}"

# --- 颜色 -----------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
info()  { echo "${BLUE}[i]${NC} $*"; }
ok()    { echo "${GREEN}[OK]${NC} $*"; }
warn()  { echo "${YELLOW}[!]${NC} $*"; }
fail()  { echo "${RED}[X]${NC} $*" >&2; exit 1; }

# --- 前置检查 -------------------------------------------------
LICENSE_CODE="${1:-${LICENSE_CODE:-}}"
if [[ -z "${LICENSE_CODE}" ]]; then
  fail "请提供激活码。用法: curl -fsSL <url> | bash -s YOUR_LICENSE_CODE"
fi

if [[ $EUID -ne 0 ]]; then
  fail "请用 root 用户运行（sudo -i 切换后再执行）"
fi

info "准备部署 Paper Writing 到 ${DEPLOY_DIR}"
info "激活码: ${LICENSE_CODE:0:4}...${LICENSE_CODE: -4}"

# --- 装 Docker ------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  info "未检测到 Docker，自动安装..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  ok "Docker 安装完成"
else
  ok "Docker 已安装: $(docker --version)"
fi

# Docker compose v2 检查
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    fail "未找到 docker compose 命令，请手动安装 Docker Compose v2"
  fi
else
  DC="docker compose"
fi
ok "Docker Compose: $(${DC} version --short 2>/dev/null || echo unknown)"

# --- 生成机器指纹 ---------------------------------------------
if [[ -r /etc/machine-id ]]; then
  MACHINE_SEED=$(cat /etc/machine-id)
elif [[ -r /var/lib/dbus/machine-id ]]; then
  MACHINE_SEED=$(cat /var/lib/dbus/machine-id)
else
  MACHINE_SEED="$(hostname)-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s)"
fi
MACHINE_ID=$(echo -n "paper-writing:${MACHINE_SEED}" | sha256sum | awk '{print $1}')
info "机器指纹: ${MACHINE_ID:0:16}..."

# --- 向部署代理换取 docker 凭证 -------------------------------
info "验证激活码并换取镜像拉取凭证..."
NOW_MS=$(($(date +%s)*1000))

RESP_FILE=$(mktemp)
HTTP_CODE=$(curl -sS --max-time 30 -w '%{http_code}' -o "${RESP_FILE}" -X POST "${DEPLOY_PROXY_URL}/auth" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"${LICENSE_CODE}\",\"machineId\":\"${MACHINE_ID}\",\"timestamp\":${NOW_MS}}" 2>/dev/null) || HTTP_CODE="000"
AUTH_RESP=$(cat "${RESP_FILE}" 2>/dev/null)
rm -f "${RESP_FILE}"

if [[ "${HTTP_CODE}" == "000" ]]; then
  fail "部署代理不可达 (${DEPLOY_PROXY_URL})，请检查网络或联系服务商"
fi

if [[ "${HTTP_CODE}" -ge 400 ]]; then
  ERROR_MSG=$(echo "${AUTH_RESP}" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail "激活失败 (HTTP ${HTTP_CODE}): ${ERROR_MSG:-未知错误}"
fi

SUCCESS=$(echo "${AUTH_RESP}" | grep -oE '"success":[a-z]*' | head -1 | cut -d: -f2)
if [[ "${SUCCESS}" != "true" ]]; then
  ERROR_MSG=$(echo "${AUTH_RESP}" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  fail "激活失败: ${ERROR_MSG:-未知错误}"
fi

# Pull fields from JSON response
GHCR_USER=$(echo "${AUTH_RESP}" | grep -oE '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
GHCR_TOKEN=$(echo "${AUTH_RESP}" | grep -oE '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
REGISTRY=$(echo "${AUTH_RESP}" | grep -oE '"registry":"[^"]*"' | head -1 | cut -d'"' -f4)
BACKEND_IMAGE=$(echo "${AUTH_RESP}" | grep -oE '"backendImage":"[^"]*"' | head -1 | cut -d'"' -f4)
FRONTEND_IMAGE=$(echo "${AUTH_RESP}" | grep -oE '"frontendImage":"[^"]*"' | head -1 | cut -d'"' -f4)
IMAGE_TAG=$(echo "${AUTH_RESP}" | grep -oE '"imageTag":"[^"]*"' | head -1 | cut -d'"' -f4)
LIC_EXPIRY=$(echo "${AUTH_RESP}" | grep -oE '"licenseExpiresAt":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "${GHCR_TOKEN}" || -z "${BACKEND_IMAGE}" || -z "${FRONTEND_IMAGE}" ]]; then
  fail "部署代理返回数据不完整: ${AUTH_RESP}"
fi

ok "验证通过，授权到期: ${LIC_EXPIRY:-未知}"

# --- 登录镜像仓库 ---------------------------------------------
info "登录镜像仓库 ${REGISTRY}..."
echo "${GHCR_TOKEN}" | docker login "${REGISTRY}" -u "${GHCR_USER}" --password-stdin >/dev/null
ok "登录成功"

# --- 准备部署目录 ---------------------------------------------
mkdir -p "${DEPLOY_DIR}"
cd "${DEPLOY_DIR}"

# 下载 docker-compose.yml
info "下载 docker-compose.yml..."
curl -fsSL "${REPO_RAW_BASE}/docker-compose.yml" -o docker-compose.yml

# 生成 .env（如果不存在，避免覆盖已有配置）
if [[ ! -f .env ]]; then
  info "生成随机密码并写入 .env ..."
  DB_PASSWORD=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-24 || echo "change-me-$(date +%s)")
  REDIS_PASSWORD=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-24 || echo "change-me-$(date +%s)")
  JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "change-me-jwt-$(date +%s)")
  JWT_REFRESH_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "change-me-refresh-$(date +%s)")
  ENCRYPTION_KEY=$(openssl rand -hex 32 2>/dev/null || echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  SERVER_IP=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || echo 'localhost')

  cat > .env <<EOF
# 激活码（不要泄露）
LICENSE_CODE=${LICENSE_CODE}

# 镜像信息
BACKEND_IMAGE=${BACKEND_IMAGE}
FRONTEND_IMAGE=${FRONTEND_IMAGE}
IMAGE_TAG=${IMAGE_TAG}

# 端口
FRONTEND_PORT=${FRONTEND_PORT}
DB_PORT=${DB_PORT}
REDIS_PORT=${REDIS_PORT}

# 数据库
DB_NAME=paper_writing
DB_USER=postgres
DB_PASSWORD=${DB_PASSWORD}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# Auth 密钥（自动随机生成）
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
ENCRYPTION_KEY=${ENCRYPTION_KEY}

# Cookie / CORS
AUTH_COOKIE_SECURE=false
AUTH_COOKIE_SAMESITE=lax
AUTH_COOKIE_PATH=/
AUTH_COOKIE_DOMAIN=
CORS_ORIGINS=http://${SERVER_IP}:${FRONTEND_PORT},http://localhost:${FRONTEND_PORT}
EOF
  ok ".env 已生成: ${DEPLOY_DIR}/.env"
else
  ok "检测到已有 .env，跳过生成（如需更新请手动编辑）"
fi

# --- 拉镜像 & 启动 --------------------------------------------
info "拉取镜像（可能需要几分钟）..."
${DC} pull

info "启动服务..."
${DC} up -d

# --- 等待 backend 就绪 + 运行 migration ----------------------
info "等待服务就绪（最多 60s）..."
for i in $(seq 1 30); do
  if docker exec pw-backend sh -c 'wget -qO- http://127.0.0.1:3001/public-config' >/dev/null 2>&1; then
    ok "后端已就绪"
    break
  fi
  sleep 2
done

info "运行数据库迁移..."
docker exec pw-backend npx prisma migrate deploy 2>/dev/null || docker exec pw-backend npx prisma db push --accept-data-loss 2>/dev/null || ok "数据库已就绪（迁移已由容器自动完成）"

# --- 创建默认管理员 -------------------------------------------
ADMIN_EMAIL="${2:-admin@paperbanana.com}"
ADMIN_PASS="${3:-}"

# 校验密码长度（后端要求至少 8 位）
if [[ -n "${ADMIN_PASS}" && ${#ADMIN_PASS} -lt 8 ]]; then
  warn "您提供的密码少于 8 位，不符合系统要求"
  # 如果是交互式终端，提示重新输入
  if [[ -t 0 ]]; then
    while true; do
      read -sp "请输入新的管理员密码（至少 8 位）: " ADMIN_PASS
      echo ""
      if [[ ${#ADMIN_PASS} -ge 8 ]]; then
        break
      fi
      warn "密码至少 8 位，请重新输入"
    done
  else
    # 非交互式（pipe 模式），自动生成随机密码
    warn "非交互模式，自动生成随机密码"
    ADMIN_PASS=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | cut -c1-12 || echo "Admin123456")
  fi
fi

if [[ -z "${ADMIN_PASS}" ]]; then
  ADMIN_PASS=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | cut -c1-12 || echo "Admin123456")
fi

info "创建管理员账号 (${ADMIN_EMAIL})..."
ADMIN_RESP=$(curl -fsS --max-time 10 -X POST "http://127.0.0.1:8090/api/auth/bootstrap-admin" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"name\":\"管理员\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null) || true

if echo "${ADMIN_RESP}" | grep -q '"user"'; then
  ok "管理员账号创建成功"
else
  warn "管理员账号可能已存在（首次注册的用户即为管理员）"
fi

# --- 完成 -----------------------------------------------------
echo ""
ok "部署完成！"
echo ""
echo "  访问: ${GREEN}http://$(curl -fsS --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):${FRONTEND_PORT}${NC}"
echo "  目录: ${DEPLOY_DIR}"
echo "  配置: ${DEPLOY_DIR}/.env"
echo ""
echo "  管理员账号: ${GREEN}${ADMIN_EMAIL}${NC}"
echo "  管理员密码: ${GREEN}${ADMIN_PASS}${NC}"
echo ""
echo "  ${YELLOW}⚠ 请立即登录后修改管理员密码！${NC}"
echo ""
echo "常用命令："
echo "  查看状态: cd ${DEPLOY_DIR} && ${DC} ps"
echo "  查看日志: cd ${DEPLOY_DIR} && ${DC} logs -f backend"
echo "  停止:     cd ${DEPLOY_DIR} && ${DC} down"
echo "  升级:     curl -fsSL ${REPO_RAW_BASE}/upgrade.sh | bash"
echo ""
