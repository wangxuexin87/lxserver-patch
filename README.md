# lxserver 一键改造：网页播放器用户名+密码登录

针对 [lxserver](https://github.com/XCQ0607/lxserver)（LX Music 数据同步服务端）的改造脚本。
原生播放器只支持共享密码登录，本项目将其改为**用户名+密码**登录，与客户端同步用同一套账号。

## 一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wangxuexin87/lxserver-patch/main/install.sh | bash
```

幂等，可重复执行。执行后按提示操作即可（加用户步骤可直接回车跳过）。

## 改造内容

| # | 内容 | 说明 |
|---|------|------|
| 1 | 登录页替换 | `login.html`：用户名+密码登录页，替代原生共享密码页；登录后数据同步自动登录；session 失效时静默自动重登 |
| 2 | 后端补丁 | `patch-auth.js`：`POST /api/music/auth` 改为校验 `users.json` 中的用户名+密码；不传用户名时保留共享密码兼容 |
| 3 | 会话持久 | 播放器会话有效期 24 小时 → 30 天 |
| 4 | 移动端禁止缩放 | 播放器 `index.html` 的 viewport 改为 `maximum-scale=1.0, user-scalable=no` |
| 5 | 更新持久化 | 生成 `docker-compose.override.yml`：挂载登录页与补丁脚本，容器每次启动自动打补丁；更新镜像后无需手动操作 |

## 仓库文件

- `install.sh` —— 一键脚本（`login.html` / `patch-auth.js` 已内嵌，开箱即用）
- `login.html` —— 登录页源码（独立文件，方便查看/修改）
- `patch-auth.js` —— 后端补丁源码（独立文件，方便查看/修改）

> 修改 `login.html` / `patch-auth.js` 后，请同步把新内容嵌回 `install.sh`
> 对应 heredoc 段（`__LX_LOGIN_HTML__` / `__LX_PATCH_AUTH_JS__` 之间）。

## 日常维护

- **加用户**：管理后台 → 用户管理，实时生效，无需重启
- **更新镜像**：在 compose 目录下 `docker compose pull` + `docker compose up -d` 即可，补丁自动重打
- **恢复官方默认**：删除 `docker-compose.override.yml` 后重建容器

## 回滚

- 登录页：容器内 `/server/public/music/login.html.bak`
- 后端：容器内 `/server/server/server/server.js.bak`（实际路径以补丁日志为准）
- 播放器页面：容器内 `/server/public/music/index.html.bak`

回滚后执行 `docker restart <容器名>`。
