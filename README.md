# NyaaTrainer

> 喵灵月影宗——使用Agent结合CE和自创脚本进行游戏修改的私人工具集。

把"在游戏里找到一个数值"到"交付一个双击即用的独立修改器"的整条链路，沉淀成
**可被 Agent 直接复用的文档 + 脚本 + 样板**。

- 协议：[MIT](LICENSE)
- 维护者：[@NyaaCaster](https://github.com/NyaaCaster)

---

## 启用

把下面这句提示词发给任何 Agent 工具（Claude Code / Codex / OpenCode / ZCode / DSH…），即可完成部署：

```text
从 https://github.com/NyaaCaster/NyaaTrainer.git 安装 NyaaTrainer 项目
```

Agent 会：询问你项目 clone 到哪个目录 → `git clone` → 运行 `runtime\bootstrap.ps1` 下载 **Cheat Engine 7.7 纯净便携包**并装配 → 三条 CE 通道与修改器生成器即刻可用。

> 装配只落在仓库 `runtime\` 内：**不写注册表、不执行任何安装器、不碰你已装的任何软件**；要求本机已有 7-Zip（解 7z 包用）。国内网络请先开翻墙（bootstrap 对下载源做连通性探测，失败会停下提示）。

---

## 这是什么

一套面向 **Agent 驱动**的游戏内存修改工程。核心主张：

1. **不要一上来扫内存** —— Unity Mono 游戏直接 dump 类结构，字段名往往就叫 `currentHp`
2. **地址必须可重建** —— 记「类名 + 字段偏移」而不是记地址，重启后重新解析
3. **交付物是程序** —— 最终产出是一个不依赖 CE 安装的独立修改器 exe
4. **全程可脚本化** —— 生成、验证、清理都不需要点 GUI

实测案例（两个真实项目，见 `docs/`）：

| 项目 | 引擎 | 数据形态 | 结果 |
|---|---|---|---|
| パンドラメイズ260427 | Unity Mono | 静态字段 | 定位用十几轮 → 交付独立修改器 |
| 淫白の御供 | Unity Mono | 实例字段 | **3 轮定位**，交付带 HP/MP 锁定的小面板修改器 |

---

## 快速开始

### 1. 装配 runtime（唯一安装步骤；不要求预装任何外部软件）

```powershell
.\runtime\bootstrap.ps1
```

它自动完成：从维护者服务器下载 **CE 7.7 纯净便携 7z 包** → SHA256 白名单校验 → **7z 免安装解压**（免装、免注册表、免驱动、**全程不执行任何安装器**）到 `runtime\ce\`（纯净包已内嵌 Agent 引导，开箱即用）→ 幂等校验引导三件 → **删除下载物** → 文件级自检。Python 3.12（embeddable）已内嵌于 `runtime\tools\python\`，无需安装。

> ⚠️ **国内网络提示**：CE 官网站点通常需要代理，**请先开启翻墙软件再运行 bootstrap**（脚本会对下载源做连通性探测，失败会停下并给出同样提示）。完全无法联网时可用本地安装包离线装配：`.\runtime\bootstrap.ps1 -CePackage <安装包路径>`。
> 系统需已有 7-Zip（bootstrap 会探测；没有则提示安装）。

### 2. （可选）config.yaml

```bash
cp config.example.yaml config.yaml
```

`config.yaml` 已在 `.gitignore` 中，不会被提交。独立工作区后**不再有必填路径**（CE 路径由脚本自动定位到 `runtime\ce\`）；`games[]` 登记改为可选，由使用现场决定。

### 3. 交给 Agent

用 Agent 打开本仓库，让它读 **[`AGENTS.md`](AGENTS.md)**（热 rule），即可按标准流程作业。

---

## 目录结构

```
NyaaTrainer/
├── README.md                  本文件 —— 项目门面（人类阅读）
├── AGENTS.md                  Agent 热 rule —— 流程 / 硬规矩 / 索引（Agent 必读）
├── LICENSE                    MIT（第三方工件来源与许可见 bootstrap/THIRD_PARTY.md）
├── config.example.yaml        配置样例（复制为 config.yaml 后按需修改；无必填路径）
├── .gitignore
│
├── docs/                      方法论文档（Agent 与人类的共同知识源）
│   ├── 01-mono-recon.md           Unity Mono 数据结构侦察（定位数值的起点）
│   ├── 02-stable-address.md       把浮动地址固化成重启后仍有效的条目
│   ├── 03-standalone-trainer.md   打包成独立修改器 exe（含小面板 UI）
│   ├── 04-ce-bridge.md            CE 与本仓库的通道（前置工作链）
│   └── history/
│       └── PLAN-standalone-workspace.md  独立工作区改造计划（SSOT，已完成归档）
│
├── bootstrap/                 Agent 引导原料（仓库自研 + 已获准分发的部署件）
│   ├── main_boot.lua             追加进 main.lua 的三段引导正文
│   ├── dsh_lib.lua               Lua 往返桥（结果回传）
│   ├── dsh_stable.lua            稳定条目框架（声明/解析/反查/自动重建）
│   ├── ceMCP.lua(+.sha256)       CE 侧 MCP 文件通道轮询内核（社区扩展部署版）
│   └── THIRD_PARTY.md            第三方工件来源与许可
│
├── runtime/                   运行时装配区（bootstrap.ps1 管；ce/ 与 downloads/ 不进仓库）
│   ├── bootstrap.ps1             ★ 装配器：下载 CE 7.7 → 7z 解压 → 部署引导 → 删安装包 → 自检
│   ├── ce/                       CE 免安装副本（bootstrap 产出，gitignore）
│   └── tools/python/             ★ 内嵌 Python 3.12 embeddable（随仓库分发）
│
├── src/                       可执行代码
│   ├── ce_mcp_server.py          标准 MCP 服务端（Agent 首选接入方式）
│   ├── make_trainer.py           独立修改器生成器（与游戏无关，通用）
│   ├── ce-lua.ps1                任意 Lua 通道客户端
│   ├── ce-mcp.ps1                8 个成品工具的命令行客户端
│   ├── check_lua_scope.py        Lua 作用域自查（查"使用早于 local 声明"）
│   └── CheatEngine-Manage.ps1    CE 安装管理（legacy，排查/卸载用）
│
├── skills/                    Agent 技能（放进 Agent 的 skills 目录即可用）
│   ├── ce-stable-address/SKILL.md
│   └── ce-standalone-trainer/SKILL.md
│
└── examples/                  各游戏的样板（表 + 稳定地址脚本）
    ├── pandora/stable.CT         静态字段型
    ├── iyohaku/stable.CT         实例字段型
    │   iyohaku/stable.lua
    └── nurtale/stable.CT         实例无单例 + 调托管方法型
        nurtale/stable.lua
```

---

## 工作流一览

```
侦察引擎  →  摸清数据结构  →  写入验证  →  固化地址  →  跨进程验证  →  打包修改器  →  交付
   |             |                            |                              |
   |        docs/01-mono-recon.md       docs/02-stable-address.md     docs/03-standalone-trainer.md
   |                                                                          |
   +------------------ 全程靠 docs/04-ce-bridge.md 提供通道 -------------------+
```

每步的验收判据写在 `AGENTS.md` 里，**不可跳步**（尤其是"重启后仍有效"和"干净环境能跑"）。

---

## 使用 skill

`skills/` 下是两个 Agent 技能。把整个目录复制到你的 Agent skills 目录即可：

```bash
# 常见位置（按你的 Agent 而定）
cp -r skills/ce-* ~/.agents/skills/
```

| skill | 何时触发 |
|---|---|
| `ce-stable-address` | 地址重启就失效 / 要做永久条目 / 指针扫描 / 找基址偏移 |
| `ce-standalone-trainer` | 打包成 exe / 双击即用 / 给游戏做个修改器 |

---

## 免责声明

本项目仅用于**单机游戏的个人学习与娱乐性修改**，以及逆向工程方法的学习记录。

- 请勿用于联机游戏、竞技游戏或任何违反游戏服务条款的场景
- 请勿用于商业用途或传播修改后的游戏本体
- 使用本仓库工具产生的一切后果由使用者自行承担

`openLuaServer` 会开一个**无认证的本地管道**（等价于任意 Lua 执行），
请在可信环境下使用，用完及时关闭。

---

<div align="center">

**Nyaa be with you.**

</div>
