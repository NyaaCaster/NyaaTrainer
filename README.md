# NyaaTrainer

> 私人风灵月影宗 —— 使用 Agent 结合 Cheat Engine 和自创脚本进行游戏修改的记录仓库。

把"在游戏里找到一个数值"到"交付一个双击即用的独立修改器"的整条链路，沉淀成
**可被 Agent 直接复用的文档 + 脚本 + 样板**。

- 协议：[MIT](LICENSE)
- 维护者：[@NyaaCaster](https://github.com/NyaaCaster)

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

### 1. 装依赖

| 工具 | 用途 | 来源 |
|---|---|---|
| **Cheat Engine 7.7** | 内存修改引擎 | <https://cheatengine.org/> · [GitHub](https://github.com/cheat-engine/cheat-engine) |
| **Python 3.8+** | 生成器 / MCP 服务端 | <https://www.python.org/downloads/> |
| **PowerShell 5.1+**（推荐 7.x） | 通道脚本 | <https://github.com/PowerShell/PowerShell> |

> Agent 提示：安装完成后，**把实际安装路径写回 `config.yaml` 的 `paths.cheat_engine`**
> （`config.yaml` 由 `config.example.yaml` 复制而来，见下一步）。

### 2. 配置

```bash
cp config.example.yaml config.yaml
```

然后编辑 `config.yaml`，**至少填这两个**：

```yaml
paths:
  cheat_engine: "C:\\Program Files\\Cheat Engine 7.7"   # 你的 CE 安装目录
  games_root:   "D:\\Games"                             # 你的游戏根目录
```

`config.yaml` 已在 `.gitignore` 中，**不会被提交** —— 你的本地路径不会进仓库。

`config.example.yaml` 里还登记了各外部工具的来源地址（`tools` 段），
Agent 可据此提示用户补全路径。

### 3. 让 CE 具备可被 Agent 驱动的能力

详见 **[`docs/04-ce-bridge.md`](docs/04-ce-bridge.md)**。简述：

在 `<CE_DIR>\main.lua` 末尾追加引导（文件见 `lua/`）：

```lua
pcall(function() openLuaServer('CELUASERVER') end)          -- 开命名管道
pcall(function() dofile(getCheatEngineDir() .. 'dsh_lib.lua') end)
```

之后 Agent 就能通过 `src/ce-lua.ps1` 在 CE 里执行任意 Lua 并取回结果。

### 4. 交给 Agent

用 Agent 打开本仓库，让它读 **[`AGENT.md`](AGENT.md)**（热 rule），即可按标准流程作业。

---

## 目录结构

```
NyaaTrainer/
├── README.md                  本文件 —— 项目门面（人类阅读）
├── AGENT.md                   Agent 热 rule —— 流程 / 硬规矩 / 索引（Agent 必读）
├── LICENSE                    MIT
├── config.example.yaml        配置样例（复制为 config.yaml 后修改）
├── .gitignore
│
├── docs/                      方法论文档（Agent 与人类的共同知识源）
│   ├── 01-mono-recon.md           Unity Mono 数据结构侦察（定位数值的起点）
│   ├── 02-stable-address.md       把浮动地址固化成重启后仍有效的条目
│   ├── 03-standalone-trainer.md   打包成独立修改器 exe（含小面板 UI）
│   └── 04-ce-bridge.md            CE 与本仓库的通道（前置工作链）
│
├── src/                       可执行代码
│   ├── ce_mcp_server.py          标准 MCP 服务端（Agent 首选接入方式）
│   ├── make_trainer.py           独立修改器生成器（与游戏无关，通用）
│   ├── ce-lua.ps1                任意 Lua 通道客户端
│   ├── ce-mcp.ps1                8 个成品工具的命令行客户端
│   └── CheatEngine-Manage.ps1    CE 安装管理（Status/Sync/Migrate/Uninstall）
│
├── lua/                       CE 侧加载的 Lua 库
│   ├── dsh_lib.lua               Lua 往返桥（结果回传）
│   └── dsh_stable.lua            稳定条目框架（声明/解析/反查/自动重建）
│
├── skills/                    Agent 技能（放进 Agent 的 skills 目录即可用）
│   ├── ce-stable-address/SKILL.md
│   └── ce-standalone-trainer/SKILL.md
│
└── examples/                  各游戏的样板（表 + 稳定地址脚本）
    ├── pandora/stable.CT         静态字段型
    └── iyohaku/stable.CT         实例字段型
        iyohaku/stable.lua
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

每步的验收判据写在 `AGENT.md` 里，**不可跳步**（尤其是"重启后仍有效"和"干净环境能跑"）。

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
