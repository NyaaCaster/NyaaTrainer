# THIRD_PARTY — 外部工件来源与许可

本仓库（NyaaTrainer，MIT）自身代码之外，`runtime/` 装配与 `bootstrap/` 引导涉及下列第三方工件。

| 工件 | 版本 | 来源 | 许可 | 引入方式 |
|---|---|---|---|---|
| **Cheat Engine** 安装包（仅运行时下载解压，不随仓库分发） | 7.7 | <https://cheatengine.org/>（官网安装器）<br>源码：<https://github.com/cheat-engine/cheat-engine> | GPL-2.0 | `runtime/bootstrap.ps1` 下载 → 7z 免安装解压到 `runtime/ce/`；下载的安装包用后即删 |
| **standalonephase1/2.cepack、tiny.cepack 等模板** | （随 CE 分发） | 同上 | GPL-2.0 | 属 CE 安装副本内文件，`make_trainer.py` 首次运行就地转 `.dat`，不单独入库 |
| **Python embeddable zip** | 3.12.x | <https://www.python.org/downloads/windows/> | PSF-2.0 | 内嵌于 `runtime/tools/python/`（官方免安装分发包，未修改内容） |
| **ceMCP Daemon（`bootstrap/ceMCP.lua`）** | 社区扩展 v1.1 | CE 论坛 topic 623995「Cheat Engine Simple MCP Server」；部署版含 2 处补丁（请求/响应文件固定到 CE 目录、主窗体就绪后自动启动），由维护者服务器分发 | 见文件头声明 | 已含补丁的部署版入库于 `bootstrap/ceMCP.lua`，SHA256 见同名 `.sha256` |

## 说明

1. **仓库本体保持 MIT**：Cheat Engine 及其 `.cepack` 模板以「用户机器上运行时自行获取」的方式接入（方案 A 自装配），仓库二进制与源码层面均不包含 GPL 工件 → GPL 不传染本仓库。
2. **CE 运行副本的再分发要求**由 Cheat Engine 官 GPLv2 规定约束最终用户本机部署；本仓库不代理、不镜像其安装包。
3. `main_boot.lua` / `dsh_lib.lua` / `dsh_stable.lua` 为本仓库自研引导代码（MIT），不来自上游。
4. 修改器产物（`make_trainer.py` 生成的独立exe）内打包的是 CE 运行时工件，**产物按 GPL-2.0 传染条款处理**，仅限单机游戏个人学习与娱乐性修改（见 README 免责声明）。
