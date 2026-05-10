# 详细部署指南

## 一键部署流程

```
┌─ 部署者 ──────────┐
│                   │
│  curl | bash      │── (1) 激活码 + 机器指纹 ──►  部署代理 (8748)
│                   │                                  │
│                   │                                  │ (2) 验证激活码
│                   │                                  ▼
│                   │                           activation-manager (8747)
│                   │                                  │
│                   │ ◄─ (3) GHCR 凭证 ─────────────┘
│                   │
│  docker login     │──────────────────►  ghcr.io
│  docker pull      │                        │
│                   │ ◄─ 镜像 ─────────────┘
│                   │
│  生成 .env        │
│  docker up        │── 启动 4 个容器 ──►  postgres / redis / backend / frontend
│                   │
│  backend 启动后   │── 自动激活 license ──►  activation-manager
│                   │
└───────────────────┘
```

## 细节

### 1. 激活码绑定机器

- 激活码在首次激活时绑定到这台服务器的机器指纹（`/etc/machine-id` 的 sha256）
- 之后**不能**在另一台服务器用同一个激活码（报错 "激活码已被其他设备使用"）
- 如果你要迁移服务器，请联系服务商**解绑**旧机器

### 2. 目录结构

```
/opt/paper-writing/
├── docker-compose.yml   # install.sh 下载的
├── .env                 # 自动生成的环境变量（不要提交到 git）
└── (docker volumes)     # 数据持久化（由 Docker 管理）
    ├── pw_postgres_data
    ├── pw_redis_data
    └── pw_uploads_data
```

### 3. 端口占用

- `8090` → 前端（你访问的地址）
- `5433` → Postgres（只监听 127.0.0.1，外部访问不到）
- `6381` → Redis（只监听 127.0.0.1，外部访问不到）
- `3001` → Backend（不对外暴露，只有 frontend 能访问）

如果端口冲突，可以改 `.env` 里的 `FRONTEND_PORT` / `DB_PORT` / `REDIS_PORT`，重启容器即可。

### 4. License 续签

- 部署成功后，backend 容器会**每 6 小时**自动联系 activation-manager 续签 license
- 如果 activation-manager 不可达，会进入宽限期（默认 2 小时）
- 宽限期后 license 失效，用户无法使用（但数据不会丢）

### 5. 防火墙

默认 `docker-compose.yml` 只对外暴露 8090 端口。推荐使用 ufw / firewalld 只放行必要端口：

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 8090/tcp    # 禁止直接访问，强制走 nginx
ufw enable
```

如果不用 nginx，可以允许 8090。

### 6. 升级不丢数据

```bash
curl -fsSL https://raw.githubusercontent.com/Goingu/paper/main/upgrade.sh | bash
```

升级只会拉取新镜像、重启 backend/frontend 容器、执行 prisma migrate。数据库和 uploads 卷保持不变。

### 7. 完全卸载

```bash
cd /opt/paper-writing
docker compose down -v       # -v 会删除所有数据卷，慎用！
rm -rf /opt/paper-writing
```

## 故障排查

### backend 容器不断重启

```bash
docker logs pw-backend --tail 50
```

常见原因：
- 数据库密码不对（.env 里的 DB_PASSWORD 和启动时不一致）
- activation-manager 连不上 → 等 2 小时后 license 过期
- prisma migrate 失败 → 手动跑一次 `docker exec pw-backend npx prisma migrate deploy`

### frontend 502

```bash
docker logs pw-frontend --tail 30
```

大部分是 backend 没起来。先修 backend。

### 忘记管理员密码

联系服务商提供重置脚本，或自己进数据库：

```bash
docker exec -it pw-postgres psql -U postgres -d paper_writing
> UPDATE users SET password_hash = '<bcrypt_hash>' WHERE email = 'your@email.com';
```
