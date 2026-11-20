/**
 * AIStudio2API for SillyTavern - 服务端插件
 *
 * 在酒馆里管理 AIStudio2API 官方命令行版：首次启动时下载，面板手动启动/停止，
 * 意外退出自动重启，酒馆关闭时一起关闭。不修改上游程序。
 *
 * 路由挂在 /api/plugins/aistudio2api/ 下：
 *   GET  status   运行状态、版本、进度
 *   POST start    启动（没有程序时先下载）
 *   POST stop     停止
 *   POST update   下载最新版（需先停止）
 *   GET  logs     最近的程序输出
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const http = require('http');
const { spawn, execFileSync } = require('child_process');
const { Readable } = require('stream');
const { pipeline } = require('stream/promises');

// 上游在前；上游删库或停更时用备份 fork（由 tools/mirror-upstream.sh 每天同步）
const SOURCES = ['Mag1cFall/AIStudio2API', 'shleeshlee/AIStudio2API'];
// 程序目录：环境变量 > 安装脚本记下的独立安装目录（~/.aistudio2api-tavern）> 默认 ~/aistudio2api
function resolveAppDir() {
    if (process.env.AISTUDIO2API_HOME) return process.env.AISTUDIO2API_HOME;
    try {
        const linked = fs.readFileSync(path.join(os.homedir(), '.aistudio2api-tavern'), 'utf8')
            .replace(/^﻿/, '').split(/\r?\n/)[0].trim();
        if (linked && fs.existsSync(linked)) return linked;
    } catch { /* 没有指向独立安装 */ }
    return path.join(os.homedir(), 'aistudio2api');
}
const APP_DIR = resolveAppDir();
const BIN_NAME = process.platform === 'win32' ? 'aistudio2api.exe' : 'aistudio2api';
const BIN_PATH = path.join(APP_DIR, BIN_NAME);
const VERSION_FILE = path.join(APP_DIR, '.termux-version'); // 与 Termux 直装脚本共用
const PORT = Number(process.env.AISTUDIO2API_PORT) || 2048;
// 管理页面自带防嵌入（X-Frame-Options: DENY），酒馆弹窗通过这个本机转接口加载它
const UI_PORT = Number(process.env.AISTUDIO2API_UI_PORT) || 2052;
const LOG_LIMIT = 300;
const MAX_RESTARTS = 3;

const IS_TERMUX = Boolean(process.env.PREFIX && process.env.PREFIX.includes('com.termux'));

const state = {
    status: 'stopped', // stopped | downloading | starting | running | stopping | external | error
    message: '',
    progress: null, // 下载进度 0-100
    child: null,
    wantRunning: false,
    restarts: 0,
    logs: [],
};

