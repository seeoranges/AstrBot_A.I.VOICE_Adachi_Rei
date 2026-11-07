# 依赖、来源与范围

| 组件 | 用途 | 来源 |
| --- | --- | --- |
| AstrBot | 消息、模型及插件运行环境 | https://github.com/AstrBotDevs/AstrBot |
| 大肥鱼配置包 | 辅助插件与本机部署工具的基础 | https://github.com/zexuanw958-svg/dafeiyu-config-pack |
| Proactive Chat v1.3.0-beta.1 | 主动联系及本地语音集成的基线 | https://github.com/Pancakes-Labs/astrbot_plugin_proactive_chat |
| A.I.VOICE Editor / 足立レイ | 本机语音合成 | 用户自行合法安装；不随仓库分发 |
| DeepSeek API | 日语改写和情绪标签 | 用户自行配置 API 密钥 |
| FFmpeg | WAV 到 QQ 可用音频格式的转换 | https://ffmpeg.org/ |
| Ollama / bge-m3 | 可选的上游长期记忆嵌入 | https://ollama.com/ |
| DeepSeek Search 插件 | 当前环境另行安装的可选搜索能力 | https://github.com/Fantasality/astrbot_plugin_deepseek_search |

第三方插件请从原项目安装并遵循其版本与许可。仓库不捆绑搜索、记忆、QQ 客户端、SnowLuma/NapCat、模型或商业音源，也不复制个人配置。

语音插件的集成目标是当前 AstrBot 插件 API（主动消息基线声明 AstrBot >=4.24.0）。首次公开整理采用本机已部署代码；没有宣称对所有 AstrBot / Editor 版本兼容。升级上游后请先运行离线测试，再验证自己的实际环境。
