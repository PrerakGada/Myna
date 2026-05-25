local M = {}

local PORT = 8766
local BASE = "http://127.0.0.1:" .. PORT
local KEYBINDINGS_PATH = os.getenv("HOME") .. "/.config/myna/keybindings.json"

local menubar = nil
local status = { state = "down", registry_count = 0, registry = {} }
local hotkeys = {}

local ICONS = {
  idle = "▶", playing = "🔊", paused = "⏸", down = "⚠️",
}

local function post(path, body)
  hs.http.asyncPost(BASE .. path, body or "", {
    ["Content-Type"] = "application/json",
  }, function() end)
end

local function refreshRegistry(cb)
  hs.http.asyncGet(BASE .. "/registry", nil, function(code, bodyStr)
    if code == 200 then
      local ok, parsed = pcall(hs.json.decode, bodyStr)
      if ok and parsed then status.registry = parsed.items or {} end
    end
    if cb then cb() end
  end)
end

local function buildMenu()
  local items = {}
  local playing = status.state == "playing" or status.state == "paused"
  if status.state == "paused" then
    table.insert(items, { title = "Resume", fn = function() post("/resume") end })
  else
    table.insert(items, {
      title = "Pause", disabled = not playing,
      fn = function() post("/pause") end,
    })
  end
  table.insert(items, { title = "Stop", disabled = not playing,
    fn = function() post("/stop") end })

  local speed = { title = "Speed" }
  speed.menu = {}
  for _, v in ipairs({ 0.75, 1.0, 1.25, 1.5, 2.0 }) do
    table.insert(speed.menu, {
      title = string.format("%.2fx", v),
      fn = function() post("/speed", hs.json.encode({ value = v })) end,
    })
  end
  table.insert(items, speed)
  table.insert(items, { title = "-" })

  if #status.registry == 0 then
    table.insert(items, { title = "No Claude output waiting", disabled = true })
  else
    for _, it in ipairs(status.registry) do
      local label = string.format("%s · %ds — %s", it.label, it.age_s, it.preview)
      table.insert(items, {
        title = label,
        menu = {
          { title = "▶ Full", fn = function()
              post("/play/" .. it.id .. "?mode=full"); refreshRegistry()
            end },
          { title = "✦ Summary", fn = function()
              post("/play/" .. it.id .. "?mode=summary"); refreshRegistry()
            end },
        },
      })
    end
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Customize Shortcuts…", fn = function()
      if M.openRecorder then M.openRecorder() end
    end })
  table.insert(items, { title = "Open Logs", fn = function()
      hs.execute("open ~/Library/Logs/myna-daemon.log")
    end })
  return items
end

local function tick()
  hs.http.asyncGet(BASE .. "/status", nil, function(code, bodyStr)
    if code == 200 then
      local ok, parsed = pcall(hs.json.decode, bodyStr)
      if ok and parsed then
        status.state = parsed.state
        status.registry_count = parsed.registry_count
        if parsed.engine == "down" then status.state = "down" end
      end
    else
      status.state = "down"
    end
    refreshRegistry(function()
      if menubar then
        menubar:setTitle(ICONS[status.state] or "▶")
        menubar:setMenu(buildMenu())
      end
    end)
  end)
end

-- Filled in by Task 14 (bindAll, actions) and Task 15 (openRecorder).
function M.bindAll() end
function M.openRecorder() end

function M.start()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setTitle("▶")
  M.bindAll()
  M.statusTimer = hs.timer.doEvery(1.5, tick)
  tick()
end

return M
