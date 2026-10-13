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
// v2.1.3+ 官方已原生支持用户名+密码双模式登录，跳过此补丁
if (src.includes('const { password, username, mode } = JSON.parse(body)')) {
  console.log('检测到 v2.1.3+ 原生用户名密码登录，跳过认证补丁。')
} else if (src.includes('const { password, username } = JSON.parse(body)')) {
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
