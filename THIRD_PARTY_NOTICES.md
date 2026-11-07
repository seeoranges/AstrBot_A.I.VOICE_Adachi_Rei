# 作者、修改与许可

本仓库整理自一个本机 AstrBot 部署，不是 AstrBot、A.I.VOICE 或足立レイ的官方项目。首次整理未统一改写各组件的许可。

- `plugins/astrbot_plugin_dafeiyu_*` 来自 **zexuan604 / zexuanw958-svg** 的大肥鱼配置包，保留 metadata 中的署名。原 MIT 许可证保存在各插件目录及 `LICENSES/dafeiyu-config-pack-MIT.txt`。
- 部分部署/运维工具也基于同一安装工具链，并包含本机修复与增强；来源是上述大肥鱼项目。原作者权利与原有许可声明保留。
- `integrations/astrbot_plugin_proactive_chat/core/services/sender_service.py` 基于 **DBJD-CR / Pancakes-Labs** 的 Proactive Chat **v1.3.0-beta.1**，本地修改加入足立零语音查找、去重和发送后合成。修改形成于 2026-11-05 至 2026-11-06。该目录保留完整 **AGPL-3.0** 许可及对应补丁；使用或分发时遵守该许可。
- 根目录的 `main.py` 是本地定制的语音桥接插件，metadata 保留 `dafeiyu-local` 标识；项目所有者未在本次整理中另行指定统一的开源许可证。没有明确许可的新增文件不因为仓库公开而自动获得 MIT 等授权。
- A.I.VOICE Editor、足立レイ音源、QQ、SnowLuma/NapCat 与模型不包含在源码中，适用各自条款。角色、音源及名称的权利属于各自权利人。

上游链接和组件用途见 `docs/DEPENDENCIES.md`。请在进一步分发时保留署名和许可证，不要把上游组件全部标为本项目原创。
