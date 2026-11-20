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
const { spawn, execFileSync } = require('child_process');
const { Readable } = require('stream');
const { pipeline } = require('stream/promises');

const UPSTREAM = 'Mag1cFall/AIStudio2API';
const APP_DIR = process.env.AISTUDIO2API_HOME || path.join(os.homedir(), 'aistudio2api');
const BIN_NAME = process.platform === 'win32' ? 'aistudio2api.exe' : 'aistudio2api';
const BIN_PATH = path.join(APP_DIR, BIN_NAME);
const VERSION_FILE = path.join(APP_DIR, '.termux-version'); // 与 Termux 直装脚本共用
const PORT = Number(process.env.AISTUDIO2API_PORT) || 2048;
const LOG_LIMIT = 300;
const MAX_RESTARTS = 3;

const IS_TERMUX = Boolean(process.env.PREFIX && process.env.PREFIX.includes('com.termux'));

const state = {
    status: 'stopped', // stopped | downloading | starting | running | external | error
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
    throw new Error('目前只支持安卓 Termux、Linux 和 macOS；Windows 请直接用官方桌面版');
}

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
    // 读 releases/latest 的跳转地址，不走 GitHub API（无限流）
    const res = await fetch(`https://github.com/${UPSTREAM}/releases/latest`, { redirect: 'manual' });
    const location = res.headers.get('location') || '';
    const match = location.match(/\/tag\/([^/?#]+)/);
    if (!match) throw new Error(`查不到最新版本（HTTP ${res.status}）`);
    return match[1];
}

async function download(tag) {
    const name = assetName(tag);
    const url = `https://github.com/${UPSTREAM}/releases/download/${tag}/${name}.tar.gz`;
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'aistudio2api-'));
    const archive = path.join(tmpDir, 'pkg.tar.gz');
    try {
        setStatus('downloading', `下载 ${tag}`);
        state.progress = 0;
        const res = await fetch(url);
        if (!res.ok || !res.body) throw new Error(`下载失败 HTTP ${res.status}：${url}`);
        const total = Number(res.headers.get('content-length')) || 0;
        let received = 0;
        const body = Readable.fromWeb(res.body);
        body.on('data', (chunk) => {
            received += chunk.length;
            if (total) state.progress = Math.floor((received / total) * 100);
        });
        await pipeline(body, fs.createWriteStream(archive));

        execFileSync('tar', ['-xzf', archive, '-C', tmpDir]);
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
    if (!IS_TERMUX) return { cmd: BIN_PATH, args, env };

    // 安卓没有 /etc/resolv.conf，Go 的 DNS 解析器读不到会全部失败；用 proot 映射 Termux 的
    if (!commandExists('proot')) throw new Error('缺少 proot，请在 Termux 里运行：pkg install proot');
    const prefix = process.env.PREFIX;
    const resolv = path.join(prefix, 'etc', 'resolv.conf');
    if (!fs.existsSync(resolv)) fs.writeFileSync(resolv, 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
    env.SSL_CERT_FILE = path.join(prefix, 'etc', 'tls', 'cert.pem');
    return { cmd: 'proot', args: ['--kill-on-exit', '-b', `${resolv}:/etc/resolv.conf`, BIN_PATH, ...args], env };
}

function launch() {
    const { cmd, args, env } = buildCommand();
    setStatus('starting', '启动中');
    const child = spawn(cmd, args, { cwd: APP_DIR, env, stdio: ['ignore', 'pipe', 'pipe'] });
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

async function start() {
    if (busy) return;
    if (state.child) return;
    busy = true;
    try {
        if (await portInUse(PORT)) {
            setStatus('external', `端口 ${PORT} 已被占用：AIStudio2API 可能已在别处运行`);
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
        if (state.status !== 'external') setStatus('stopped', '已停止');
        return Promise.resolve();
    }
    return new Promise((resolve) => {
        const timer = setTimeout(() => {
            try { child.kill('SIGKILL'); } catch { /* 已退出 */ }
        }, 5000);
        child.once('exit', () => { clearTimeout(timer); resolve(); });
        try { child.kill('SIGTERM'); } catch { clearTimeout(timer); resolve(); }
    });
}

async function update() {
    if (busy) throw new Error('正在处理上一个操作');
    if (state.child) throw new Error('先停止再更新');
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
    // 不是本插件启动的，但端口有服务：多半是用 Termux 命令单独起的
    if (!state.child && (state.status === 'stopped' || state.status === 'external')) {
        const inUse = await portInUse(PORT);
        if (inUse && state.status === 'stopped') state.status = 'external';
        if (!inUse && state.status === 'external') state.status = 'stopped';
    }
    return {
        status: state.status,
        message: state.message,
        progress: state.progress,
        version: installedVersion(),
        port: PORT,
        termux: IS_TERMUX,
        appDir: APP_DIR,
    };
}

async function init(router) {
    router.get('/status', async (_req, res) => res.json(await snapshot()));
    router.post('/start', async (_req, res) => {
        start(); // 下载可能很久，后台进行；前端轮询 status
        res.json(await snapshot());
    });
    router.post('/stop', async (_req, res) => {
        await stop();
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
    router.get('/logs', (_req, res) => res.json({ logs: state.logs }));

    // 酒馆被直接结束时也带走子进程
    process.once('exit', () => {
        if (state.child) try { state.child.kill('SIGKILL'); } catch { /* 已退出 */ }
    });
    console.log(`[AIStudio2API] 插件已加载，程序目录 ${APP_DIR}`);
}

async function exit() {
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
