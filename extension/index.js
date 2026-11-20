/**
 * AIStudio2API for SillyTavern - 前端扩展
 *
 * 扩展栏里的小面板：点面板打开 AIStudio2API 管理页面，右侧按钮手动启动/停止；
 * 把 AIStudio2API 加进「反向代理」预设，来源选 Google AI Studio 后直接选用。
 */

import { getRequestHeaders } from '../../../../script.js';
import { callGenericPopup, POPUP_TYPE } from '../../../popup.js';

const NAME = 'AIStudio2API';
const API = '/api/plugins/aistudio2api';
const ADMIN_URL = 'http://127.0.0.1:2048';
const PROXY_URL = 'http://127.0.0.1:2048';

const STATUS_TEXT = {
    stopped: '已停止',
    downloading: '下载中',
    starting: '启动中',
    running: '运行中',
    stopping: '停止中',
    external: '外部运行中',
    error: '出错',
    offline: '插件未加载',
};

let current = { status: 'offline' };
let pollTimer = null;

async function call(method, route) {
    const res = await fetch(`${API}/${route}`, { method, headers: getRequestHeaders() });
    const data = await res.json().catch(() => ({}));
    if (!res.ok && !data.status) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
}

function isUp(s) {
    return s === 'running' || s === 'external';
}

function render() {
    const s = current.status;
    const panel = document.getElementById('a2a_panel');
    if (!panel) return;
    panel.dataset.status = s;

    let text = STATUS_TEXT[s] || s;
    if (s === 'downloading' && current.progress != null) text = `下载中 ${current.progress}%`;
    $('#a2a_state').text(text);
    $('#a2a_version').text(current.version && current.version !== 'unknown' ? current.version : '');

    const btn = $('#a2a_toggle');
    const busy = s === 'downloading' || s === 'starting' || s === 'stopping';
    // 等待时按钮方框不动，里面换成一个转圈的细圆环
    btn.toggleClass('fa-play', !isUp(s) && !busy)
        .toggleClass('fa-stop', s === 'running')
        .toggleClass('a2a-busy', busy)
        .toggle(s !== 'external' && s !== 'offline')
        .attr('title', s === 'running' ? '停止' : busy ? '处理中' : '启动');

    const showMsg = s === 'error' || s === 'downloading' || s === 'external' || (s === 'stopped' && !current.version);
    const msg = s === 'stopped' && !current.version ? '首次启动会自动下载程序（约 75MB）' : current.message || '';
    $('#a2a_msg').text(msg).toggle(showMsg && Boolean(msg));
}

async function refresh() {
    try {
        current = await call('GET', 'status');
    } catch {
        current = { status: 'offline' };
    }
    render();
    schedule();
}

function schedule() {
    clearTimeout(pollTimer);
    const s = current.status;
    const fast = s === 'downloading' || s === 'starting' || s === 'stopping';
    pollTimer = setTimeout(refresh, fast ? 1000 : 10000);
}

async function toggle() {
    const s = current.status;
    if (s === 'downloading' || s === 'starting' || s === 'stopping' || s === 'external' || s === 'offline') return;
    const stopping = s === 'running';
    // 点下去立刻有反馈，不等服务端回话
    current = { ...current, status: stopping ? 'stopping' : 'starting' };
    render();
    try {
        current = await call('POST', stopping ? 'stop' : 'start');
    } catch (err) {
        toastr.error(err.message, NAME);
    }
    render();
    schedule();
}

function openInTab() {
    window.open(ADMIN_URL, '_blank', 'noopener,noreferrer');
}

