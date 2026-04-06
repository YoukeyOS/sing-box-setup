# deploy_anytls_singbox.sh

交互式 Bash 脚本，用于在 Debian/Ubuntu VPS 上部署：

- sing-box AnyTLS 入站
- Let's Encrypt 证书
- Cloudflare DNS API 验证
- systemd 管理
- 证书续期后自动复制到 `/etc/sing-box/certs/<host>/` 并重载 sing-box

## 运行方式

建议先下载再审阅：

```bash
curl -fsSL -o deploy_anytls_singbox.sh https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/<BRANCH>/deploy_anytls_singbox.sh
less deploy_anytls_singbox.sh
bash deploy_anytls_singbox.sh
```

也可以直接远程执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/<BRANCH>/deploy_anytls_singbox.sh)
```

## 需要准备

1. root 权限
2. 域名已托管到 Cloudflare
3. 在 Cloudflare 中为目标域名准备好 Zone
4. 一个 Cloudflare API Token，至少带 `Zone:DNS:Edit`，并限制到对应 Zone
5. 目标域名的 A 记录应保持 **DNS only（灰云）**

## 脚本会做什么

1. 安装 `sing-box`、`certbot` 和 `python3-certbot-dns-cloudflare`
2. 可选地通过 Cloudflare API 创建/更新 A 记录为 DNS only
3. 用 Certbot + Cloudflare DNS 插件签发或复用证书
4. 将证书复制到 `/etc/sing-box/certs/<host>/`
5. 生成 `/etc/sing-box/config.json`
6. 停止旧的 `anytls-go`（可选）
7. 启用并重启 `sing-box`
8. 安装证书 deploy hook，后续续期后自动复制证书并重载 `sing-box`

## 生成的关键文件

- `/etc/sing-box/config.json`
- `/etc/sing-box/certs/<host>/fullchain.pem`
- `/etc/sing-box/certs/<host>/privkey.pem`
- `/root/.secrets/certbot/cloudflare-<zone>.ini`
- `/root/.config/anytls-singbox/<host>.env`

## Shadowrocket 最小配置

- 类型：AnyTLS
- 服务器：脚本里填写的完整域名
- 端口：脚本里填写的端口
- 密码：脚本里填写或自动生成的密码
- SNI / Server Name：同一个完整域名
- Allow Insecure / 跳过证书验证：关闭

## 复用与迁移

脚本支持通过环境变量预填默认值，例如：

```bash
ANYTLS_HOST=sg.example.com \
ANYTLS_ZONE=example.com \
ANYTLS_EMAIL=you@example.com \
ANYTLS_PORT=443 \
ANYTLS_NAME=iphone \
ANYTLS_PASSWORD='yourpassword' \
ANYTLS_SERVER_IPV4='203.0.113.10' \
ANYTLS_CF_TOKEN='cf_token_here' \
bash deploy_anytls_singbox.sh
```
