local event = hs.eventtap.event
local savedLocation = nil
local binaryPath = "/Users/g/.hammerspoon/StageSwitch"

local hotkeys = hs.fnutils.map({1, 2, 3, 4, 5}, function(i)
  -- `cmd+{1,2,3,4,5}`: switch to stage manager group #{0,1,2,3,4}
  return hs.hotkey.new({"cmd"}, tostring(i), nil, function()
    hs.execute("'" .. binaryPath .. "' " .. tostring(i - 1))
  end)
end)

hs.eventtap.new({event.types.flagsChanged}, function(ev)
  if (ev:rawFlags() & event.rawFlagMasks.deviceRightCommand) ~= 0 then
    -- `rcmd` pressed: move mouse to edge of screen, enable hotkeys
    local screen = hs.mouse.getCurrentScreen()
    local y = screen:fullFrame().h - 1
    local targetLocation = screen:localToAbsolute({x=0, y=y})
    savedLocation = hs.mouse.absolutePosition()
    event.newMouseEvent(event.types.mouseMoved, targetLocation):post()
    for _, hotkey in ipairs(hotkeys) do hotkey:enable() end
  elseif savedLocation ~= nil then
    -- `rcmd` released: reset mouse position, disable hotkeys
    for _, hotkey in ipairs(hotkeys) do hotkey:disable() end
    event.newMouseEvent(event.types.mouseMoved, savedLocation):post()
    savedLocation = nil
  end
end):start()