// 在酒馆里弹窗打开管理页面（经插件的本机转接口，绕开它的防嵌入）
function openAdmin() {
    if (current.status === 'offline') {
        toastr.warning('服务端插件没有加载：确认 config.yaml 里 enableServerPlugins: true，然后重启酒馆', NAME);
        return;
    }
    if (!isUp(current.status)) {
        toastr.info('先点右边的 ▶ 启动', NAME);
        return;
    }
    if (!current.uiPort) {
        openInTab(); // 转接口没起来时退回新标签页
        return;
    }
    // 自己的全屏层，不用酒馆弹窗：酒馆弹窗的内边距会把管理页面挤到比它的最小宽度还窄
    if (document.getElementById('a2a_overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'a2a_overlay';
    overlay.innerHTML = `
      <div class="a2a-sheet">
        <div class="a2a-sheet-bar">
          <b>AIStudio2API</b>
          <span class="a2a-sheet-actions">
            <span class="a2a-sheet-tab" title="在浏览器新标签页打开">新标签页 ↗</span>
            <i class="fa-solid fa-xmark a2a-sheet-close" title="关闭"></i>
          </span>
        </div>
        <iframe class="a2a-frame" src="http://127.0.0.1:${current.uiPort}/"></iframe>
      </div>`;
    // 屏幕比管理页面能排开的最小宽度还窄时，按最小宽度排版再整体缩小，不让右边被切掉
    const MIN_WIDTH = 400;
    const sheet = overlay.querySelector('.a2a-sheet');
    const frame = overlay.querySelector('.a2a-frame');
    const fit = () => {
        const w = sheet.clientWidth;
        const h = sheet.clientHeight - overlay.querySelector('.a2a-sheet-bar').offsetHeight;
        if (w > 0 && w < MIN_WIDTH) {
            const scale = w / MIN_WIDTH;
            Object.assign(frame.style, {
                flex: '0 0 auto', width: `${MIN_WIDTH}px`, height: `${h / scale}px`,
                transform: `scale(${scale})`, transformOrigin: 'top left',
            });
        } else {
            Object.assign(frame.style, { flex: '', width: '', height: '', transform: '', transformOrigin: '' });
        }
    };
    window.addEventListener('resize', fit);
    const close = () => {
        overlay.remove();
        document.removeEventListener('keydown', onKey);
        window.removeEventListener('resize', fit);
    };
    const onKey = (e) => { if (e.key === 'Escape') close(); };
    overlay.querySelector('.a2a-sheet-close').addEventListener('click', close);
    overlay.querySelector('.a2a-sheet-tab').addEventListener('click', openInTab);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(overlay);
    fit();
}

async function showLogs() {
    let logs = [];
    try {
        logs = (await call('GET', 'logs')).logs || [];
    } catch (err) {
        toastr.error(err.message, NAME);
        return;
    }
    const pre = document.createElement('pre');
    pre.className = 'a2a-logs';
    pre.textContent = logs.slice(-80).join('\n') || '（还没有输出）';
    callGenericPopup(pre, POPUP_TYPE.TEXT, '', { wide: true, large: true });
}

async function update() {
    try {
        current = { ...current, status: 'downloading', progress: 0 };
        render();
        const pending = call('POST', 'update');
        schedule();
        const data = await pending;
        current = data;
        if (data.ok === false) toastr.error(data.error, NAME);
        else toastr.success(data.message || '已更新', NAME);
    } catch (err) {
        toastr.error(err.message, NAME);
    }
    render();
    schedule();
}

// 和 CandyBox 一样，往「反向代理」预设里补一条
function injectProxy() {
    import('../../../openai.js').then(({ proxies }) => {
        if (!proxies) return;
        if (!proxies.find((p) => p.name === NAME)) {
            proxies.push({ name: NAME, url: PROXY_URL, password: '' });
        }
        const select = document.querySelector('#openai_proxy_preset');
        if (select && !select.querySelector(`option[value="${NAME}"]`)) {
            const option = document.createElement('option');
            option.text = NAME;
            option.value = NAME;
            select.appendChild(option);
        }
    }).catch(() => {});
}

function registerProxy() {
    injectProxy();
    const select = document.querySelector('#openai_proxy_preset');
    if (select) new MutationObserver(injectProxy).observe(select, { childList: true });
}

function createUI() {
    const html = `
    <div id="a2a_container" class="extension_container">
      <div id="a2a_panel" data-status="offline" title="点击在酒馆里打开 AIStudio2API 管理页面">
        <div class="a2a-left">
          <span class="a2a-star-1">✦</span>
          <b>AIStudio2API</b>
          <span id="a2a_version" class="a2a-version"></span>
          <span class="a2a-star-2">✧</span>
        </div>
        <div class="a2a-right">
          <span class="a2a-dot"></span>
          <span id="a2a_state">…</span>
          <i id="a2a_toggle" class="fa-solid fa-play a2a-toggle" title="启动"></i>
        </div>
      </div>
      <div id="a2a_bar">
        <span id="a2a_open" class="a2a-link a2a-open">打开管理页面</span>
        <span id="a2a_msg"></span>
        <span class="a2a-links">
          <span id="a2a_logs" class="a2a-link">日志</span>
          <span id="a2a_update" class="a2a-link">更新</span>
        </span>
      </div>
    </div>`;
    $('#extensions_settings2').append(html);

    $(document).on('click', '#a2a_panel', (e) => {
        if ($(e.target).closest('#a2a_toggle').length) return;
        e.preventDefault();
        openAdmin();
    });
    $(document).on('click', '#a2a_toggle', (e) => {
        e.preventDefault();
        e.stopPropagation();
        toggle();
    });
    $(document).on('click', '#a2a_open', (e) => {
        e.preventDefault();
        openAdmin();
    });
    $(document).on('click', '#a2a_logs', (e) => {
        e.preventDefault();
        showLogs();
    });
    $(document).on('click', '#a2a_update', (e) => {
        e.preventDefault();
        if (current.status === 'running') {
            toastr.info('先停止再更新', NAME);
            return;
        }
        if (current.status !== 'stopped' && current.status !== 'error') return;
        update();
    });
}

jQuery(async () => {
    try {
        createUI();
        registerProxy();
        await refresh();
    } catch (err) {
        console.error(`[${NAME}] 加载失败`, err);
    }
});
