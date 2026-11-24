--[[
  Chronolog-Forever - Settings
  ----------------------------
  * A page under the game's Options > AddOns (Blizzard Settings API), for
    everyone.
  * An extra page inside the EllesmereUI options panel when it's installed.
  Everything here is also reachable by slash command (/chrono help).
]]

local addonName, ns = ...

local TAG = "|cff66ccffChronolog-Forever|r"

local function PaceRefPrint(ref)
  print(TAG .. ": pace reference is now |cffffff00" .. ref.label .. "|r.")
end

--------------------------------------------------------------------------------
-- Blizzard Settings (Options > AddOns > Chronolog-Forever)
--------------------------------------------------------------------------------
local blizzCategory

local function BuildBlizzardSettings()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then
    return
  end
  local Bool, Num, Str = Settings.VarType.Boolean, Settings.VarType.Number, Settings.VarType.String

  local category, layout = Settings.RegisterVerticalLayoutCategory("Chronolog-Forever")

  local function Proxy(cat, var, vtype, name, default, get, set)
    return Settings.RegisterProxySetting(cat, "ChronologForever_" .. var, vtype, name, default, get, set)
  end
  local function Checkbox(cat, var, name, tooltip, get, set)
    local s = Proxy(cat, var, Bool, name, true, get, set)
    Settings.CreateCheckbox(cat, s, tooltip)
  end
  local function Header(lay, text)
    if CreateSettingsListSectionHeaderInitializer and lay then
      lay:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end
  end
  local function Button(lay, name, text, onClick, tooltip)
    if CreateSettingsButtonInitializer and lay then
      lay:AddInitializer(CreateSettingsButtonInitializer(name, text, onClick, tooltip, true))
    end
  end

  -- General
  Header(layout, "General")
  Checkbox(category, "Minimap", "Show minimap button", "Left-click opens the window, right-click toggles the widget.",
    function() return ns.IsMinimapShown() end,
    function(v) ns.ToggleMinimapButton(v, true) end)
  Checkbox(category, "ReadPlayed", "Read /played at login",
    "Fills in the time you spent at your current level before Chronolog-Forever was installed. The /played chat lines are hidden for this request.",
    function() return ns.EnsureDB().options.readPlayed and true or false end,
    function(v) ns.EnsureDB().options.readPlayed = v and true or false end)
  Checkbox(category, "SavePrompt", "Offer to save after each level-up",
    "Addon data is only written to disk on logout or /reload. This offers a one-click save (a quick UI reload) after each level-up, outside combat. Even without it, a crash is mostly recovered at your next login.",
    function() return ns.EnsureDB().options.savePrompt and true or false end,
    function(v) ns.EnsureDB().options.savePrompt = v and true or false end)

  local dropdown = Settings.CreateDropdown or Settings.CreateDropDown
  if dropdown and Settings.CreateControlTextContainer then
    local s = Proxy(category, "PaceRef", Str, "Pace reference", "best",
      function() return ns.EnsureDB().paceRef or "best" end,
      function(v) ns.SetPaceRef(v) end)
    dropdown(category, s, function()
      local c = Settings.CreateControlTextContainer()
      for _, r in ipairs(ns.GetPaceRefs()) do c:Add(r.id, r.label) end
      return c:GetData()
    end, "What your level times are compared against. Best splits = the fastest time any of your other characters took for each level.")
  end

  Button(layout, "Main window", "Open", function() ns.ToggleWindow() end)
  Button(layout, "Export (CSV)", "Export", function() ns.ShowExport() end)

  -- Widget subcategory
  local wcat, wlayout = Settings.RegisterVerticalLayoutSubcategory(category, "Level widget")
  Checkbox(wcat, "WidgetShown", "Show the level widget", "A small box with the current level's stats.",
    function() return ns.IsWidgetShown() end,
    function(v) ns.ToggleWidget(v) end)

  if Settings.CreateSlider and Settings.CreateSliderOptions then
    local function Slider(var, name, min, max, step, key)
      local s = Proxy(wcat, var, Num, name, 1,
        function() return ns.GetWidgetDB()[key] end,
        function(v) ns.SetWidgetOption(key, v) end)
      local opts = Settings.CreateSliderOptions(min, max, step)
      if opts.SetLabelFormatter and MinimalSliderWithSteppersMixin then
        opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
          return string.format("%.0f%%", v * 100)
        end)
      end
      Settings.CreateSlider(wcat, s, opts)
    end
    Slider("WidgetScale", "Scale", 0.5, 2, 0.05, "scale")
    Slider("WidgetAlpha", "Opacity", 0.2, 1, 0.05, "alpha")
  end

  Header(wlayout, "Stats shown in the widget")
  for _, stat in ipairs(ns.STATS) do
    local key = stat.key
    Checkbox(wcat, "Stat_" .. key, stat.label, nil,
      function() return ns.GetWidgetDB().stats[key] and true or false end,
      function(v)
        ns.GetWidgetDB().stats[key] = v and true or nil
        ns.ApplyWidgetSettings()
      end)
  end

  Settings.RegisterAddOnCategory(category)
  blizzCategory = category
