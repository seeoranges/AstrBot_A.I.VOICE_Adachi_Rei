# 安装与配置

## 1. 准备现有运行环境

本仓库是扩展代码，不是包含 QQ、AstrBot 和商业音源的一键整机安装包。先准备能正常收发消息的 AstrBot / OneBot 实例。运维脚本按照大肥鱼安装布局工作；自己手动部署 AstrBot 时，只使用语音部分并调整路径。

```text
<安装目录>/
  astrbot/data/plugins/
  ffmpeg/bin/ffmpeg.exe
  tools/aivoice-daemon.ps1
  private/
    deepseek-key.txt
    owner-qq.txt
    backend.txt           # 运维探针使用，纯语音合成不需要
    protocol.txt          # 已有接入环境的协议记录
```

插件从安装位置向上推导 `<安装目录>`，也可在启动 AstrBot 前通过进程环境变量 `ADACHI_REI_HOME` 显式指定。不要在代码里写 API 密钥。

安装并激活自己的 A.I.VOICE Editor 和足立レイ音源。当前桥接默认 API DLL 路径为：

```text
C:\Program Files\AI\AIVoice\AIVoiceEditor\AI.Talk.Editor.Api.dll
```

如果安装位置不同，需要修改 `tools/aivoice-daemon.ps1` 中的 `$dll`。音源本身不可由仓库安装；需要自己合法获取。FFmpeg 放到上面的运行目录，或者调整插件中的 `FFMPEG` 常量。

## 2. 准备自己的私密文件

在 `<安装目录>/private/` 中用本机文本编辑器创建：

- `deepseek-key.txt`：自己的 DeepSeek API 密钥，单行纯文本。
- `owner-qq.txt`：自己的主人账号，单行纯文本。
- `backend.txt`：仅在使用后台探针/运维工具时需要。格式为三行 `url: 本机后台地址`、`username: 后台用户名`、`password: 后台密码`。这些探针仅向本机后台认证。

不要把内容填进 GitHub Issue、聊天截图或仓库文件。仓库没有创建或复制这些个人文件。

## 3. 安装语音

在克隆下来的仓库中执行：

```powershell
powershell -NoProfile -File .\scripts\install.ps1 -Dir E:\dafeiyu -Component voice
```

安装器检查现有目录，将待覆盖文件备份到 `<安装目录>/private/snapshots/github-install-时间-随机串/`，然后复制插件和桥接。遇到复制错误会尝试恢复原文件。安装后重载插件；预热开启时 Editor 会启动并常驻。

`examples/voice-config.example.json` 展示开关，可在 AstrBot 的插件配置界面逐项设置。没有密钥或未激活音源时，语音不能成功，文字仍通过原来的聊天链路发送。

插件会注册 `adachi_aivoice` TTS 适配器；普通主人私聊通过发送后钩子补语音，无需把所有平台的全局 TTS 都改成它。

## 4. 可选组件

```powershell
# 主动消息语音：仅接受已知 v1.3.0-beta.1 基线或本仓库同版文件
powershell -NoProfile -File .\scripts\install.ps1 -Dir E:\dafeiyu -Component proactive

# 配套辅助插件，会覆盖相同名称的已有插件；安装器会先备份
powershell -NoProfile -File .\scripts\install.ps1 -Dir E:\dafeiyu -Component support

# 实例启动/停止、QQ 状态探针和守护工具
powershell -NoProfile -File .\scripts\install.ps1 -Dir E:\dafeiyu -Component ops
```

主动消息主体请先从上游安装，仓库仅提供语音集成。安装后重载主动消息插件。计时建议是空闲 30–90 分钟、23:00–08:00 免打扰、连续四次未回复后暂停。修改计时后，已有未来任务可能仍保留旧时间；需要在插件界面重新安排任务。说明性示例不能直接覆盖完整生产配置。

运维工具依赖原运行目录中的 `start-astrbot.cmd`、协议端启动入口、Python 环境及对应计划任务。安装器不会创建或重注册计划任务，不会启动/停止现有实例。`qq_watch.py` 的云端分支不包含在本次整理范围内；本仓库支持这里描述的本机环境。

可以先演练：

```powershell
powershell -NoProfile -File E:\dafeiyu\tools\start-all.ps1 -Dir E:\dafeiyu -DryRun
powershell -NoProfile -File E:\dafeiyu\tools\stop-all.ps1 -Dir E:\dafeiyu -DryRun
```

## 5. 回退

安装脚本成功后会打印备份目录。目录中的 `manifest.json` 逐一记录原文件是否存在；停止相关插件后，把备份中的同路径文件复制回运行目录。原本不存在的文件需按清单移除，再重载插件。不要把 `private/` 快照上传。

Editor 里首次合成会创建本插件专属的情绪预设，并在私密目录保存创建前的 `user.vpc`。回退代码不会自动删除这些预设。需要恢复 Editor 预设时，先退出 Editor，再用对应备份恢复，避免覆盖用户随后新建的预设。
