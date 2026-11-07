# AstrBot × A.I.VOICE · 足立レイ

把足立零的声音带进 QQ：中文回复照常显示，再补上一条由本机 A.I.VOICE Editor 合成的日语语音。

本项目记录了一套实际在 Windows 上使用的 AstrBot 扩展。核心是 `astrbot_plugin_adachi_aivoice`，另外整理了主动消息语音集成、实例启动和掉线诊断工具。仓库提供代码、示例与离线测试；运行环境和个人数据需要在自己的电脑上配置。

仓库根目录提供标准 AstrBot 插件入口 `main.py`、`metadata.yaml`、`_conf_schema.json` 和依赖声明，可以直接通过仓库链接安装。语音桥接脚本包含在插件的 `tools/` 中；商业音源仍需自己安装。

## 功能

- **中文文字 + 日语语音**：将回复改写成足立レイ风格的日语台词，通过本机音源合成。
- **逐句情绪表现**：支持平静、普通、温柔、开心、兴奋、生气、低落、惊讶、调侃九种配置。模型选择情绪标签，本机固定表决定参数。
- **单条语音中的情绪变化**：标准化后不超过六句时使用 Editor 的 List 模式逐句设定，再一次导出；更多句子保留完整文本并走兼容合成路径。
- **后台预热与串行合成**：避免多条消息同时操作 Editor；可设置同一会话只念最新回复。
- **主动消息也能说话**：提供针对主动消息插件的集成文件，先确认文字发送成功，再补语音。
- **主人私聊限制**：语音发送检查账号和平台，避免在无关会话触发。
- **失败恢复**：合成错误留下诊断；连续失败时可提示。List 模式仅清理能确认属于本插件的临时行。

“情绪”指文字与语音的表现控制。足立レイ音源的 J 参数用于表现张力/喜悦，其他情绪由速度、音高、抑扬等组合近似；句末停顿是 Editor 的全局设置。

## 运行流程

```mermaid
flowchart LR
    QQ[QQ 私聊] --> AstrBot[AstrBot 生成中文回复]
    AstrBot --> Text[发送中文文字]
    Text --> Rewrite[DeepSeek 改写日语及情绪标签]
    Rewrite --> Bridge[本机 PowerShell 桥接]
    Bridge --> Editor[A.I.VOICE Editor / 足立レイ]
    Editor --> FFmpeg[FFmpeg 转换音频]
    FFmpeg --> Audio[QQ 语音]
```

## 开始使用

需要 Windows 10/11、Python 3.12、已接通 OneBot QQ 的 AstrBot、合法安装并授权的 A.I.VOICE Editor / 足立レイ音源、FFmpeg，以及自己的 DeepSeek API 密钥。音源和 Editor 不随本仓库分发；改写日语需要调用模型接口。

1. 先让现有 AstrBot 能正常收发 QQ 消息。
2. 按 [安装与配置](docs/SETUP.md) 准备目录、私密文件和音源。
3. 在 AstrBot 后台选择「从链接安装」，输入本仓库地址；已有同名语音插件时先备份，避免重复安装。也可使用下面的备份安装脚本。
4. 在插件配置中填写 `home_dir`（保存 `private/` 的目录），必要时填写 `ffmpeg_path`。重载插件后，由自己发一条消息验证。

```powershell
# 在已完成 AstrBot / OneBot 部署的电脑上执行；替换为自己的安装目录。
powershell -NoProfile -File .\scripts\install.ps1 -Dir E:\dafeiyu -Component voice
```

脚本默认只安装语音。运维工具、辅助插件与主动消息集成都需显式选择，详见安装文档。

## 目录

| 路径 | 内容 |
| --- | --- |
| `main.py`、`metadata.yaml`、`_conf_schema.json` | 可被市场解析和直接安装的核心插件入口 |
| `plugins/astrbot_plugin_dafeiyu_*/` | 保留原署名的配套辅助插件 |
| `tools/` | A.I.VOICE 桥接、实例启动/停止、状态探针与守护工具 |
| `integrations/astrbot_plugin_proactive_chat/` | 主动消息语音集成、补丁与 AGPL 许可证 |
| `examples/` | 无个人数据的配置示例 |
| `scripts/` | 安装、离线测试与发布检查 |
| `tests/` | Mock / 离线回归测试 |
| `docs/` | 部署、功能边界和开发说明 |

## 测试

```powershell
python -B -m unittest discover -s tests -p "test_*.py"
powershell -NoProfile -File .\scripts\run-tests.ps1
python -B .\scripts\check-package.py
```

测试不登录 QQ、不发送消息、不调用付费模型、不连接真实 Editor。仓库配置了 Windows CI。真实音源合成需要在已安装音源的本机另行验证；本项目在本机完成过逐句合成、长文本兼容合成及桥接进程中断恢复验证，耗时受文本和机器影响，不能作为端到端时延承诺。

## 数据与依赖

账号、API 密钥、后台密码、聊天记录、记忆库、运行日志、模型、QQ/SnowLuma 安装包和音源均不包含在仓库中。请始终把私人配置放在运行目录的 `private/` 中，不要提交到 Git。

AstrBot、QQ 接入、记忆与搜索等能力由各自上游项目提供，见 [依赖与来源](docs/DEPENDENCIES.md)。不同文件保留各自的作者与许可，见 [第三方说明](THIRD_PARTY_NOTICES.md)。足立レイ的名称、角色和音源权利属于各自权利人。