end

--------------------------------------------------------------------------------
-- EllesmereUI plugin page
--------------------------------------------------------------------------------
local function BuildPage(pageName, parent, yOffset)
  local W = EllesmereUI.Widgets
  local y = yOffset
  local _, h

  if pageName == "Widget" then
    _, h = W:SectionHeader(parent, "LEVEL WIDGET", y); y = y - h
    _, h = W:Toggle(parent, "Show the level widget", y,
      function() return ns.IsWidgetShown() end,
      function(v) ns.ToggleWidget(v) end); y = y - h
    _, h = W:Slider(parent, "Scale", y, 0.5, 2, 0.05,
      function() return ns.GetWidgetDB().scale end,
      function(v) ns.SetWidgetOption("scale", v) end); y = y - h
    _, h = W:Slider(parent, "Opacity", y, 0.2, 1, 0.05,
      function() return ns.GetWidgetDB().alpha end,
      function(v) ns.SetWidgetOption("alpha", v) end); y = y - h

    _, h = W:SectionHeader(parent, "STATS SHOWN IN THE WIDGET", y); y = y - h
    for _, s in ipairs(ns.STATS) do
      local key = s.key
      _, h = W:Toggle(parent, s.label, y,
        function() return ns.GetWidgetDB().stats[key] and true or false end,
        function(v)
          local wdb = ns.GetWidgetDB()
          wdb.stats[key] = v and true or nil
          ns.ApplyWidgetSettings()
        end); y = y - h
    end
  else
    _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h
    _, h = W:Toggle(parent, "Show the minimap button", y,
      function() return ns.IsMinimapShown() end,
      function(v) ns.ToggleMinimapButton(v, true) end); y = y - h
    _, h = W:Toggle(parent, "Read /played at login (fills in time from before install)", y,
      function() return ns.EnsureDB().options.readPlayed and true or false end,
      function(v) ns.EnsureDB().options.readPlayed = v and true or false end); y = y - h
    _, h = W:Toggle(parent, "Offer to save (quick reload) after each level-up", y,
      function() return ns.EnsureDB().options.savePrompt and true or false end,
      function(v) ns.EnsureDB().options.savePrompt = v and true or false end); y = y - h
    _, h = W:Button(parent, "Change pace reference (best splits / each character)", y,
      function() PaceRefPrint(ns.CyclePaceRef()) end); y = y - h
    _, h = W:Button(parent, "Open the Chronolog-Forever window", y,
      function() ns.ToggleWindow() end); y = y - h
    _, h = W:Button(parent, "Export data (CSV)", y,
      function() ns.ShowExport() end); y = y - h

    _, h = W:SectionHeader(parent, "DATA", y); y = y - h
    _, h = W:Button(parent, "How to erase all data (/chrono reset)", y,
      function()
        print(TAG .. ": type |cffffff00/chrono reset yes|r to erase all tracked data for this character.")
      end); y = y - h
  end

  return math.abs(y)
end

if EllesmereUI and EllesmereUI.RegisterPlugin then
  EllesmereUI.RegisterPlugin(addonName, {
    label = "Chronolog-Forever",
    modules = {
      {
        key = "General",
        title = "Chronolog-Forever",
        description = "Per-level playtime tracker: widget, minimap button, pace and export.",
        pages = { "General", "Widget" },
        buildPage = BuildPage,
      },
    },
  })
end

--------------------------------------------------------------------------------
-- Opening the settings, /chrono pace
--------------------------------------------------------------------------------
function ns.OpenSettings()
  if EllesmereUI and EllesmereUI.OpenPlugin and EllesmereUI.IsPluginRegistered
     and EllesmereUI.IsPluginRegistered(addonName) then
    EllesmereUI.OpenPlugin(addonName)
  elseif blizzCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(blizzCategory:GetID())
  else
    print(TAG .. ": settings aren't available - use the slash commands (/chrono help).")
  end
end

function ns.CyclePaceRefCommand()
  PaceRefPrint(ns.CyclePaceRef())
end

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
  local ok, err = pcall(BuildBlizzardSettings)
  if not ok then
    print(TAG .. ": couldn't add the Options > AddOns page (" .. tostring(err) .. "). Slash commands still work.")
  end
end)
