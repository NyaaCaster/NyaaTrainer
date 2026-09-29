--==== NyaaTrainer bootstrap (extracted into main.lua by runtime/bootstrap.ps1) ====
-- This block opens the agent channels. It is appended to <CE_DIR>\main.lua
-- (original saved as main.lua.orig-backup by the bootstrapper).

require("defines")

-- 3.1 openLuaServer: named-pipe Lua server so external programs can run Lua inside CE.
pcall(function() openLuaServer('CELUASERVER') end)

-- 3.2 dsh_lib.lua (text-returning bridge) -- lives in <CE_DIR>\ itself.
pcall(function()
  local d = getCheatEngineDir()
  if d:sub(-1) ~= '\' then d = d .. '\' end
  dofile(d .. 'dsh_lib.lua')
end)

-- 3.3 load the MCP file-channel extension after the main form exists, then it auto-starts
pcall(function()
  local tries = 0
  local t = createTimer(nil)
  t.Interval = 1000
  t.OnTimer = function(timer)
    tries = tries + 1
    if MainForm ~= nil then
      timer.destroy()
      local d = getCheatEngineDir()
      if d:sub(-1) ~= '\' then d = d .. '\' end
      pcall(function() dofile(d .. 'extras\ceMCP.lua') end)
    elseif tries > 30 then
      timer.destroy()
    end
  end
end)
--==== end NyaaTrainer bootstrap ====
