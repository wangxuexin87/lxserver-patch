# lxserver 一键改造：会话持久化 + 移动端优化

针对 [lxserver](https://github.com/XCQ0607/lxserver)（LX Music 数据同步服务端）的增强脚本。

> **v2.1.3+ 说明**：上游已原生支持用户名+密码双模式登录和静默自动重登，本项目不再替换登录页和认证逻辑，仅保留会话持久化和移动端优化。旧版本（v2.1.2 及以下）仍走全套补丁。

## 一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wangxuexin87/lxserver-patch/main/install.sh | bash
```

幂等，可重复执行。执行后按提示操作即可（加用户步骤可直接回车跳过）。每次执行会自动拉取上游最新镜像。

## 改造内容

| # | 内容 | 说明 |
|---|------|------|
| 1 | 会话持久 | 播放器会话有效期 24 小时 → 30 天 |
| 2 | 移动端禁止缩放 | 播放器 `index.html` 的 viewport 改为 `maximum-scale=1.0, user-scalable=no` |
| 3 | 自动更新 | 每次执行先 `docker pull` 拉取上游最新镜像，再重建容器 |
| 4 | 更新持久化 | 生成 `docker-compose.override.yml`：挂载补丁脚本，容器每次启动自动打补丁；更新镜像后无需手动操作 |

### 旧版本（v2.1.2 及以下）额外补丁

| # | 内容 | 说明 |
|---|------|------|
| 5 | 登录页替换 | `login.html`：用户名+密码登录页，替代原生共享密码页；登录后数据同步自动登录；session 失效时静默自动重登 |
| 6 | 后端补丁 | `patch-auth.js`：`POST /api/music/auth` 改为校验 `users.json` 中的用户名+密码；不传用户名时保留共享密码兼容 |

> v2.1.3+ 检测到原生登录支持时，自动跳过 5、6，使用官方登录页和认证逻辑。

## 仓库文件

- `install.sh` —— 一键脚本（`login.html` / `patch-auth.js` 已内嵌，开箱即用）
- `login.html` —— 登录页源码（仅旧版本使用，v2.1.3+ 不再覆盖）
- `patch-auth.js` —— 后端补丁源码（独立文件，方便查看/修改）

> 修改 `login.html` / `patch-auth.js` 后，请同步把新内容嵌回 `install.sh`
> 对应 heredoc 段（`__LX_LOGIN_HTML__` / `__LX_PATCH_AUTH_JS__` 之间）。

## 日常维护

- **加用户**：管理后台 → 用户管理，实时生效，无需重启
- **更新镜像**：重新跑一键脚本即可（自动 pull + 重打补丁）
- **恢复官方默认**：删除 `docker-compose.override.yml` 后重建容器

## 回滚

- 登录页：容器内 `/server/public/music/login.html.bak`（仅旧版本）
- 后端：容器内 `/server/server/server/server.js.bak`（实际路径以补丁日志为准）
- 播放器页面：容器内 `/server/public/music/index.html.bak`

回滚后执行 `docker restart <容器名>`。
