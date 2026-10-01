# 方法 C：引擎对象模型映射（变量表协议）

> **本文解决什么**：方法 A 的 eval 通道打通后，**读什么、怎么读全、怎么写回**——
> 把引擎的全局游戏状态单例枚举成一张"变量表"（id → 名称/当前值/类型），修改面板按这张表作业。
> 这是"通用多引擎修改器"在数据层的**标准件**。
>
> **上位总览**：`05-engine-mod-methods-overview.md`；通道原理见 `06-method-runtime-script-eval.md`。
> 建立：2026-10-02。

---

## 0. 原理

脚本架构引擎都有**官方全局对象**承载游戏状态（MV 的 `$gameParty`、RGSS 的 `$game_switches`、
AGTK 的 `Agtk.variables`……）。修改器的做法不是逐个猜字段，而是：

1. **一次性快照**：eval 一段"导出器"脚本，把所有相关全局对象**序列化成结构化快照**
   （稀疏数组剔除空位、字典压缩、背包计数化）；
2. **分门别类**：开关（bool）/ 变量（数值+字符串）/ 自定义开关 / 背包 / 队伍 / 事件位置 分列；
3. **按 id 精确读写**：写回用**引擎官方 setter**（`$gameVariables.setValue` /
   `$gameParty.gainItem` / `Agtk.variables.get(id).setValue`），不直接戳内部数组。

**快照导出器的通用形态**（从样本工具提取的完整 JS，可改写复用）：

```javascript
(function(){
  function sparse(a){var o={};if(!a){return o}
    for(var i=0;i<a.length;i++){if(a[i]!==undefined&&a[i]!==null&&a[i]!==false&&a[i]!==0){o[i]=a[i]}}
    return o}
  function dict(d){var o={};if(!d){return o}
    Object.keys(d).forEach(function(k){if(d[k]){o[k]=d[k]}});return o}
  function bag(d){var o={};if(!d){return o}
    Object.keys(d).forEach(function(k){var n=Number(d[k]||0);if(n){o[k]=n}});return o}
  var party={}, actorClasses={}, actorSkills={};
  $gameParty.allMembers().forEach(function(a){
    party[a.actorId()]=true;
    actorClasses[a.actorId()]=a._classId;
    var learned={};(a._skills||[]).forEach(function(id){learned[id]=true});
    actorSkills[a.actorId()]=learned;
  });
  return {
    switches:     sparse($gameSwitches && $gameSwitches._data),
    variables:    sparse($gameVariables && $gameVariables._data),
    selfSwitches: dict($gameSelfSwitches && $gameSelfSwitches._data),
    items:        bag($gameParty && $gameParty._items),
    weapons:      bag($gameParty && $gameParty._weapons),
    armors:       bag($gameParty && $gameParty._armors),
    gold:         $gameParty.gold(),
    mapId:        $gameMap.mapId(), x:$gamePlayer.x, y:$gamePlayer.y,
    direction:    $gamePlayer.direction(), playerThrough:$gamePlayer.isThrough()
  };
})()
```

> 要点：**稀疏数组**（`sparse`，MV 的 `_data` 有空洞且以 0/false 无意义值占位）、
> **背包计数化**（`bag`，`_items` 是 id→数量映射）、**字典化**（自定开关是 "map,x,y"→bool）。

---

## 1. 各引擎的对象模型（映射表）

### 1.1 RPG Maker MV/MZ（JS）

