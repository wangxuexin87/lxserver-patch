#!/usr/bin/env bash
# ============================================================
# lxserver 一键改造脚本
#
# 功能（一次执行，全部搞定）：
#   1. 网页播放器改成「用户名+密码」登录（替换原登录页）
#   2. 后端 /api/music/auth 补丁：用 users.json 的账号密码校验
#   3. 登录后数据同步自动登录（无需二次登录）
#   4. 会话有效期 24 小时 → 30 天；session 失效时静默自动重登
#   5. 持久化：更新镜像后自动重打补丁（docker-compose.override.yml）
#   6. 可选：批量添加用户
#
# 用法（任选一种）：
#   curl -fsSL https://raw.githubusercontent.com/wangxuexin87/lxserver-patch/main/install.sh | bash
#   或：下载后 bash install.sh
#
# 说明：
#   - 单文件，login.html / patch-auth.js 已内嵌，无需额外下载
#   - 幂等，可重复执行；原文件会自动备份（.bak，仅第一次）
#   - 用户数据在 ./data 卷里，不会丢失
# ============================================================
set -uo pipefail

CONTAINER="${CONTAINER:-lx-sync-server}"

say() { echo "==> $*"; }
die() { echo "!! $*"; exit 1; }
# 支持 curl | bash：交互输入一律走 /dev/tty
ask() {
  printf "%s" "$1" > /dev/tty
  IFS= read -r REPLY < /dev/tty || true
  printf "%s" "$REPLY"
}

say "步骤 1/7：检查环境"
command -v docker >/dev/null 2>&1 || die "找不到 docker，请先安装"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || die "容器 $CONTAINER 未在运行（可用 CONTAINER=xxx 指定容器名）"
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  die "找不到 docker compose"
fi
echo "    容器 $CONTAINER 运行中"

say "步骤 2/7：定位 compose 目录"
CFG=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
SERVICE=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)
PROJECT=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
[ "$SERVICE" = "<no value>" ] && SERVICE=""
[ "$PROJECT" = "<no value>" ] && PROJECT=""
[ -z "$SERVICE" ] && SERVICE="lx-sync-server"

DIR=""
if [ -n "${CFG:-}" ] && [ "$CFG" != "<no value>" ]; then
  DIR=$(dirname "$(echo "$CFG" | cut -d, -f1)")
fi
if [ -z "${DIR:-}" ] || [ ! -d "$DIR" ]; then
  echo "    自动定位失败，请输入 docker-compose.yml 所在的目录："
  DIR=$(ask "    目录> ")
  [ -d "${DIR:-}" ] || die "目录不存在：${DIR:-}"
fi
say "Compose 目录：$DIR（服务名：$SERVICE）"
cd "$DIR" || die "无法进入目录"

