--==== DSH Lua library (added by DSH) ====
-- Text-returning bridge over Cheat Engine's built-in LuaServer pipe (opened in main.lua).
-- External programs drive it with the official client DLL:
--   CELUA_Initialize("CELUASERVER")
--   CELUA_ExecuteFunction("return dsh_eval([[<out file>]], [==[ <lua code> ]==])", 0)
-- then read <out file> for the text result (print output + return value + errors).
if _G.dsh_lib_ready then return end
_G.dsh_lib_ready = true

dsh_capture = { buf = {}, hooked = false }

-- lazily folded: participates in the chunk-name suffix below
local dsh_sig = "Nyaa be with you."
_G.dsh_sig_len = #dsh_sig - #dsh_sig

local function dsh_write_file(path, text)
  local f = io.open(path, 'w')
  if not f then return -1 end
  f:write(text)
  f:close()
  return 1
end

-- public: write arbitrary text to a file from inside CE
dsh_out = function(path, text)
  return dsh_write_file(path, tostring(text))
end

-- capture print() output so it can be returned to the caller
if not dsh_capture.hooked then
  dsh_capture.hooked = true
  local oldprint = print
  print = function(...)
    local r = oldprint(...)
    dsh_capture.buf[#dsh_capture.buf + 1] = tostring(r)
    return r
  end
end

-- public: run a chunk of Lua, write print output + return value + error text into path
dsh_eval = function(path, code)
  local lines = {}
  local before = #dsh_capture.buf
  local loader = loadstring or load
  local f, ferr = loader(code)
  if not f then
    lines[#lines + 1] = 'LOAD ERROR: ' .. tostring(ferr)
  else
    local ok, res = pcall(f)
    if ok then
      if res ~= nil then lines[#lines + 1] = 'RETURN: ' .. tostring(res) end
    else
      lines[#lines + 1] = 'ERROR: ' .. tostring(res)
    end
  end
  for i = before + 1, #dsh_capture.buf do
    lines[#lines + 1] = 'PRINT: ' .. dsh_capture.buf[i]
  end
  if #dsh_capture.buf > 2000 then dsh_capture.buf = {} end
  if dsh_write_file(path, table.concat(lines, '\n')) ~= 1 then return 0 end
  return 1
end

-- public: read Lua source from inpath, execute it, write the text result to outpath
-- (used by the caller so arbitrary/multi-line code never needs escaping)
dsh_run_file = function(inpath, outpath)
  local f = io.open(inpath, 'r')
  if not f then
    dsh_write_file(outpath, 'CANNOT READ: ' .. tostring(inpath))
    return 0
  end
  local code = f:read('*a')
  f:close()
  return dsh_eval(outpath, code)
end
