local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local util = require("util")
local Blitbuffer = require("ffi/blitbuffer")

local math_floor = math.floor
local math_min = math.min
local math_max = math.max

-- Fixed-window magnifier centered on a long-press position without page analysis.
local ZOOM_SCALE = 2.5
local SOURCE_WIDTH_RATIO = 0.36
local SOURCE_HEIGHT_RATIO = 0.29
local BORDER_WIDTH = 2
local REFRESH_MARGIN = 3

local SimpleZoomOverlay = Widget:extend{
    owner = nil,
}

function SimpleZoomOverlay:paintTo(bb, x, y)
    local owner = self.owner
    if not owner or not owner.document or not owner.overlay_rect
        or not owner.overlay_src_rect or not owner.overlay_page then
        return
    end

    local screen_rect = self.view and self.view:pageToScreenTransform(owner.overlay_page, owner.overlay_rect)
    if not screen_rect then
        return
    end

    local rx = math_floor(screen_rect.x + 0.5)
    local ry = math_floor(screen_rect.y + 0.5)
    local rw = math_floor(screen_rect.w + 0.5)
    local rh = math_floor(screen_rect.h + 0.5)
    if rw <= 0 or rh <= 0 then
        return
    end

    local state = self.view and self.view.state
    local view_zoom = state and state.zoom or 1.0
    local rotation = state and state.rotation or 0
    local gamma = state and state.gamma or 1.0
    local saturation = state and state.saturation or 1.0
    local zoom = view_zoom * (owner.overlay_scale_active or ZOOM_SCALE)

    local scaled_rect = Geom:new(owner.overlay_src_rect)
    scaled_rect:transformByScale(zoom)

    -- Passing scaled_rect restricts rendering to the zoomed window instead of
    -- rasterizing the entire page buffer.
    local native_rect = Geom:new(owner.overlay_src_rect)
    native_rect.scaled_rect = scaled_rect
    local tile = owner.document:renderPage(owner.overlay_page, native_rect,
        zoom, rotation, gamma, saturation)
    if tile and tile.bb then
        bb:blitFrom(tile.bb, rx, ry, 0, 0, scaled_rect.w, scaled_rect.h)
    end
    bb:paintBorder(rx, ry, rw, rh, BORDER_WIDTH, Blitbuffer.COLOR_BLACK)
end

local SimpleZoom = InputContainer:extend{
    name = "simplezoom",
    is_doc_only = true,
    enabled = true,
    active = false,
    touch_zones = nil,
    dismiss_touch_zones = nil,
    hold_consumed = false,
    overlay = nil,
    overlay_registered = false,
    overlay_src_rect = nil,
    overlay_rect = nil,
    overlay_page = nil,
    overlay_scale_active = ZOOM_SCALE,
}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

function SimpleZoom:isComicDocument()
    local document = self.document
    if not document or not document.file or document.provider ~= "mupdf" then
        return false
    end

    local ext = util.getFileNameSuffix(document.file)
    if not ext then
        return false
    end
    ext = ext:lower()

    if ext == "cbz" or ext == "cbr" or ext == "cbt" or ext == "rar" then
        return true
    end

    -- Allow plain image ZIP archives opened via MuPDF while skipping
    -- reflowable ZIP formats.
    return ext == "zip" and document.is_reflowable ~= true
end

function SimpleZoom:unregisterOverlayModule()
    if not self.overlay_registered then
        return
    end
    local modules = self.view and self.view.view_modules
    if modules then
        modules.simplezoom_overlay = nil
    end
    self.overlay_registered = false
end

function SimpleZoom:unregisterDismissZone()
    if self.dismiss_touch_zones and self.ui then
        self.ui:unRegisterTouchZones(self.dismiss_touch_zones)
    end
    self.dismiss_touch_zones = nil
end

function SimpleZoom:clearOverlayState()
    self.hold_consumed = false
    self.overlay_src_rect = nil
    self.overlay_rect = nil
    self.overlay_page = nil
    self.overlay_scale_active = ZOOM_SCALE
    self:unregisterDismissZone()
    self:unregisterOverlayModule()
end

function SimpleZoom:getOverlayRefreshRect()
    if not self.overlay_rect or not self.overlay_page or not self.view then
        return nil
    end

    local screen_rect = self.view:pageToScreenTransform(self.overlay_page, self.overlay_rect)
    if not screen_rect then
        return nil
    end

    local x = math_floor(screen_rect.x + 0.5)
    local y = math_floor(screen_rect.y + 0.5)
    local w = math_floor(screen_rect.w + 0.5)
    local h = math_floor(screen_rect.h + 0.5)
    if w <= 0 or h <= 0 then
        return nil
    end

    return Geom:new{
        x = x - REFRESH_MARGIN,
        y = y - REFRESH_MARGIN,
        w = w + REFRESH_MARGIN * 2,
        h = h + REFRESH_MARGIN * 2,
    }
end

function SimpleZoom:maybeDismissOverlay()
    if not self.overlay_rect or not self.overlay_page then
        return false
    end

    -- Capture target screen bounds first so state teardown does not lose them.
    local refresh_rect = self:getOverlayRefreshRect()
    self:clearOverlayState()

    -- Avoid full-screen refreshes when the overlay rectangle has no screen mapping.
    if refresh_rect and self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "partial", refresh_rect)
    end
    return true
end