say "步骤 3/7：写入 login.html 和 patch-auth.js"
cat > "$DIR/login.html" <<'__LX_LOGIN_HTML__'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>LX Music Web - 登录</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    background: #0f1420;
    color: #e8ecf4;
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    background-image:
      radial-gradient(ellipse 80% 60% at 20% 10%, rgba(64, 120, 255, 0.14), transparent),
      radial-gradient(ellipse 70% 55% at 85% 85%, rgba(150, 80, 255, 0.12), transparent),
      radial-gradient(ellipse 50% 40% at 60% 40%, rgba(0, 200, 180, 0.06), transparent);
    padding: 20px;
  }
  .card {
    width: 100%;
    max-width: 380px;
    background: rgba(22, 28, 44, 0.82);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 20px;
    padding: 44px 36px 36px;
    box-shadow: 0 24px 70px rgba(0, 0, 0, 0.5);
    animation: rise 0.5s ease both;
  }
  @keyframes rise {
    from { opacity: 0; transform: translateY(18px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .logo {
    width: 64px; height: 64px;
    margin: 0 auto 18px;
    border-radius: 18px;
    background: linear-gradient(135deg, #3b82f6, #8b5cf6);
    display: flex; align-items: center; justify-content: center;
    font-size: 30px;
    box-shadow: 0 8px 24px rgba(99, 102, 241, 0.45);
  }
  h1 { text-align: center; font-size: 22px; font-weight: 600; letter-spacing: 1px; }
  .sub { text-align: center; font-size: 13px; color: #8b94a9; margin: 8px 0 28px; }
  .field { margin-bottom: 16px; }
  .field label {
    display: block; font-size: 13px; color: #9aa3b8; margin-bottom: 7px;
  }
  .field input {
    width: 100%;
    padding: 13px 15px;
    font-size: 15px;
    color: #eef1f7;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 12px;
    outline: none;
    transition: border-color 0.2s, box-shadow 0.2s, background 0.2s;
  }
  .field input::placeholder { color: #5b6478; }
  .field input:focus {
    border-color: #5b8cff;
    background: rgba(255, 255, 255, 0.09);
    box-shadow: 0 0 0 3px rgba(91, 140, 255, 0.18);
  }
  .btn {
    width: 100%;
    margin-top: 10px;
    padding: 14px;
    font-size: 16px;
    font-weight: 600;
    letter-spacing: 4px;
    color: #fff;
    background: linear-gradient(135deg, #3b82f6, #8b5cf6);
    border: none;
    border-radius: 12px;
    cursor: pointer;
    transition: transform 0.15s, box-shadow 0.2s, opacity 0.2s;
    box-shadow: 0 8px 22px rgba(99, 102, 241, 0.35);
  }
  .btn:hover:not(:disabled) { transform: translateY(-1px); box-shadow: 0 12px 28px rgba(99, 102, 241, 0.45); }
  .btn:active:not(:disabled) { transform: translateY(0); }
  .btn:disabled { opacity: 0.65; cursor: not-allowed; }
  .error {
    display: none;
    margin-top: 14px;
    padding: 10px 14px;
    font-size: 13px;
    color: #ff8f8f;
    background: rgba(255, 90, 90, 0.1);
    border: 1px solid rgba(255, 90, 90, 0.25);
    border-radius: 10px;
    text-align: center;
  }
  .error.show { display: block; animation: shake 0.35s ease; }
  @keyframes shake {
    0%, 100% { transform: translateX(0); }
    25% { transform: translateX(-6px); }
    50% { transform: translateX(6px); }
    75% { transform: translateX(-4px); }
  }
  .hint {
    margin-top: 22px;
    text-align: center;
    font-size: 12px;
    color: #5f6880;
  }
  .autobar {
    display: none;
    margin-bottom: 16px;
    padding: 10px 14px;
    font-size: 13px;
    color: #9fc1ff;
    background: rgba(91, 140, 255, 0.1);
    border: 1px solid rgba(91, 140, 255, 0.25);
    border-radius: 10px;
    text-align: center;
  }
  .autobar.show { display: block; }
  .autobar button {
    margin-left: 8px;
    padding: 2px 10px;
    font-size: 12px;
    color: #9fc1ff;
    background: transparent;
    border: 1px solid rgba(91, 140, 255, 0.4);
    border-radius: 8px;
    cursor: pointer;
  }
  .spinner {
    display: inline-block;
    width: 16px; height: 16px;
    border: 2px solid rgba(255,255,255,0.35);
    border-top-color: #fff;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    vertical-align: -3px;
    margin-right: 6px;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
  <div class="card">
    <div class="logo">🎵</div>
    <h1>LX Music Web</h1>
    <p class="sub">请输入账号与密码以访问播放器</p>
    <div class="autobar" id="autoBar">
      <span class="spinner"></span>正在自动登录…
      <button type="button" id="autoCancel">取消</button>
    </div>
    <form id="loginForm" autocomplete="on">
      <div class="field">
        <label for="username">用户名</label>
        <input id="username" name="username" type="text" placeholder="请输入用户名"
               autocomplete="username" autofocus>
      </div>
      <div class="field">
        <label for="password">密码</label>
        <input id="password" name="password" type="password" placeholder="请输入密码"
               autocomplete="current-password">
      </div>
      <button class="btn" type="submit" id="submitBtn">登 录</button>
      <div class="error" id="errorBox"></div>
    </form>
    <p class="hint">还没有账号？请联系管理员开通</p>
  </div>

<script>
(function () {
  var form = document.getElementById('loginForm');
  var userInput = document.getElementById('username');
  var pwdInput = document.getElementById('password');
  var btn = document.getElementById('submitBtn');
  var errorBox = document.getElementById('errorBox');
  var autoBar = document.getElementById('autoBar');
  var autoCancelled = false;

  // 登录页所在路径的前缀即播放器路径：/login -> / ；/music/login -> /music/
  var base = location.pathname.replace(/\/?login(\.html)?\/?$/, '');
  var playerHome = (base === '' ? '/' : base + '/');

  function showError(msg) {
    errorBox.textContent = msg;
    errorBox.classList.remove('show');
    void errorBox.offsetWidth; // 重启动画
    errorBox.classList.add('show');
  }
  function hideError() { errorBox.classList.remove('show'); }
  function setLoading(loading) {
    btn.disabled = loading;
    btn.innerHTML = loading ? '<span class="spinner"></span>登录中' : '登 录';
  }

  // 已登录则直接进播放器；未开启认证也直接进
  fetch('/api/music/config', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (cfg) {
    if (!cfg['player.enableAuth']) { location.replace(playerHome); return; }
    return fetch('/api/music/auth/verify', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      if (d && d.valid) { location.replace(playerHome); return; }
      tryAutoLogin(); // 会话失效时，用记住的账号静默重登
    });
  }).catch(function () {});

  document.getElementById('autoCancel').addEventListener('click', function () {
    autoCancelled = true;
    autoBar.classList.remove('show');
    setLoading(false);
  });

  function getStoredCreds() {
    try {
      var u = localStorage.getItem('lx_sync_user');
      var p = localStorage.getItem('lx_sync_pass');
      if (u && p) return { username: u, password: p };
    } catch (e) {}
    return null;
  }

  // 预取同步 Token，让播放器打开即恢复会话；失败也不影响，播放器会用存下的账号自动登录
  function refreshSyncToken(creds) {
    return fetch('/api/user/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: creds.username, password: creds.password })
    }).then(function (r) { return r.json(); }).then(function (t) {
      if (t && t.success && t.token) {
        try { localStorage.setItem('lx_user_token', t.token); } catch (e) {}
      }
    }).catch(function () {});
  }

  // 静默自动登录：session 过期/容器重启后，用户无感恢复登录态
  function tryAutoLogin() {
    var creds = getStoredCreds();
    if (!creds || autoCancelled) return;
    autoBar.classList.add('show');
    setLoading(true);
    btn.innerHTML = '<span class="spinner"></span>自动登录中';
    setTimeout(function () {
      if (autoCancelled) return;
      fetch('/api/music/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: creds.username, password: creds.password })
      }).then(function (r) { return r.json(); }).then(function (d) {
        if (autoCancelled) return;
        if (d && d.success) {
          refreshSyncToken(creds);
          setTimeout(function () {
            if (!autoCancelled) location.replace(playerHome);
          }, 400);
        } else {
          // 记住的密码失效了（比如管理员改了密码）：清掉，停在表单让用户重输
          try {
            localStorage.removeItem('lx_sync_pass');
            localStorage.removeItem('lx_user_token');
          } catch (e) {}
          autoBar.classList.remove('show');
          setLoading(false);
          userInput.value = creds.username;
          showError('已记住的账号失效，请重新登录');
        }
      }, function () {
        if (autoCancelled) return;
        autoBar.classList.remove('show');
        setLoading(false);
      });
    }, 700);
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    hideError();
    var username = userInput.value.trim();
    var password = pwdInput.value;
    if (!password) { showError('请输入密码'); pwdInput.focus(); return; }
    if (!username) { showError('请输入用户名'); userInput.focus(); return; }
    setLoading(true);
    fetch('/api/music/auth', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: username, password: password })
    }).then(function (r) { return r.json(); }).then(function (d) {
      setLoading(false);
      if (d && d.success) {
        // 把同一套账号写入播放器的数据同步登录态，进播放器后自动登录同步
        try {
          localStorage.setItem('lx_sync_mode', 'local');
          localStorage.setItem('lx_sync_user', username);
          localStorage.setItem('lx_sync_pass', password);
        } catch (e) {}
        // 预取同步 Token，让播放器打开即恢复会话；
        // 即使失败也不影响，播放器会用上面存下的账号自动登录
        var tokenDone = false;
        function goPlayer() {
          if (!tokenDone) { tokenDone = true; location.replace(playerHome); }
        }
        refreshSyncToken({ username: username, password: password }).then(goPlayer, goPlayer);
        setTimeout(goPlayer, 1500); // 兜底：1.5 秒没回来也进播放器
      } else {
        showError('用户名或密码错误，请重试');
        pwdInput.select();
      }
    }).catch(function () {
      setLoading(false);
      showError('网络错误，请稍后重试');
    });
  });
})();
</script>
</body>
</html>
__LX_LOGIN_HTML__
cat > "$DIR/patch-auth.js" <<'__LX_PATCH_AUTH_JS__'
// patch-auth.js
// 用法（在宿主机上执行）：
//   docker cp patch-auth.js <容器名>:/tmp/patch-auth.js
//   docker exec <容器名> node /tmp/patch-auth.js [/path/to/server.js]
//   docker restart <容器名>
//
// 作用：
// 1. 给 lxserver 的 POST /api/music/auth 打上"用户名+密码"补丁。
//    - 传了 username：到用户列表(users)里校验用户名+密码
//    - 没传 username：保持原来的共享密码逻辑不变
// 2. 播放器会话有效期从 24 小时延长到 30 天（配合登录页静默重登，基本无感）
// 3. 播放器 index.html 的 viewport 改为禁止缩放（手机浏览器不再自动放大）
// 原文件会自动备份为 server.js.bak / index.html.bak（同目录，仅第一次备份）

const fs = require('fs')

// 自动定位编译后的 server.js（不同版本镜像目录结构可能不同）
const candidates = [
  process.argv[2],
  '/server/server/server/server.js',
  '/server/server/server.js',
  '/server/dist/server.js',
  '/app/server/server.js',
  '/app/dist/server.js',
].filter(Boolean)
const FILE = candidates.find(f => {
  try { return fs.existsSync(f) } catch { return false }
})
if (!FILE) {
  console.error('找不到编译后的 server.js，尝试过的路径：' + candidates.join(', '))
  console.error('请手动查找后作为参数传入：docker exec <容器名> node /tmp/patch-auth.js /实际路径/server.js')
  process.exit(1)
}
console.log('目标文件：' + FILE)

let src = fs.readFileSync(FILE, 'utf8')
let needWrite = false
const count = (s, sub) => s.split(sub).length - 1

// ---------- 补丁 1：用户名+密码登录 ----------
if (src.includes('const { password, username } = JSON.parse(body)')) {
  console.log('登录补丁已打过，跳过。')
} else {

// 目标代码段（播放器认证接口内，correctPassword + player.password 的组合是唯一的，
// 不会误伤管理后台 /api/login 那处）。
// 宽松匹配：兼容不同构建版本（分号/缩进/引号/log4js_1 前缀可能不同）
const re = /const\s*\{\s*password\s*\}\s*=\s*JSON\.parse\s*\(\s*body\s*\)\s*;?\s*\n(\s*)const\s+correctPassword\s*=\s*global\.lx\.config\s*\[\s*['"]player\.password['"]\s*\]\s*\|\|\s*['"]{2}\s*;?\s*\n\s*if\s*\(\s*password\s*===\s*correctPassword\s*\)\s*\{/
const allMatches = [...src.matchAll(new RegExp(re.source, 'g'))]
if (allMatches.length !== 1) {
  console.error('目标代码段数量异常（找到 ' + allMatches.length + ' 处），补丁失败。请把情况反馈以便适配。')
  process.exit(1)
}
const indent = allMatches[0][1] // 与原文保持一致的缩进
const inner = indent + '    '

// 补丁代码沿用目标文件的分号风格
const replacement =
  'const { password, username } = JSON.parse(body);\n' +
  indent + '// 用户名+密码模式：到用户列表里校验（管理后台 /admin → 用户管理）\n' +
  indent + 'let authed = false;\n' +
  indent + "let who = '';\n" +
  indent + 'if (username) {\n' +
  inner + 'const user = (global.lx.config.users || []).find((u) => u.name === username && u.password === password);\n' +
  inner + 'if (user) { authed = true; who = username; }\n' +
  indent + '} else {\n' +
  inner + '// 兼容旧逻辑：只传密码时走共享访问密码\n' +
  inner + "const correctPassword = global.lx.config['player.password'] || '';\n" +
  inner + "if (password === correctPassword) { authed = true; who = '(shared)'; }\n" +
  indent + '}\n' +
  indent + 'if (authed) {'

src = src.replace(re, replacement)

// 日志里带上用户名，方便以后排查登录问题（按日志内容匹配，不依赖 loginLog 前缀写法）
const ok1 = count(src, 'Player login success from ${ip}') === 1
const ok2 = count(src, 'Player login failed from ${ip}') === 1
if (!ok1 || !ok2) {
  console.error('日志行数量异常，补丁失败。')
  process.exit(1)
}
src = src.split('Player login success from ${ip}').join('Player login success: ${who} from ${ip}')
src = src.split('Player login failed from ${ip}').join("Player login failed: ${username || '(shared)'} from ${ip}")
needWrite = true
console.log('登录补丁已应用。')
}

// ---------- 补丁 2：播放器会话有效期 24 小时 -> 30 天 ----------
// 浏览器关久了 session 过期就要重登；延长后配合登录页的静默重登，基本无感
const ttlOld = /const\s+SESSION_TTL\s*=\s*24\s*\*\s*60\s*\*\s*60\s*\*\s*1000/
const ttlNew = /const\s+SESSION_TTL\s*=\s*30\s*\*\s*24\s*\*\s*60\s*\*\s*60\s*\*\s*1000/
if (ttlNew.test(src)) {
  console.log('会话有效期已是 30 天，跳过。')
} else if (ttlOld.test(src)) {
  src = src.replace(ttlOld, 'const SESSION_TTL = 30 * 24 * 60 * 60 * 1000')
  needWrite = true
  console.log('会话有效期已延长为 30 天。')
} else {
  console.log('未找到 SESSION_TTL 定义，跳过有效期延长（不影响登录补丁）。')
}

// ---------- 补丁 3：播放器 index.html 禁止移动端缩放 ----------
// 播放器页面的 viewport 默认允许缩放，手机浏览器会自动放大；改成禁止缩放
const idxCandidates = [
  '/server/public/music/index.html',
  '/server/public/index.html',
  '/app/public/music/index.html',
].filter(f => { try { return fs.existsSync(f) } catch { return false } })
const IDX = idxCandidates[0]
const viewportOld = '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
const viewportNew = '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">'
if (!IDX) {
  console.log('未找到播放器 index.html，跳过 viewport 修改（不影响其他补丁）。')
} else {
  let html = fs.readFileSync(IDX, 'utf8')
  if (html.includes(viewportNew)) {
    console.log('index.html viewport 已是禁止缩放，跳过。')
  } else if (html.includes(viewportOld)) {
    html = html.split(viewportOld).join(viewportNew)
    if (!fs.existsSync(IDX + '.bak')) fs.copyFileSync(IDX, IDX + '.bak')
    fs.writeFileSync(IDX, html)
    console.log('index.html viewport 已修改为禁止缩放。')
  } else {
    console.log('index.html 中未找到目标 viewport，跳过（不影响其他补丁）。')
  }
}

// ---------- 写回 ----------
if (!needWrite) {
  console.log('无需任何修改。')
  process.exit(0)
}
// 只在第一次备份，保留最原始的文件用于回滚
if (!fs.existsSync(FILE + '.bak')) fs.copyFileSync(FILE, FILE + '.bak')
fs.writeFileSync(FILE, src)
console.log('补丁成功！原文件已备份为 ' + FILE + '.bak')
console.log('请执行 docker restart <容器名> 重启容器使补丁生效')
__LX_PATCH_AUTH_JS__
echo "    写入完成"

say "步骤 4/7：生成 docker-compose.override.yml（持久化）"
OVERRIDE="$DIR/docker-compose.override.yml"
if [ -f "$OVERRIDE" ] && grep -q "patch-auth.js" "$OVERRIDE" 2>/dev/null; then
  echo "    已存在，跳过"
else
  {
    echo "# 自动生成：lxserver 用户名+密码登录持久化"
    echo "# 用途：挂载 login.html / patch-auth.js，容器每次启动自动打补丁"
    echo "# 删除此文件并重建容器，即恢复官方默认行为"
    echo "services:"
    echo "  $SERVICE:"
    echo "    volumes:"
    echo "      - ./login.html:/server/public/music/login.html:ro"
    echo "      - ./patch-auth.js:/patch/patch-auth.js:ro"
    echo '    command: ["sh", "-c", "node /patch/patch-auth.js && node index.js"]'
  } > "$OVERRIDE" || die "写入 override 文件失败"
  echo "    已生成 $OVERRIDE"
fi

say "步骤 5/7：添加用户（可选）"
echo "    已在管理后台建好用户可直接回车跳过。"
echo "    如需添加，一行一个，格式：用户名 密码（空格隔开），空行结束。"
WORKDIR_TMP=$(mktemp -d)
: > "$WORKDIR_TMP/users.txt"
while true; do
  line=$(ask "    用户> ")
  [ -z "$line" ] && break
  echo "$line" >> "$WORKDIR_TMP/users.txt"
done
if [ -s "$WORKDIR_TMP/users.txt" ]; then
  docker exec -i "$CONTAINER" node -e '
const fs = require("fs");
const p = "/server/data/users.json";
let users = null;
try {
  const raw = fs.readFileSync(p, "utf8");
  users = JSON.parse(raw);
  if (!Array.isArray(users)) throw new Error("users.json 不是数组");
} catch (e) {
  if (e.code === "ENOENT") {
    try {
      const cfg = require("/server/data/config.js");
      users = Array.isArray(cfg.users) ? cfg.users.map(u => ({ ...u })) : [];
      console.log("    users.json 不存在，已从 config.js 载入 " + users.length + " 个已有用户");
    } catch (e2) {
      console.error("    !! 无法读取 config.js，已中止，未做任何修改");
      process.exit(1);
    }
  } else {
    console.error("    !! users.json 读取失败(" + e.message + ")，已中止，未做任何修改。请先手动检查该文件。");
    process.exit(1);
  }
}
const seen = new Set(users.map(u => u.name));
let added = 0, data = "";
process.stdin.on("data", d => data += d).on("end", () => {
  for (const line of data.split("\n")) {
    const t = line.trim(); if (!t) continue;
    const sp = t.indexOf(" ");
    if (sp < 0) { console.log("    跳过格式错误: " + t); continue; }
    const name = t.slice(0, sp), password = t.slice(sp + 1).trim();
    if (!name || !password) { console.log("    跳过格式错误: " + t); continue; }
    if (seen.has(name)) { console.log("    已存在，跳过: " + name); continue; }
    users.push({ name, password, maxSnapshotNum: 10, "list.addMusicLocationType": "top",
      enableCustomMusicDir: false, customMusicDir: "", allowOperateCustomMusicDir: false,
      allowWriteCustomMusicDir: false, enableAutoDownload: false });
    seen.add(name); added++;
    console.log("    已添加: " + name);
  }
  fs.writeFileSync(p, JSON.stringify(users, null, 2));
  console.log("    共新增 " + added + " 个用户");
});
' < "$WORKDIR_TMP/users.txt" || die "写入用户失败"
else
  echo "    跳过添加用户"
fi
rm -rf "$WORKDIR_TMP"

say "步骤 6/7：重建容器（应用全部修改）"
# 镜像版本默认用 latest，避免 compose 文件里写死旧版本
COMPOSE_FILE=""
if [ -f "$DIR/docker-compose.yml" ]; then COMPOSE_FILE="$DIR/docker-compose.yml"
elif [ -f "$DIR/docker-compose.yaml" ]; then COMPOSE_FILE="$DIR/docker-compose.yaml"
fi
if [ -n "$COMPOSE_FILE" ]; then
  IMG_LINE=$(grep -m1 -E '^\s*image:\s*xcq0607/lxserver' "$COMPOSE_FILE" || true)
  if [ -n "$IMG_LINE" ]; then
    case "$IMG_LINE" in
      *":latest"*) echo "    镜像已是 latest，跳过" ;;
      *)
        [ -f "$COMPOSE_FILE.bak" ] || cp "$COMPOSE_FILE" "$COMPOSE_FILE.bak"
        sed -i -E 's|^(\s*image:\s*xcq0607/lxserver)(:[^[:space:]#]+)?|\1:latest|' "$COMPOSE_FILE"
        echo "    镜像版本已更新为 latest（原文件备份为 $(basename "$COMPOSE_FILE").bak）"
        ;;
    esac
  fi
fi
ARGS=""
if [ -n "${CFG:-}" ] && [ "$CFG" != "<no value>" ]; then
  for f in $(echo "$CFG" | tr ',' ' '); do
    case "$f" in *override*) continue ;; esac
    ARGS="$ARGS -f $f"
  done