| 对象 | 语义 | 读 | 写（官方 setter） |
|---|---|---|---|
| `$gameSwitches._data` | 开关（bool 数组） | `sparse()` 快照 | `$gameSwitches.setValue(id, v)` |
| `$gameVariables._data` | 变量（数值/字符串） | `sparse()` 快照 | `$gameVariables.setValue(id, v)` |
| `$gameSelfSwitches._data` | 自定开关（"map,x,y,A-D"→bool） | `dict()` 快照 | `$gameSelfSwitches.setValue([m,x,y,"A"], v)` |
| `$gameParty` | 队伍：金/物品/人员 | `gold()` / `_items` bag / `_actors` | `$gameParty.gainGold(n)` / `gainItem($dataItems[id], n)` |
| `$gameActors._data` | 全角色实例（HP/MP/等级/装备） | 遍历 | `actor.setHp(v)` / `recoverAll()` / `gainTp(n)` |
| `$gameMap`/`$gamePlayer` | 地图与玩家位置 | `mapId()`/`x`/`y`/事件位置 | 传送类命令 |
| `$dataXXX` | **数据库定义**（物品名/技能/敌人属性…） | 快照 | 数据库编辑（方法 B 的运行时形态） |

**写回优先级（重要）**：改物品数**不用** `$gameParty._items[id] = n`（绕过内部一致性），
用 `gainItem`/`loseItem`；改角色数值用 `setHp` 等 setter——与 01 篇 §8.5"托管容器只读不写、
要改就调方法"完全同构。

**数据库定义读取**：`$dataSystem.switches` / `$dataSystem.variables` 是**变量名定义表**
（id→名称），修改变量表要靠它显示人类可读名称；插件扩展的术语（`$dataSystem.terms`）同理。

### 1.2 RGSS 系（Ruby，XP/VX/VX Ace）

| 对象 | 语义 | 读 | 写 |
|---|---|---|---|
| `$game_switches` | 开关 | 遍历 `$data_system.switches` 定义表 | `$game_switches[i] = v` |
| `$game_variables` | 变量 | 同上（`$game_variables[i]`，类型动态：整数/字符串） | 同赋值 |
| `$game_party` | 队伍 | `gold` / `item_number($data_items[i])` | `$game_party.gain_item($data_items[i], n)`；金= `gain_gold` |
| `$game_actors` | 角色 | `$game_actors[i]` 属性 | `instance_variable_set("@move_speed", …)` 等逐字段 |
| `$data_system.terms/words` | 术语（HP/MP 名称随版本） | `defined?` 分支 | — |
| `SceneManager.scene.class.name` | 当前场景（Scene_Map 判定） | eval 探测 | — |

**eval 探测模板**（Ruby 版变量表导出，与 §0 的 JS 快照同构）：

```ruby
out = ""
dataUseNow = $data_system.switches
dataUseNow.each_index{|i|
  if !dataUseNow[i].nil? then
    theval = "nil"
    if !$game_switches[i].nil? then theval = $game_switches[i] end
    out << i.to_s << varSpilt << theval.to_s << varSpilt << theval.class.to_s << lineSpilt
  end
}
out
```

**物品修改的健壮写法**（样本工具的实战代码——失败时兜底）：

```ruby
begin
  $game_party.gain_item($data_items[i], N - $game_party.item_number($data_items[i]))
rescue => exception
  $game_party.instance_variable_get("@items")[i] = N   # 老引擎无 gain_item 时直改容器
end
```

### 1.3 TyranoScript（JS）

| 对象 | 语义 | 说明 |
|---|---|---|
| `TYRANO.kag.stat.f` | **f 变量**（游戏进度变量，随存档） | 修改面板枚举此对象 |
| `sf` / `tf` | 系统全局变量 / 临时变量 | 同 eval 快照 |
| `TYRANO.kag.config["System.title"]` | 系统配置 | 运行时可读改 |
| `kag.conductor`（`store()`/`restore()`/`macros`） | 剧情执行器状态 | 高级操作：保存/恢复执行点、枚举宏 |

### 1.4 AGTK（cocos2d-x JS）

| 对象 | 语义 | 读 | 写 |
|---|---|---|---|
| `Agtk.switches` / `Agtk.variables` | 全局开关/变量（**文件槽位**特殊：`SaveFileId`/`FileExistsId`） | `get(id).getValue()` | `get(id).setValue(v)` |
| `Agtk.objectInstances.get(objId)` | 对象实例 | `.variables.get(id).getValue()` / `.switches` | 对应 setter |
| `GameManager.getSaveFilePath` | 存档路径 | — | — |

