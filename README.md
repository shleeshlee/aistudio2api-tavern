# AIStudio2API for SillyTavern

把 [AIStudio2API](https://github.com/Mag1cFall/AIStudio2API) 装进 SillyTavern：酒馆扩展栏里一个面板，点一下启动，点面板打开管理页面。安卓 Termux、Linux、macOS 都能用。

不修改上游程序：插件第一次启动时下载上游发布的命令行版，放在 `~/aistudio2api/`（和 [aistudio2api-termux](https://github.com/shleeshlee/aistudio2api-termux) 共用，已有账号直接沿用）。

## 安装

在 Termux 或终端里运行（会自动找酒馆目录）：

```sh
curl -fsSL https://raw.githubusercontent.com/shleeshlee/aistudio2api-tavern/main/install.sh | bash
```

然后重启酒馆。脚本会：

1. 把服务端插件装到 `SillyTavern/plugins/AIStudio2API/`
2. 把前端扩展装到 `public/scripts/extensions/third-party/AIStudio2API/`
3. 打开 `config.yaml` 的 `enableServerPlugins`
4. Termux 上缺 proot 时补装（用来给程序修 DNS）

再次运行同一行命令即更新插件。

## 使用

扩展栏里的蓝色「AIStudio2API」面板：

| 操作 | 效果 |
| --- | --- |
| 点右边 ▶ | 启动（第一次自动下载程序，约 75MB，需要能访问 GitHub） |
| 点右边 ■ | 停止 |
| 点面板本身 | 新标签页打开管理页面：添加账号、看用量 |
| 日志 | 查看程序最近的输出，启动失败时看这里 |
| 更新 | 下载上游最新版（先停止） |

接入酒馆：API 连接 → Chat Completion → 来源选 **Google AI Studio** → 反向代理预设选 **AIStudio2API** → 连接，选模型。

面板启动时会连同生成服务一起启动，不用再进管理页面点「启动服务」。酒馆关闭时程序一起关闭。

### 添加账号

手机上不能用上游的浏览器登录，用「粘贴 Cookie」：Firefox 安卓版装 Cookie-Editor，登录 aistudio.google.com 后导出 JSON，到管理页面「账户 → 添加账户 → 粘贴 Cookie」。

## 状态说明

| 面板显示 | 含义 |
| --- | --- |
| 外部运行中 | 2048 端口已有 AIStudio2API 在跑（比如用 Termux 命令单独启动的），插件不重复启动，面板照样能打开管理页面 |
| 出错 | 点「日志」看原因；连续意外退出 3 次后不再自动重启 |
| 插件未加载 | 服务端插件没加载：确认 `config.yaml` 里 `enableServerPlugins: true` 并重启酒馆 |

## 许可

MIT。AIStudio2API 本身的许可见上游仓库。