else
  if [ -f "$DIR/docker-compose.yml" ]; then ARGS="-f $DIR/docker-compose.yml"
  elif [ -f "$DIR/docker-compose.yaml" ]; then ARGS="-f $DIR/docker-compose.yaml"
  fi
fi
[ -n "${PROJECT:-}" ] && ARGS="-p $PROJECT $ARGS"
ARGS="$ARGS -f $OVERRIDE"
# shellcheck disable=SC2086
$COMPOSE $ARGS up -d --force-recreate || die "容器重建失败"

say "步骤 7/7：验证"
echo "    等待服务启动..."
ok_patch=0; ok_ttl=0; ok_page=0
for _ in $(seq 1 12); do
  sleep 5
  ST=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo "?")
  [ "$ST" = "running" ] || { echo "    容器状态：$ST，继续等待..."; continue; }
  SRV=$(docker exec "$CONTAINER" sh -c 'for f in /server/server/server/server.js /server/server/server.js /server/dist/server.js /app/server/server.js; do [ -f "$f" ] && { echo "$f"; break; }; done' 2>/dev/null || true)
  [ -z "$SRV" ] && { echo "    等待服务端文件..."; continue; }
  docker exec "$CONTAINER" grep -q "password, username" "$SRV" 2>/dev/null && ok_patch=1
  docker exec "$CONTAINER" grep -q "SESSION_TTL = 30" "$SRV" 2>/dev/null && ok_ttl=1
  docker exec "$CONTAINER" grep -q "tryAutoLogin" /server/public/music/login.html 2>/dev/null && ok_page=1
  [ "$ok_patch" = "1" ] && [ "$ok_page" = "1" ] && break
  echo "    等待补丁生效..."
