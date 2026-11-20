# AIStudio2API for SillyTavern

把 [AIStudio2API](https://github.com/Mag1cFall/AIStudio2API) 装进 SillyTavern：酒馆扩展栏里一个面板，点一下启动，点面板打开管理页面。安卓 Termux、Linux、macOS、Windows 都能用。

不修改上游程序：程序从上游发布页下载，放在 `~/aistudio2api/`（和 [aistudio2api-termux](https://github.com/shleeshlee/aistudio2api-termux) 共用，已有账号直接沿用）。上游删库或停更时，自动改用备份 [shleeshlee/AIStudio2API](https://github.com/shleeshlee/AIStudio2API)（源码、发布包和编译依赖每天同步）。

## 安装 / 更新 / 卸载

一条命令，在 Termux 或终端里运行（会自动找酒馆目录）：

```sh
curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash
```

**Windows**（PowerShell 里运行，需要 Windows 10 1803 及以上）：

```powershell
irm https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.ps1 | iex
```

Windows 上程序是上游的桌面版，插件在后台启动它（只在托盘显示图标，不弹窗口），面板的「日志」读它写的日志文件。酒馆由脚本重启时会在新窗口里打开。

运行后选：

```
    1) 安装
    2) 更新
    3) 卸载
```

- **安装 / 更新**：补装缺的依赖（Termux 上包括修 DNS 用的 proot），装好插件和面板，打开 `config.yaml` 的 `enableServerPlugins`，下载或更新 AIStudio2API 程序；酒馆在运行时问要不要自动重启，重启后自动验收插件是否加载
- **卸载**：停止程序，删除插件和面板；`~/aistudio2api/`（程序和已导入的账号）单独询问，默认保留

已经单独装过 AIStudio2API（自己解压的、或用 aistudio2api-termux 装的）：安装/更新时会自动找出来（正在运行的进程和主目录下的文件夹），显示账号数，问要不要让插件直接用它；选是则插件改用那个目录，文件原地不动，卸载时也不会删它。

免交互用法：`... | bash -s -- install`（或 `update`、`uninstall`），末尾可再加酒馆目录。

## 使用

扩展栏里的蓝色「AIStudio2API」面板：

| 操作 | 效果 |
| --- | --- |
| 点右边 ▶ | 启动（第一次自动下载程序，约 75MB，需要能访问 GitHub） |
| 点右边 ■ | 停止 |
| 点面板本身 / 「打开管理页面」 | 在酒馆里弹窗打开管理页面：添加账号、看用量（弹窗里也有「在浏览器新标签页打开」） |
| 日志 | 查看程序最近的输出，启动失败时看这里 |
| 更新 | 下载上游最新版（先停止） |

接入酒馆：API 连接 → Chat Completion → 来源选 **Google AI Studio** → 反向代理预设选 **AIStudio2API** → 连接，选模型。

面板启动时会连同生成服务一起启动，不用再进管理页面点「启动服务」。酒馆关闭时程序一起关闭。

### 添加账号

手机上不能用上游的浏览器登录，用「粘贴 Cookie」：Firefox 安卓版装 Cookie-Editor，登录 aistudio.google.com 后导出 JSON，到管理页面「账户 → 添加账户 → 粘贴 Cookie」。

管理页面本身禁止被别的网页嵌入，插件在本机 `127.0.0.1:2052` 起了一个转接口供弹窗使用：只转发到 AIStudio2API，只允许本机页面嵌入。

## 状态说明

| 面板显示 | 含义 |
| --- | --- |
| 外部运行中 | 2048 端口已有 AIStudio2API 在跑（比如用 Termux 命令单独启动的），插件不重复启动，面板照样能打开管理页面 |
| 出错 | 点「日志」看原因；连续意外退出 3 次后不再自动重启 |
| 插件未加载 | 服务端插件没加载：确认 `config.yaml` 里 `enableServerPlugins: true` 并重启酒馆 |

## 许可

MIT。AIStudio2API 本身的许可见上游仓库。
