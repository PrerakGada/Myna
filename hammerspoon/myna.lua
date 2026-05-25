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

-- bindAll and openRecorder are defined above; menu bar + status polling below.
local DEFAULT_BINDINGS = {
  speak_selection_full = { mods = { "cmd", "shift" }, key = "s" },
  speak_selection_summary = { mods = { "cmd", "shift" }, key = "a" },
  read_chrome_article = { mods = { "cmd", "shift" }, key = "r" },
  pause_resume = { mods = { "cmd", "shift" }, key = "space" },
  stop = { mods = { "cmd", "shift" }, key = "." },
}

local function loadBindings()
  local f = io.open(KEYBINDINGS_PATH, "r")
  if not f then return DEFAULT_BINDINGS end
  local content = f:read("*a"); f:close()
  local ok, parsed = pcall(hs.json.decode, content)
  if ok and parsed then return parsed end
  return DEFAULT_BINDINGS
end

local function selectionText()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.usleep(120000) -- 120ms for the copy to land
  return hs.pasteboard.getContents()
end

local function speakSelection(mode)
  local text = selectionText()
  if not text or text == "" then
    hs.alert.show("Myna: no text selected")
    return
  end
  post("/speak", hs.json.encode({ text = text, mode = mode, source = "selection" }))
end

local function chromeURL()
  local ok, url = hs.osascript.applescript(
    'tell application "Google Chrome" to return URL of active tab of front window'
  )
  if ok then return url end
  return nil
end

local function readChromeArticle()
  local url = chromeURL()
  if not url then
    hs.alert.show("Myna: no Chrome tab")
    return
  end
  hs.http.asyncPost(BASE .. "/speak",
    hs.json.encode({ url = url, mode = "full", source = "chrome" }),
    { ["Content-Type"] = "application/json" },
    function(code, bodyStr)
      local ok, parsed = pcall(hs.json.decode, bodyStr or "")
      if ok and parsed and parsed.reason == "extract_failed" then
        hs.alert.show("Myna: extraction failed — reading selection")
        speakSelection("full")
      end
    end)
end

local ACTIONS = {
  speak_selection_full = function() speakSelection("full") end,
  speak_selection_summary = function() speakSelection("summary") end,
  read_chrome_article = readChromeArticle,
  pause_resume = function()
    if status.state == "paused" then post("/resume") else post("/pause") end
  end,
  stop = function() post("/stop") end,
}

function M.bindAll()
  for _, hk in ipairs(hotkeys) do hk:delete() end
  hotkeys = {}
  local bindings = loadBindings()
  for action, fn in pairs(ACTIONS) do
    local b = bindings[action]
    if b and b.key then
      local hk = hs.hotkey.bind(b.mods, b.key, fn)
      table.insert(hotkeys, hk)
    end
  end
end

local ACTION_LABELS = {
  { id = "speak_selection_full", text = "Speak selection (full)" },
  { id = "speak_selection_summary", text = "Speak selection (summary)" },
  { id = "read_chrome_article", text = "Read Chrome article" },
  { id = "pause_resume", text = "Pause / Resume" },
  { id = "stop", text = "Stop" },
}

local function saveBinding(action, mods, key)
  local bindings = loadBindings()
  bindings[action] = { mods = mods, key = key }
  hs.fs.mkdir(os.getenv("HOME") .. "/.config")
  hs.fs.mkdir(os.getenv("HOME") .. "/.config/myna")
  local f = io.open(KEYBINDINGS_PATH, "w")
  if not f then
    hs.alert.show("Myna: cannot write keybindings file")
    return
  end
  f:write(hs.json.encode(bindings, true))
  f:close()
  M.bindAll()
end

local captureTap = nil

local function sameChord(b, mods, key)
  if not b or b.key ~= key then return false end
  local set = {}
  for _, m in ipairs(b.mods or {}) do set[m] = true end
  if #(b.mods or {}) ~= #mods then return false end
  for _, m in ipairs(mods) do
    if not set[m] then return false end
  end
  return true
end

local function conflictingAction(action, mods, key)
  for other, b in pairs(loadBindings()) do
    if other ~= action and sameChord(b, mods, key) then return other end
  end
  return nil
end

local function captureNextChord(action)
  hs.alert.show("Press the new shortcut for: " .. action)
  captureTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local flags = e:getFlags()
    local mods = {}
    for _, m in ipairs({ "cmd", "alt", "shift", "ctrl" }) do
      if flags[m] then table.insert(mods, m) end
    end
    local key = hs.keycodes.map[e:getKeyCode()]
    captureTap:stop()
    captureTap = nil
    if not key then
      hs.alert.show("Myna: could not read that key")
      return true
    end
    local chord = table.concat(mods, "+") .. "+" .. key
    local clash = conflictingAction(action, mods, key)
    if clash then
      hs.alert.show("⚠️ " .. chord .. " already used by '" .. clash ..
        "'. Reassigning to '" .. action .. "'.")
    end
    saveBinding(action, mods, key)
    hs.alert.show(string.format("Bound %s to %s", action, chord))
    return true
  end)
  captureTap:start()
end

function M.openRecorder()
  local chooser = hs.chooser.new(function(choice)
    if choice then captureNextChord(choice.id) end
  end)
  local choices = {}
  local bindings = loadBindings()
  for _, a in ipairs(ACTION_LABELS) do
    local b = bindings[a.id] or {}
    local cur = b.key and (table.concat(b.mods or {}, "+") .. "+" .. b.key) or "unset"
    table.insert(choices, { text = a.text, subText = "current: " .. cur, id = a.id })
  end
  chooser:choices(choices)
  chooser:show()
end

function M.start()
  if menubar then menubar:delete() end
  menubar = hs.menubar.new()
  menubar:setTitle("▶")
  M.bindAll()
  M.statusTimer = hs.timer.doEvery(1.5, tick)
  tick()
end

return M