function log(line) {
    const text = String(line).replace(/\x1b\[[0-9;]*m/g, '').trimEnd();
    if (!text) return;
    for (const l of text.split('\n')) {
        state.logs.push(prettyLine(l));
    }
    if (state.logs.length > LOG_LIMIT) state.logs.splice(0, state.logs.length - LOG_LIMIT);
}

// 上游输出是 JSON 日志行，整理成「时间 级别 内容」方便在面板里看
function prettyLine(line) {
    if (!line.startsWith('{')) return line;
    try {
        const o = JSON.parse(line);
        const time = String(o.time || '').slice(11, 19);
        const extra = o.error || (o.request && o.request.error) || o.addr || '';
        return [time, o.level, o.msg, extra].filter(Boolean).join(' ');
    } catch {
        return line;
    }
}

function setStatus(status, message = '') {
    state.status = status;
    state.message = message;
    if (message) log(`[插件] ${message}`);
}

function installedVersion() {
    try {
        return fs.readFileSync(VERSION_FILE, 'utf8').trim() || null;
    } catch {
        return fs.existsSync(BIN_PATH) ? 'unknown' : null;
    }
}

function assetName(tag) {
    const arch = { arm64: 'arm64', x64: 'amd64' }[process.arch];
    if (!arch) throw new Error(`不支持的 CPU 架构：${process.arch}`);
    if (process.platform === 'linux') return `aistudio2api-${tag}-linux-${arch}`;
    if (process.platform === 'darwin') return `aistudio2api-${tag}-darwin-${arch}`;
    if (process.platform === 'win32') {
        if (arch !== 'amd64') throw new Error('上游只发布 64 位 x86 的 Windows 版');
        return `aistudio2api-${tag}-windows-amd64`;
    }
    throw new Error(`不支持的系统：${process.platform}`);
}

const IS_WINDOWS = process.platform === 'win32';
// 上游 Windows 只发桌面版 zip（托盘程序，不往控制台输出），其他系统是命令行版 tar.gz
const ARCHIVE_EXT = IS_WINDOWS ? '.zip' : '.tar.gz';

function portInUse(port) {
    return new Promise((resolve) => {
        const socket = net.connect({ host: '127.0.0.1', port });
        socket.setTimeout(800);
        socket.once('connect', () => { socket.destroy(); resolve(true); });
        socket.once('timeout', () => { socket.destroy(); resolve(false); });
        socket.once('error', () => resolve(false));
    });
}

async function latestTag() {
    // 读 releases/latest 的跳转地址，不走 GitHub API（无限流）；上游不行换备份
    const errors = [];
    for (const source of SOURCES) {
        try {
            const res = await fetch(`https://github.com/${source}/releases/latest`, { redirect: 'manual' });
            const match = (res.headers.get('location') || '').match(/\/tag\/([^/?#]+)/);
            if (match) {
                if (source !== SOURCES[0]) log(`[插件] 上游不可用，改用备份 ${source}`);
                return match[1];
            }
            errors.push(`${source} HTTP ${res.status}`);
        } catch (err) {
            errors.push(`${source} ${err.message}`);
        }
    }
    throw new Error(`查不到最新版本（${errors.join('；')}）`);
}

async function fetchRelease(tag, name) {
    const errors = [];
    for (const source of SOURCES) {
        const url = `https://github.com/${source}/releases/download/${tag}/${name}${ARCHIVE_EXT}`;
        try {
            const res = await fetch(url);
            if (res.ok && res.body) {
                if (source !== SOURCES[0]) log(`[插件] 从备份 ${source} 下载`);
                return res;
            }
            errors.push(`${source} HTTP ${res.status}`);
        } catch (err) {
            errors.push(`${source} ${err.message}`);
        }
    }
    throw new Error(`下载失败（${errors.join('；')}）`);
}

async function download(tag) {
    const name = assetName(tag);
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'aistudio2api-'));
    const archive = path.join(tmpDir, `pkg${ARCHIVE_EXT}`);
    try {
        setStatus('downloading', `下载 ${tag}`);
        state.progress = 0;
        const res = await fetchRelease(tag, name);
        const total = Number(res.headers.get('content-length')) || 0;
        let received = 0;
        const body = Readable.fromWeb(res.body);
        body.on('data', (chunk) => {
            received += chunk.length;
            if (total) state.progress = Math.floor((received / total) * 100);
        });
        await pipeline(body, fs.createWriteStream(archive));

        // Windows 10 起自带的 tar.exe 能解 zip
        execFileSync('tar', IS_WINDOWS ? ['-xf', archive, '-C', tmpDir] : ['-xzf', archive, '-C', tmpDir]);
        const extracted = path.join(tmpDir, name, BIN_NAME);
        if (!fs.existsSync(extracted)) throw new Error('压缩包里没有 aistudio2api，上游包结构可能变了');

        fs.mkdirSync(APP_DIR, { recursive: true });
        fs.copyFileSync(extracted, BIN_PATH);
        fs.chmodSync(BIN_PATH, 0o755);
        fs.writeFileSync(VERSION_FILE, `${tag}\n`);
        log(`[插件] 已安装 ${tag} 到 ${APP_DIR}`);
    } finally {
        state.progress = null;
        fs.rmSync(tmpDir, { recursive: true, force: true });
    }
}

function commandExists(cmd) {
    try {
        execFileSync('sh', ['-c', `command -v ${cmd}`], { stdio: 'ignore' });
        return true;
    } catch {
        return false;
    }
}

function buildCommand() {
    const args = ['--open-ui=false'];
    const env = { ...process.env };
    // 面板上点启动 = 连生成服务一起启动，不用再进管理页面点「启动服务」
    env.AUTO_START = 'true';
    if (process.env.AISTUDIO2API_PORT) env.LISTEN_ADDR = `127.0.0.1:${PORT}`;
    // Windows 桌面版不往控制台输出，让它写日志文件，面板的「日志」从文件读
    if (IS_WINDOWS) env.LOG_FILE = 'true';
    if (!IS_TERMUX) return { cmd: BIN_PATH, args, env };

    // 安卓没有 /etc/resolv.conf，Go 的 DNS 解析器读不到会全部失败；用 proot 映射 Termux 的
    if (!commandExists('proot')) throw new Error('缺少 proot，请在 Termux 里运行：pkg install proot');
    const prefix = process.env.PREFIX;
    const resolv = path.join(prefix, 'etc', 'resolv.conf');
    if (!fs.existsSync(resolv)) fs.writeFileSync(resolv, 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
    env.SSL_CERT_FILE = path.join(prefix, 'etc', 'tls', 'cert.pem');
    // termux-exec（LD_PRELOAD）会把 proot 的 execve 改走系统 linker64，
    // 系统加载器拒绝静态非 PIE 程序：报 "has unexpected e_type: 2"。proot 自己负责加载，钩子必须去掉
    delete env.LD_PRELOAD;
    return { cmd: 'proot', args: ['--kill-on-exit', '-b', `${resolv}:/etc/resolv.conf`, BIN_PATH, ...args], env };
}

function launch() {
    const { cmd, args, env } = buildCommand();
    setStatus('starting', '启动中');
    const child = spawn(cmd, args, { cwd: APP_DIR, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    state.child = child;

    const onOutput = (chunk) => {
        const text = chunk.toString();
        log(text);
        if (state.status === 'starting' && text.includes('管理服务就绪')) {
            state.restarts = 0;
            setStatus('running', '运行中');
        }
    };
    child.stdout.on('data', onOutput);
    child.stderr.on('data', onOutput);

    // 日志文字可能随上游改版变化，以端口能连上为准
    const readyCheck = setInterval(async () => {
        if (state.child !== child || state.status !== 'starting') return clearInterval(readyCheck);
        if (await portInUse(PORT)) {
            clearInterval(readyCheck);
            if (state.child === child && state.status === 'starting') {
                state.restarts = 0;
                setStatus('running', '运行中');
            }
        }
    }, 1000);
    child.once('exit', () => clearInterval(readyCheck));

    child.once('error', (err) => {
        state.child = null;
        state.wantRunning = false;
        setStatus('error', `启动失败：${err.message}`);
    });

    child.once('exit', (code, signal) => {
        state.child = null;
        if (!state.wantRunning) {
            setStatus('stopped', '已停止');
            return;
        }
        if (state.restarts >= MAX_RESTARTS) {
            state.wantRunning = false;
            setStatus('error', `连续退出 ${MAX_RESTARTS} 次，已放弃重启（退出码 ${code ?? signal}），看日志找原因`);
            return;
        }
        state.restarts += 1;
        setStatus('starting', `意外退出（${code ?? signal}），5 秒后第 ${state.restarts} 次重启`);
        setTimeout(() => {
            if (state.wantRunning && !state.child) {
                try { launch(); } catch (err) { setStatus('error', err.message); }
            }
        }, 5000);
    });
}

let busy = false;

// 正在运行的「本目录这个程序」的进程：酒馆被强制结束时留下的、或用同目录的 Termux 命令起的。
// 它们是本插件管的那份程序，认领回来，面板照样能停。
function ownPids() {
    if (IS_WINDOWS) {
        // 按可执行文件完整路径找；路径里的单引号按 PowerShell 规则转义
        const target = BIN_PATH.replace(/'/g, "''");
        try {
            const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
                `Get-CimInstance Win32_Process -Filter "Name='${BIN_NAME}'" | Where-Object { $_.ExecutablePath -eq '${target}' } | ForEach-Object { $_.ProcessId }`],
            { encoding: 'utf8', windowsHide: true, timeout: 15000 });
            return out.split(/\r?\n/).map((s) => Number(s.trim())).filter((p) => p > 0);
        } catch {
            return [];
        }
    }
    if (fs.existsSync('/proc/self/cmdline')) {
        const pids = [];
        for (const d of fs.readdirSync('/proc')) {
            if (!/^\d+$/.test(d) || Number(d) === process.pid) continue;
            try {
                if (fs.readFileSync(`/proc/${d}/cmdline`, 'utf8').split('\0').includes(BIN_PATH)) pids.push(Number(d));
            } catch { /* 进程已退出或无权读 */ }
        }
        return pids;
    }
    try {
        return execFileSync('pgrep', ['-f', BIN_PATH], { encoding: 'utf8' })
            .split('\n').filter(Boolean).map(Number).filter((p) => p !== process.pid);
    } catch {
        return [];
    }
}

// Windows 桌面版的日志文件（LOG_FILE=true 时写 runtime/logs/），取最新文件的末尾
function fileLogs() {
    try {
        const dir = path.join(APP_DIR, 'runtime', 'logs');
        const newest = fs.readdirSync(dir)
            .filter((f) => f.endsWith('.log'))
            .map((f) => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs }))
            .sort((a, b) => b.t - a.t)[0];
        if (!newest) return [];
        const file = path.join(dir, newest.f);
        const size = fs.statSync(file).size;
        const fd = fs.openSync(file, 'r');
        const len = Math.min(size, 64 * 1024);
        const buf = Buffer.alloc(len);
        fs.readSync(fd, buf, 0, len, size - len);
        fs.closeSync(fd);
        return buf.toString('utf8').split(/\r?\n/).slice(1).filter(Boolean).map(prettyLine).slice(-LOG_LIMIT);
    } catch {
        return [];
    }
}

const EXTERNAL_MSG = '这个 AIStudio2API 不是插件启动的，启停要到启动它的地方操作';

async function killPids(pids) {
    for (const p of pids) try { process.kill(p, 'SIGTERM'); } catch { /* 已退出 */ }
    for (let i = 0; i < 10; i++) {
        await new Promise((r) => setTimeout(r, 500));
        if (!ownPids().length) return;
    }
    for (const p of ownPids()) try { process.kill(p, 'SIGKILL'); } catch { /* 已退出 */ }
}

async function start() {
    if (busy) return;
    if (state.child) return;
    busy = true;
    // 先同步改成「启动中」再做任何等待：路由马上回话时面板拿到的就是启动中，不会被打回「已停止」
    state.status = 'starting';
    state.message = '启动中';
    try {
        if (await portInUse(PORT)) {
            if (ownPids().length) setStatus('running', '运行中（接管已在运行的程序）');
            else setStatus('external', EXTERNAL_MSG);
            return;
        }
        if (!fs.existsSync(BIN_PATH)) {
            await download(await latestTag());
        }
        state.wantRunning = true;
        state.restarts = 0;
        launch();
    } catch (err) {
        state.wantRunning = false;
        setStatus('error', err.message);
    } finally {
        busy = false;
    }
}

function stop() {
    state.wantRunning = false;
    const child = state.child;
    if (!child) {
        const pids = ownPids();
        if (pids.length) {
            setStatus('stopping', '停止中');
            return killPids(pids).then(() => setStatus('stopped', '已停止'));
        }
        if (state.status !== 'external') setStatus('stopped', '已停止');
        return Promise.resolve();
    }
    setStatus('stopping', '停止中');
    return new Promise((resolve) => {
        const timer = setTimeout(() => {
            try { child.kill('SIGKILL'); } catch { /* 已退出 */ }
            for (const p of ownPids()) try { process.kill(p, 'SIGKILL'); } catch { /* 已退出 */ }
        }, 4000);
        child.once('exit', () => { clearTimeout(timer); resolve(); });
        // Termux 上子进程是 proot，它不把 SIGTERM 转给里面的程序：直接发给程序本身，程序退出后 proot 跟着退
        if (IS_TERMUX) for (const p of ownPids()) try { process.kill(p, 'SIGTERM'); } catch { /* 已退出 */ }
        try { child.kill('SIGTERM'); } catch { clearTimeout(timer); resolve(); }
    });
}

async function update() {
    if (busy) throw new Error('正在处理上一个操作');
    if (state.child || ownPids().length) throw new Error('先停止再更新');
    busy = true;
    try {
        const tag = await latestTag();
        if (tag === installedVersion()) {
            setStatus('stopped', `已是最新版 ${tag}`);
            return tag;
        }
        await download(tag);
        setStatus('stopped', `已更新到 ${tag}`);
        return tag;
    } catch (err) {
        setStatus('error', err.message);
        throw err;
    } finally {
        busy = false;
    }
}

async function snapshot() {
    // 插件没有直接管着子进程时，看端口上跑的是谁：本目录的程序 → 认领为运行中；别的 → 外部运行中
    if (!state.child && !busy && ['stopped', 'external', 'running'].includes(state.status)) {
        if (await portInUse(PORT)) {
            if (ownPids().length) {
                if (state.status !== 'running') { state.status = 'running'; state.message = '运行中'; }
            } else if (state.status !== 'external') {
                state.status = 'external';
                state.message = EXTERNAL_MSG;
            }
        } else if (state.status !== 'stopped') {
            state.status = 'stopped';
            state.message = '';
        }
    }
    return {
        status: state.status,
        message: state.message,
        progress: state.progress,
        version: installedVersion(),
        port: PORT,
        termux: IS_TERMUX,
        appDir: APP_DIR,
        uiPort: frameProxy && frameProxy.listening ? UI_PORT : null,
    };
}

// ---------- 弹窗用的本机转接 ----------
// 原样转发到 AIStudio2API，只把「禁止被嵌入」换成「只允许本机页面嵌入」。
// 只监听 127.0.0.1；Host/Origin 原样转发，上游的同源与回环校验照常生效。
let frameProxy = null;

function errorPage(res, text) {
    res.writeHead(502, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<body style="font-family:sans-serif;padding:24px;color:#888">${text}</body>`);
}

function startFrameProxy() {
    frameProxy = http.createServer((req, res) => {
        const upstream = http.request(
            { host: '127.0.0.1', port: PORT, method: req.method, path: req.url, headers: req.headers },
            (up) => {
                const headers = { ...up.headers };
                delete headers['x-frame-options'];
                headers['content-security-policy'] = "frame-ancestors 'self' http://127.0.0.1:* http://localhost:*";
                res.writeHead(up.statusCode || 502, headers);
                up.pipe(res);
            },
        );
        upstream.on('error', () => errorPage(res, 'AIStudio2API 没有在运行：在酒馆扩展栏的面板上点 ▶ 启动'));
        req.pipe(upstream);
    });
    frameProxy.on('error', (err) => {
        log(`[插件] 弹窗转接口 ${UI_PORT} 启动失败：${err.message}（管理页面只能用新标签页打开）`);
    });
    frameProxy.listen(UI_PORT, '127.0.0.1');
}

async function init(router) {
    router.get('/status', async (_req, res) => res.json(await snapshot()));
    router.post('/start', async (_req, res) => {
        start(); // 下载可能很久，后台进行；前端轮询 status
        res.json(await snapshot());
    });
    router.post('/stop', async (_req, res) => {
        stop(); // 不等停完：先回「停止中」，前端轮询看结果
        res.json(await snapshot());
    });
    router.post('/update', async (_req, res) => {
        try {
            const tag = await update();
            res.json({ ok: true, tag, ...(await snapshot()) });
        } catch (err) {
            res.status(400).json({ ok: false, error: err.message, ...(await snapshot()) });
        }
    });
    router.get('/logs', (_req, res) => res.json({ logs: IS_WINDOWS ? [...state.logs, ...fileLogs()] : state.logs }));

    startFrameProxy();

    // 酒馆被直接结束时也带走子进程
    process.once('exit', () => {
        if (state.child) try { state.child.kill('SIGKILL'); } catch { /* 已退出 */ }
    });
    console.log(`[AIStudio2API] 插件已加载，程序目录 ${APP_DIR}`);
}

async function exit() {
    if (frameProxy) frameProxy.close();
    await stop();
}

module.exports = {
    init,
    exit,
    info: {
        id: 'aistudio2api',
        name: 'AIStudio2API',
        description: '在酒馆里启动和管理 AIStudio2API',
    },
};
