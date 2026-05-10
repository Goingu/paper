# Paper Writing 部署

> 一个专门为论文写作打造的 AI SaaS 系统

## 快速部署（推荐）

准备一台 **全新的 Linux 服务器**（Ubuntu 22.04 / Debian 12 / CentOS 9 皆可），配置建议：

- CPU: 2 核及以上
- 内存: 4GB 及以上
- 硬盘: 40GB 及以上
- 已开放端口: 80 / 443 / 22

用 root 用户登录，执行一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/Goingu/paper/main/install.sh | bash -s YOUR_LICENSE_CODE
```

把 `YOUR_LICENSE_CODE` 替换成你的激活码（从服务商处获得）。

完成后访问 `http://你的服务器IP:8090` 即可。

---

## 常见问题

### Q1: 提示 "部署代理不可达"
- 检查服务器是否能访问公网
- 检查 `103.146.53.97:8748` 是否通（`curl http://103.146.53.97:8748/health`）

### Q2: 提示 "激活码已被其他设备使用"
- 激活码只能绑定一台机器
- 如果换服务器了，请联系服务商解绑

### Q3: 如何绑定域名 + HTTPS

在 nginx 里配置反向代理到 `127.0.0.1:8090`，简单示例：

```nginx
server {
  listen 80;
  server_name yourdomain.com;
  client_max_body_size 100M;

  location / {
    proxy_pass http://127.0.0.1:8090;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_read_timeout 600s;
  }
}
```

配好后用 certbot 申请 HTTPS 证书。

### Q4: 查看运行状态 / 日志

```bash
cd /opt/paper-writing
docker compose ps
docker compose logs -f backend
```

### Q5: 停止 / 启动

```bash
cd /opt/paper-writing
docker compose down     # 停止
docker compose up -d    # 启动
```

### Q6: 升级到最新版

```bash
curl -fsSL https://raw.githubusercontent.com/Goingu/paper/main/upgrade.sh | bash
```

### Q7: 数据备份

PostgreSQL 数据默认存在 docker volume `pw_postgres_data`。备份：

```bash
docker exec pw-postgres pg_dump -U postgres paper_writing | gzip > backup-$(date +%Y%m%d).sql.gz
```

恢复：

```bash
gunzip < backup.sql.gz | docker exec -i pw-postgres psql -U postgres paper_writing
```

### Q8: 默认管理员账号？

首次部署后，第一个注册的邮箱会通过**引导模式**成为管理员。或者联系服务商取得预置账号。

---

## 架构

```
        用户浏览器
           │
           ▼
   ┌──────────────────┐
   │ nginx/反向代理   │  (可选，但推荐用于绑定域名 + HTTPS)
   └─────────┬────────┘
             │
             ▼
   ┌──────────────────┐
   │ pw-frontend      │  Next.js 前端 (:8090)
   └─────────┬────────┘
             │ /api/* → backend
             ▼
   ┌──────────────────┐
   │ pw-backend       │  NestJS 后端 (:3001)
   └──┬────────┬──────┘
      │        │
   ┌──▼──┐  ┌──▼────┐
   │ PG  │  │ Redis │
   └─────┘  └───────┘
```

所有组件跑在 Docker，互相通过内部网络通讯，数据持久化在 Docker volume。

---

## 获取支持

- 遇到问题联系你的服务商