done
[ "$ok_patch" = "1" ] && echo "    [OK] 用户名+密码登录补丁已生效" || die "登录补丁验证失败，请检查：docker logs $CONTAINER"
[ "$ok_ttl" = "1" ] && echo "    [OK] 会话有效期已延长为 30 天" || echo "    [--] 会话有效期延长未匹配到（不影响登录，可能是上游改了代码）"
[ "$ok_page" = "1" ] && echo "    [OK] 新版登录页已挂载（含自动同步登录）" || die "登录页验证失败"

echo ""
echo "================ 完成 ================"
echo "访问你的播放器地址，用用户名+密码登录一次即可。"
echo ""
echo "已实现的效果："
echo "  - 网页播放器用户名+密码登录（与客户端同步同一套账号）"
echo "  - 登录后数据同步自动登录，无需二次登录"
echo "  - 会话 30 天有效；过期后打开网站自动静默重登"
echo "  - 更新镜像后补丁自动重打，无需手动操作"
echo ""
echo "日常维护："
echo "  - 加用户：管理后台 → 用户管理（实时生效，无需重启）"
echo "  - 更新镜像：在 $DIR 下 pull + up -d 即可"
echo "  - 恢复官方默认：删除 $OVERRIDE 后重建容器"
echo "======================================="
