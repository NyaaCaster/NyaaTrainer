# 方法 F：解释器指令注入（无脚本语言引擎的扩展命令法）

> **本文解决什么**：RPG Maker 2k/2k3 这类**没有任何脚本语言**的引擎——没有 JS/Ruby/Python
> 可 eval，数据文件格式又封闭——修改的通路只剩一条：**给游戏的"事件指令解释器"加命令**，
> 借游戏自己的执行器跑我们的逻辑。
>
> **上位总览**：`05-engine-mod-methods-overview.md`。
> 建立：2026-10-02。

---

## 0. 原理

RPG Maker 2k/2k3 的"程序"是**事件指令列表**（打开菜单、改变量、条件分支……约几百条指令码），
由引擎内置的解释器逐条执行。**指令集是引擎的"汇编语言"**：

```
游戏 = 数据库(RPG_RT.ldb) + 地图事件(指令列表) + 解释器(逐条执行)
```

对这种引擎，"注入代码"的等价物是**注入指令**：

1. **静态注入**：离线改事件脚本（数据库/地图文件里的事件指令列表），插入我们的指令序列
   （"变量 A += N""物品 +1"）——游戏加载后自然执行；
2. **动态注入**：运行时**直接调度解释器**执行指定指令（等价于 eval，但"代码"是一条指令）；
3. **指令表逆向**：前提是掌握**指令码 ↔ 语义**的完整映射表——样本工具内置了整套
   RM2k 指令名常量（`ChangeMonsterHP`、`ConditionalBranch`、`JumpToLabel`、`ShowChoiceOption`、
   `OpenSaveMenu`、`KeyInputProc`、`ChangeEncounterSteps`、`Maniac_*` 扩展……），
   就是这张表。

**为什么走兼容运行时**：原版 RM2k 引擎（老 exe）不可注入、无扩展点。
样本工具的做法是**用开源兼容运行时（EasyRPG Player 形态）替代引擎本体**——兼容运行时是
开源的、可编译扩展的，直接把修改 API 做进播放器：

```
原版 Game.exe（封闭引擎）  →  兼容运行时 Player（开源播放器 + 内置修改 API）
```

游戏数据（`RPG_RT.ldb`/`.lmt`、地图）**不变**，只是执行器被替换——数据兼容性由运行时保证。

---

## 1. 兼容运行时暴露的修改 API（样本工具实测清单）

| API | 用途 |
|---|---|
| `EasyRpg_SetInterpreterFlag` | **直接置/清事件开关**（解释器级的 flag 写入） |
| `EasyRpg_AnimateVariable` | **动画化变量**（变量驱动动画/数值渐变） |
| `EasyRpg_TriggerEventAt` | **在坐标触发事件**（点击传送/交互类修改） |
| `EasyRpg_CallMovementAction` / `EasyRpg_WaitForSingleMovement` | 调用/等待移动路由（瞬移、NPC 操控） |
| `EasyRpg_CloneMapEvent` / `EasyRpg_DestroyMapEvent` | **克隆/销毁地图事件**（运行时改事件结构） |
| `EasyRpg_Pathfinder` | 寻路（配合事件操作） |
| `EasyRpg_ProcessJson` | JSON 数据处理（与外部工具交换数据） |

**这组 API 的语义值得注意**：它们不是"读写变量"的细粒度接口，而是**解释器语义层的操作**——
"触发事件""执行移动路由""置开关"。变量/物品等细粒度读写走**变量表 API**
（`08-method-object-model-mapping.md` §1.7 的 `getVariableDb`/`getVariableVals`），
两层配合才完整。

---

## 2. 指令语义表的构建（本方法的工程主体）

要做指令注入，必须先有**指令语义表**。样本工具内置的 RM2k 指令覆盖面（从字节码提取的
指令名清单归纳）：

| 类别 | 指令示例 |
|---|---|
| 变量/开关 | `ControlVariables`、`ControlSwitches`、条件分支 `ConditionalBranch` |
| 角色 | `ChangeMonsterHP/MP/Condition`、`ChangeExp`、`ChangeLevel`、`ChangeItems` |
| 场景 | `OpenSaveMenu`、`ChangeSaveAccess`、`OpenMainMenu`、`ReturntoTitleScreen` |
| 移动/地图 | `ChangeMapTileset`、`ChangePBG`、`TeleportTargets`、`ChangeTeleportAccess`、`KeyInputProc` |
| 战斗 | `ChangeBattleBG`、`ShowBattleAnimation`、`TerminateBattle`、`Victory/Escape/DefeatHandler` |
| 流程 | `JumpToLabel`、`Loop`/`BreakLoop`、`EndEventProcessing`、`EraseEvent`、`CallEvent`、`Comment` |
| 消息 | `ShowMessage`、`ShowChoiceOption`/`ShowChoiceEnd` |
| **Maniac 扩展**（改装版运行时的扩展指令集） | `Maniac_ControlVarArray`（**数组变量**）、`Maniac_ControlStrings`（字符串变量）、`Maniac_ControlGlobalSave`（全局存档）、`Maniac_GetSaveInfo`/`Save`/`Load`、`Maniac_GetGameInfo`、`Maniac_EditPicture`/`WritePicture`/`Zoom`、`Maniac_AddMoveRoute`、`Maniac_KeyInputProcEx`、`Maniac_CallCommand` |