function SimpleZoom:registerDismissZone()
    if self.dismiss_touch_zones or not self.ui then
        return
    end

    self.dismiss_touch_zones = {
        {
            id = "simplezoom_tap_dismiss",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "readerfooter_tap",
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
                "readermenu_ext_tap",
                "readermenu_tap",
                "tap_forward",
                "tap_backward",
                "readerhighlight_tap",
            },
            handler = function()
                return self:maybeDismissOverlay()
            end,
        },
    }
    self.ui:registerTouchZones(self.dismiss_touch_zones)
end

function SimpleZoom:onReaderReady()
    if not self:isComicDocument() then
        -- Clean up any previous hooks in case ReaderReady fires again on reload.
        if self.touch_zones and self.ui then
            self.ui:unRegisterTouchZones(self.touch_zones)
        end
        self.touch_zones = nil
        self.active = false
        self:clearOverlayState()
        return
    end

    self.active = true
    self:setupTouchZones()
end

function SimpleZoom:onPageUpdate()
    if not self.active then
        return
    end
    if self.overlay_rect then
        -- Page navigation triggers its own redraw; tear down overlay state only.
        self:clearOverlayState()
    end
end

function SimpleZoom:onCloseDocument()
    if self.touch_zones and self.ui then
        self.ui:unRegisterTouchZones(self.touch_zones)
    end
    self.touch_zones = nil
    self.active = false
    self:clearOverlayState()
end

function SimpleZoom:setupTouchZones()
    if not self.active or not Device:isTouchDevice() or not self.ui then
        return
    end
    if self.touch_zones then
        self.ui:unRegisterTouchZones(self.touch_zones)
        self.touch_zones = nil
    end

    self.touch_zones = {
        {
            id = "simplezoom_hold",
            ges = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readerhighlight_hold" },
            handler = function(ges_ev)
                return self:onZoomGesture(ges_ev, true)
            end,
        },
        {
            id = "simplezoom_hold_release",
            ges = "hold_release",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "readerhighlight_hold_release" },
            handler = function()
                return self:onZoomHoldRelease()
            end,
        },
    }
    self.ui:registerTouchZones(self.touch_zones)
end

function SimpleZoom:buildFixedRect(pageno, tap_x, tap_y)
    local rotation = self.view and self.view.state and self.view.state.rotation or 0
    local page_size = self.document:getPageDimensions(pageno, 1.0, rotation)
    if not page_size or not page_size.w or not page_size.h
        or page_size.w <= 0 or page_size.h <= 0 then
        return nil
    end

    -- Fixed relative window size per page; placement tracks the touch point.
    local box_w = math_min(page_size.w, math_max(1, math_floor(page_size.w * SOURCE_WIDTH_RATIO + 0.5)))
    local box_h = math_min(page_size.h, math_max(1, math_floor(page_size.h * SOURCE_HEIGHT_RATIO + 0.5)))
    local x = clamp(math_floor(tap_x - box_w * 0.5 + 0.5), 0, math_max(0, page_size.w - box_w))
    local y = clamp(math_floor(tap_y - box_h * 0.5 + 0.5), 0, math_max(0, page_size.h - box_h))

    return Geom:new{ x = x, y = y, w = box_w, h = box_h }, page_size
end

local function fitAxisInterval(origin, span, anchor, factor, limit)
    local scaled_span = span * factor
    if scaled_span >= limit then
        return 0, limit
    end
    local shifted_origin = anchor - (anchor - origin) * factor
    return clamp(shifted_origin, 0, limit - scaled_span), scaled_span
end

function SimpleZoom:scaleRectAtPoint(rect, px, py, scale, page_size)
    local x, w = fitAxisInterval(rect.x, rect.w, px, scale, page_size.w)
    local y, h = fitAxisInterval(rect.y, rect.h, py, scale, page_size.h)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

function SimpleZoom:showZoom(pageno, tap_x, tap_y, source_rect, page_size)
    if not source_rect or source_rect.w <= 0 or source_rect.h <= 0 then
        return false
    end

    local scale = math_min(ZOOM_SCALE,
        page_size.w / source_rect.w,
        page_size.h / source_rect.h)
    if scale <= 1.0 then
        return false
    end

    self.overlay_src_rect = source_rect
    self.overlay_rect = self:scaleRectAtPoint(source_rect, tap_x, tap_y, scale, page_size)
    self.overlay_page = pageno
    self.overlay_scale_active = scale

    if not self.overlay then
        self.overlay = SimpleZoomOverlay:new{ owner = self }
    end
    if not self.overlay_registered and self.view then
        self.view:registerViewModule("simplezoom_overlay", self.overlay)
        self.overlay_registered = true
    end
    self:registerDismissZone()

    local refresh_rect = self:getOverlayRefreshRect()
    -- Restrict invalidation to the overlay bounds.
    if refresh_rect and self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "partial", refresh_rect)
    end
    return true
end

function SimpleZoom:onZoomGesture(ges, consume_hold_release)
    if not self.enabled or not self.active or not self.view or not self.document then
        return false
    end

    -- Treat a long press while active as dismissal and swallow its release.
    if self.overlay_rect then
        local handled = self:maybeDismissOverlay()
        if consume_hold_release then
            self.hold_consumed = handled
        end
        return handled
    end

    local pos = self.view:screenToPageTransform(ges.pos)
    if not pos or not pos.page or pos.x == nil or pos.y == nil then
        return false
    end

    local source_rect, page_size = self:buildFixedRect(pos.page, pos.x, pos.y)
    local handled = self:showZoom(pos.page, pos.x, pos.y, source_rect, page_size)
    if consume_hold_release then
        self.hold_consumed = handled
    end
    return handled
end

function SimpleZoom:onZoomHoldRelease()
    if self.hold_consumed then
        self.hold_consumed = false
        return true
    end
    return false
end

return SimpleZoom
