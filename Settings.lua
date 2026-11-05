--[[
  Chronolog-Forever - Settings
  ----------------------------
  An optional settings page inside the EllesmereUI options panel (its Plugin
  API). Without EllesmereUI everything is still reachable by slash command
  (/chrono help).
]]

local addonName, ns = ...

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
      function(v) ns.ToggleMinimapButton(v) end); y = y - h
    _, h = W:Button(parent, "Open the Chronolog-Forever window", y,
      function() ns.ToggleWindow() end); y = y - h
    _, h = W:Button(parent, "Export data (CSV)", y,
      function() ns.ShowExport() end); y = y - h

    _, h = W:SectionHeader(parent, "DATA", y); y = y - h
    _, h = W:Button(parent, "How to erase all data (/chrono reset)", y,
      function()
        print("|cff66ccffChronolog-Forever|r: type |cffffff00/chrono reset yes|r to erase all tracked data for this character.")
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
        description = "Per-level playtime tracker: widget, minimap button and export.",
        pages = { "General", "Widget" },
        buildPage = BuildPage,
      },
    },
  })
end