> **指令表怎么来**：开源兼容运行时的**源码/文档**（EasyRPG 类项目维护着完整的 RM2k 指令
> 规范）+ Maniac 类改装运行时的扩展指令文档。**不要靠字节反推指令码**——有人已经做完了。
> 老引擎（RM2k/2k3）还有注册表特征可查引擎原版信息（`ASCII\RPG2000` / `Enterbrain\rpg2003` /
> `KADOKAWA\rpg200x`）。

---

## 3. 修改形态

### 3.1 游戏内 cheat 面板（RM2k 特色）

样本工具对 RM2k 提供 **F9 游戏内修改面板**（`Press "F9" for in game cheat`）——
面板本身就是**一段被注入的事件指令序列**在游戏内渲染交互（RM2k 的 UI 就是事件+变量画的）。
变量/开关锁（`rm2kVarLock.json` 持久化）+ 变量表 API 读写。

### 3.2 事件脚本离线重写（与方法 B 交界）

往事件指令列表里插入/改写指令（如把某宝箱事件的"变量+N"改成"N×10"）——
数据载体是 `RPG_RT.ldb`/地图事件数据，属方法 B 的解析范围；**语义**是指令层（本方法）。

---

## 4. 适用引擎与边界

| 引擎 | 适不适用 | 说明 |
|---|---|---|
| **RM2k/2k3** | ✅ **主力** | 无脚本语言的唯一编程通道；需兼容运行时承载 |
| 其它引擎 | 一般不需要 | 有脚本语言的引擎（MV/RGSS/Tyrano/krkr/Ren'Py）直接走方法 A，指令注入是绕远路 |
| Wolf | 部分适用 | Wolf 事件指令（`wolf_command` 系）同样可离线重写，但 Wolf 数据库可直改（方法 B 更直接） |

---

## 5. 操作骨架

```
① 判引擎: RPG_RT.ldb/lmt + 注册表特征(ASCII/Enterbrain/KADOKAWA)
② 承载: 用开源兼容运行时替代引擎本体启动(数据不变,执行器换成可编程版)
③ 变量表: 兼容运行时的变量表 API 读(08 篇 §1.7)
④ 修改: 变量表写 / 解释器指令调度(SetInterpreterFlag 等) / F9 内置面板
⑤ 锁定: 变量锁持久化(json 分类型) → 读入口返回锁值(10 篇 §2.1)
⑥ 离线改事件(可选): 指令语义表 → 事件脚本重写
⑦ 验证: 实机跑 + 存档兼容检查(工具存档 vs 原版 exe)
```

---

## 6. 坑位表

| 坑 | 现象 | 正解 |
|---|---|---|
| 对原版 exe 找注入点 | 老 exe 无扩展点、加壳 | **换兼容运行时**承载（数据兼容，执行器开源可扩展） |
| 靠字节猜指令码 | 错一位全盘崩 | 用开源运行时的**指令规范/源码**（已有人逆向完） |
| 忽略改装运行时扩展 | 数组变量/字符串变量做不到 | Maniac 类扩展指令集（`ControlVarArray`/`ControlStrings`） |
| 工具改的事件结构存档后回原版 | 原版读档异常 | 运行时补丁不落盘；落盘改写要做存档兼容测试 |
| F9 面板与游戏按键冲突 | 面板调不出来 | 按键可配置（`KeySetting.json` 形态） |

---

## 7. 与其它方法的关系

- **F 是 A 的"最后兜底"**：同为"让游戏执行我们的逻辑"，A 用脚本 eval，F 用指令注入——
  引擎给哪种就用哪种。
- **F ↔ B**：指令注入的**载体**是数据文件（事件列表在数据库里）——解析靠 B，语义靠 F。
- **F ↔ C**：变量表 API（兼容运行时）就是 C 方法在无脚本引擎上的等价物。
