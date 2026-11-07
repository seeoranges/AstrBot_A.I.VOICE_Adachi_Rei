# 开发与验证

Python 离线测试使用标准库 unittest，以替身隔离 AstrBot、网络、QQ 和 Editor。PowerShell 测试解析实际源码中的函数并使用模拟 Editor / 进程 / 计划任务，不需要安装音源。

```powershell
python -B -m unittest discover -s tests -p "test_*.py"
powershell -NoProfile -File .\scripts\run-tests.ps1
python -B .\scripts\check-package.py
```

PowerShell 5.1 的中文脚本保留 UTF-8 BOM，`.gitattributes` 固定脚本换行。每个 PowerShell 测试使用独立进程，避免模拟类型互相冲突。

2026-11-07 首次整理的本地验证：182 项 Python 测试与 122 项 PowerShell 检查通过。测试加载本仓库源码，不依赖作者电脑上的安装目录；云端验证见仓库的 Actions 页面。

涉及本机 Editor 的人工验证建议依次进行：一条短句、三句不同情绪、超过六句的完整长文本、合成中桥接进程中断后的下一次恢复。先验证文件可解码与文本完整，再比较听感。Editor 的真实导出不能用 mock 结果代替。

发布前检查暂存区，避免将配置、备份、聊天和测试音频带入提交。`check-package.py` 检查禁用路径、文件类型和常见密钥格式；这不替代人工审查。不要把真实账号写成测试夹具，示例中使用占位符。