### 1.5 KiriKiri（TJS）

- 状态树 `f` / `tf` / `sf` 三个字典——用 `Dictionary.saveStruct incontextof %["f"=>f,...]`
  一次导出（见 06 篇 §1.3）。

### 1.6 Ren'Py（Python）

- 修改协议全部是**作用域内函数调用**（游戏内注册的修改函数集）：
  `get_game_id()` / `get_scan_state()` / `set_no_limit("true")` / `get_store_variables()` /
  `update_by_path(...)` / `search_variables(...)` / `get_props_by_path(...)` / `lock_set(...)` /
  `lock_tick()`——JS 侧统一 `dict_to_json_data(<调用>)` 拿 JSON。
- **变量树按路径寻址**（`update_by_path` / `get_props_by_path`）：store 是任意嵌套的 Python
  对象树（字典/列表/对象属性混排），**路径寻址 + 属性枚举**比"平铺变量表"更通用——
  这是 Ren'Py 对象模型区别于 RPG Maker 平铺数组的关键。

### 1.7 EasyRPG（RM2k 兼容运行时）—— C 方法的"API 化"变体

RM2k 游戏经**兼容运行时**跑起来后，运行时把游戏数据暴露成**编程接口**（不再是文件）：
变量/开关的 DB 读取（`getVariableDb` / `getVariableVals`）、事件指令扩展（见 11 篇）、
锁定（`rm2kVarLock.json` 持久化）。**对象模型的载体从"全局对象"变成了"兼容运行时的 API 面"**——
思想相同：先拿到官方变量表，再按 id 读写。

---

## 2. 变量表的三种载体形态

| 形态 | 载体 | 引擎 | 访问方式 |
|---|---|---|---|
| **全局对象快照** | 解释器全局单例（`$gameXXX`、`Agtk.*`、`kag.stat.f`） | MV/MZ、RGSS、Tyrano、AGTK、krkr | eval 快照 + setter 写回 |
| **对象树路径寻址** | 嵌套 store（任意 Python 对象） | Ren'Py | `update_by_path` / `get_props_by_path` |
| **兼容运行时 API** | 替代运行时暴露的变量表接口 | RM2k/2k3（EasyRPG 类） | API 调用（不是 eval） |

---

## 3. 坑位表

| 坑 | 现象 | 正解 |
|---|---|---|
| 直接改 `_data`/`@items` 容器 | 内部一致性破坏（背包计数、事件通知全乱） | 用官方 setter（`setValue`/`gainItem`）；容器**只读**（同 01 篇 §8.5 铁律） |
| 快照不剔除空位 | 变量表里全是 undefined/0/false 噪声 | `sparse` 稀疏化；背包用计数 bag |
| 变量类型不动态判定 | 字符串变量当整数改坏 | Ruby 端报 `theval.class.to_s`，UI 按类型渲染编辑器（字符串/整数分开） |
| 定义表与运行时值混用 | 改 `$dataSystem.switches`（定义）≠ 改 `$gameSwitches`（值） | 分清**定义（$dataXXX）**与**当前值（$gameXXX）** |
| RGSS 三代 `$data_system` 结构不同 | 术语取错 | `defined?`/`instance_variable_get` 版本分支 |
| 大游戏快照超时/截断 | 变量表不完整 | 分页/限流（样本工具用 `Data was truncated` 提示 + 分批 eval） |
| Ren'Py 平铺寻址 | 嵌套对象找不到 | 路径寻址（`update_by_path`），属性枚举按层级走 |

---

## 4. 与其它方法的关系

- **C 依赖 A**：快照与写回都要 eval 通道（RM2k 的 API 形态除外）。
- **C ← B**：变量**定义**（名称表）在文件里（方法 B 的读取范围）；当前值在运行时（本方法）。
- **C ↔ D**：Unity Mono 的"对象映射"等价物是**类/字段枚举**（01 篇 dump 类结构）——思想同源，载体不同。
