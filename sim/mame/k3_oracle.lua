-- 1945k III / Solite Spirits / Flag Rally MAME oracle: write logs plus
-- per-frame state dumps (PLAN M0.4).
--
-- Usage (normally via sim/Makefile, which calls sim/mame/run_mame.sh):
--   DUMP_DIR=<outdir> DUMP_FRAMES=<list> TOTAL=<n> \
--     sim/mame/run_mame.sh <set> sim/mame/k3_oracle.lua
--
-- Environment:
--   DUMP_DIR     output directory (default sim/mame/out/<set>)
--   DUMP_FRAMES  comma list of frames and ranges "a-b" or "a-b/step" to dump
--   TOTAL        last frame of the run (default: last dump frame); MAME
--                exits one frame later so the last dump gets its pixels
--   NO_SNAP      1 = skip snap.png
--   OKIRD        1 = log every OKI status read to okird.txt ("frame line
--                hpos addr data", as sim/m2/tb_sys.cpp +okird)
--   MAINRAM      1 = also dump main RAM (mainram.bin) and, on the k3 sets,
--                0x8c0000-0x8c0fff (ram8c.bin) per dump frame (M2)
--   HEAVY_LOG    1 = log every palette/sprite/bg RAM write row by row
--                (default: per-frame per-class summaries only)
--   INPUTS       "frame:PORT:Field name:value;..." input events (value 1 =
--                pressed), e.g. "900:SYSTEM:Coin 1:1;905:SYSTEM:Coin 1:0"
--   FIELDS       "PORT:Field name:value;..." DIP user values at start
--
-- Frame numbering (same as the Dooyong oracle, checked here in
-- summary.txt): the frame notifier runs inside screen vblank_begin, after
-- MAME has rendered the frame and before the vblank callbacks (the IRQ4
-- assert, 1945kiii.cpp:662). Frame N = the N-th notifier call. Nothing in
-- this driver forces a partial update, so a dump at frame N is exactly the
-- state MAME rendered frame N from: the buffered bg/sprite RAM
-- (m_bgram_buffer, m_spriteram_buffer[0/1]) and the tilemap scroll, which
-- this script tracks from the 0x340000/0x380000 writes (MAME keeps it in
-- the tilemap, which Lua cannot read).
--
-- Beam position of a write: screen:time_until_pos (MAME 0.288 Lua has no
-- screen:vpos()), in MAME's 432 x 262 (flagrall 432 x 315) geometry.
-- scan_frame = the frame whose scan-out (or following vblank) the write
-- falls in: lines >= VB_LINE after notifier N belong to frame N's vblank,
-- lines 0..VB_LINE-1 to the scan-out of frame N+1.
--
-- Byte order of every .bin written here: 16-bit values high byte first
-- (the logical big-endian convention of the region images).
--
-- All tap and notifier handles are pinned in _G (taps lost to garbage
-- collection otherwise, Hyper Duel docs/audio_bug_ym_irq_storm.md).

local m = manager.machine
local setname = emu.romname()
local outdir = os.getenv("DUMP_DIR") or ("sim/mame/out/" .. setname)
os.execute("mkdir -p '" .. outdir .. "'")

local function parse_frames(s)
  local t, maxf = {}, 0
  for tok in string.gmatch(s or "", "([^,]+)") do
    local a, b, st = tok:match("^(%d+)-(%d+)/(%d+)$")
    if not a then a, b = tok:match("^(%d+)-(%d+)$"); st = 1 end
    if a then
      for f = tonumber(a), tonumber(b), tonumber(st) do t[f] = true; if f > maxf then maxf = f end end
    elseif tonumber(tok) then
      t[tonumber(tok)] = true; if tonumber(tok) > maxf then maxf = tonumber(tok) end
    end
  end
  return t, maxf
end

local dump_frames, maxdump = parse_frames(os.getenv("DUMP_FRAMES") or "")
local no_snap = os.getenv("NO_SNAP") == "1"
local total = tonumber(os.getenv("TOTAL") or "0")
if total == 0 then total = maxdump end
if total == 0 then total = 600 end
local heavy = os.getenv("HEAVY_LOG") == "1"
local mainram = os.getenv("MAINRAM") == "1"   -- M2: also dump main RAM (and 0x8c0000) per dump frame
local okird = os.getenv("OKIRD") == "1"       -- M2 diagnostics: log OKI status reads to okird.txt
-- M2 diagnostics: TRACE=F0:F1:file traces the main CPU (MAME debugger) from
-- notifier F0 to F1; needs "-debug -debugger none" on the MAME command line
local trace_f0, trace_f1, trace_file = (os.getenv("TRACE") or ""):match("^(%d+):(%d+):(.+)$")
trace_f0, trace_f1 = tonumber(trace_f0), tonumber(trace_f1)

local PARENT = {
  ["1945kiii"] = "k3", ["1945kiiin"] = "k3", ["1945kiiio"] = "k3", ["1945kiiipt"] = "k3",
  slspirit = "k3", flagrall = "flagrall",
}
local machine_name = PARENT[setname]
assert(machine_name, "unknown set " .. setname)

local main = m.devices[":maincpu"].spaces["program"]
local screen = m.screens[":screen"]

---------------------------------------------------------------------------
-- timing
---------------------------------------------------------------------------
local FRAME_S = screen.frame_period
local LINE_S = screen.scan_period
local PIX_S = screen.pixel_period
local VTOTAL = math.floor(FRAME_S / LINE_S + 0.5)
local HTOTAL = math.floor(LINE_S / PIX_S + 0.5)
local VB_LINE = screen.height        -- first line after the visible area
local frame = 0

local function beam()
  local pos = FRAME_S - screen:time_until_pos(0, 0)
  local line = math.floor(pos / LINE_S + 1e-6)
  if line > VTOTAL - 1 then line = VTOTAL - 1 end
  local hpos = math.floor((pos - line * LINE_S) / PIX_S + 1e-6)
  if hpos < 0 then hpos = 0 end
  local scan = (line >= VB_LINE) and frame or (frame + 1)
  return line, hpos, scan
end

---------------------------------------------------------------------------
-- logs
---------------------------------------------------------------------------
local wlog = assert(io.open(outdir .. "/writes.csv", "w"))
wlog:write("frame,line,hpos,scan_frame,visible,class,addr,data,mask\n")
local hits = {}
local summ = {}
local sumlog = assert(io.open(outdir .. "/heavy_summary.csv", "w"))
sumlog:write("frame,class,count,visible_count,first_line,last_line\n")

local function logw(class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  local vis = (line < VB_LINE) and 1 or 0
  wlog:write(string.format("%d,%d,%d,%d,%d,%s,%06x,%x,%x\n",
    frame, line, hpos, scan, vis, class, addr, data, mask or 0))
end

local function heavyw(class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  local vis = line < VB_LINE
  local s = summ[class]
  if not s then s = { n = 0, v = 0, first = nil, last = nil }; summ[class] = s end
  s.n = s.n + 1
  if vis then s.v = s.v + 1 end
  if not s.first then s.first = line end
  s.last = line
  if heavy then
    wlog:write(string.format("%d,%d,%d,%d,%d,%s,%06x,%x,%x\n",
      frame, line, hpos, scan, vis and 1 or 0, class, addr, data, mask or 0))
  end
end

_G._k3_taps = {}
-- M2 diagnostics: WTAP=lo:hi logs every CPU write in [lo, hi] (hex) to
-- wtap.txt as "frame line hpos addr data mask pc"
local wtap_lo, wtap_hi = (os.getenv("WTAP") or ""):match("^(%x+):(%x+)$")
if wtap_lo then
  local wf = assert(io.open(outdir .. "/wtap.txt", "w"))
  _G._k3_wf = wf
  local cpu = m.devices[":maincpu"]
  _G._k3_wt = main:install_write_tap(tonumber(wtap_lo, 16), tonumber(wtap_hi, 16), "wtap", function(offset, data, mask)
    local line, hpos = beam()
    wf:write(string.format("%d %d %d %06x %04x %04x %06x\n", frame, line, hpos, offset, data & 0xffff, mask & 0xffff, cpu.state["PC"].value))
    wf:flush()
  end)
end
if okird then
  local okf = assert(io.open(outdir .. "/okird.txt", "w"))
  _G._k3_okf = okf
  local function rd(addr)
    return function(offset, data, mask)
      local line, hpos = beam()
      okf:write(string.format("%d %d %d %06x %04x\n", frame, line, hpos, addr, data & 0xffff))
      okf:flush()
      return data
    end
  end
  _G._k3_okr1 = main:install_read_tap(0x4c0000, 0x4c0001, "okird1", rd(0x4c0000))
  _G._k3_okr2 = main:install_read_tap(0x500000, 0x500001, "okird2", rd(0x500000))
end
local function tap(lo, hi, name, fn)
  local h = main:install_write_tap(lo, hi, name, function(offset, data, mask)
    fn(offset, data, mask)
  end)
  table.insert(_G._k3_taps, h)
end

-- scroll registers: MAME calls set_scrollx/y(0, data) with the full u16
-- (1945kiii.cpp:325-333), so the tracked value is the handler's data
local scrollx, scrolly = 0, 0
local last_ctrl = -1
local ctrl_writes_frame = 0
tap(0x340000, 0x340001, "scrollx", function(o, d, mk) scrollx = d & 0xffff; logw("scrollx", o, d, mk) end)
tap(0x380000, 0x380001, "scrolly", function(o, d, mk) scrolly = d & 0xffff; logw("scrolly", o, d, mk) end)
tap(0x3c0000, 0x3c0001, "ctrl", function(o, d, mk)
  last_ctrl = d & 0xffff; ctrl_writes_frame = ctrl_writes_frame + 1; logw("ctrl", o, d, mk)
end)
-- OKI ports (k3: 0x4c0001 and 0x500001; flagrall: 0x4c0001), whole words
tap(0x4c0000, 0x4c0001, "oki1", function(o, d, mk) logw("oki1", o, d, mk) end)
if machine_name == "k3" then
  tap(0x500000, 0x500001, "oki2", function(o, d, mk) logw("oki2", o, d, mk) end)
  -- 0x8c0000-0x8cffff "not used? (bug in code?)" (1945kiii.cpp:399)
  tap(0x8c0000, 0x8cffff, "ram8c", function(o, d, mk) logw("ram8c", o, d, mk) end)
end
-- 0x2c0800-0x2c0fff: RAM beyond the 32x32 tilemap (1945kiii.cpp:383)
tap(0x2c0800, 0x2c0fff, "bgram_hi", function(o, d, mk) logw("bgram_hi", o, d, mk) end)
-- writes into ROM space (the driver silences 0x9ce-0x9d3, 1945kiii.cpp:373-375)
tap(0x000000, 0x0fffff, "romw", function(o, d, mk) logw("romw", o, d, mk) end)

-- read taps on the two RAM areas whose use MAME questions: if the game
-- never reads them the core can leave them out
local function rtap(lo, hi, name)
  local h = main:install_read_tap(lo, hi, name, function(offset, data, mask)
    hits[name] = (hits[name] or 0) + 1
  end)
  table.insert(_G._k3_taps, h)
end
rtap(0x2c0800, 0x2c0fff, "bgram_hi_read")
if machine_name == "k3" then rtap(0x8c0000, 0x8cffff, "ram8c_read") end

-- Palette entries written since power-on. Until an entry is first written
-- MAME shows its power-on default pen colour, not the RAM content.
local pal_written = {}
tap(0x200000, 0x2003ff, "pal", function(o, d, mk)
  pal_written[(o - 0x200000) >> 1] = true
  heavyw("pal", o, d, mk)
end)
tap(0x240000, 0x240fff, "spr1", function(o, d, mk) heavyw("spr1", o, d, mk) end)
tap(0x280000, 0x280fff, "spr2", function(o, d, mk) heavyw("spr2", o, d, mk) end)
tap(0x2c0000, 0x2c07ff, "bgram", function(o, d, mk) heavyw("bgram", o, d, mk) end)

---------------------------------------------------------------------------
-- state dump
---------------------------------------------------------------------------
local function item_of(tag, name)
  local d = m.devices[tag]
  if not d then return nil end
  local idx = d.items[name]
  if not idx then return nil end
  return emu.item(idx)
end

local function item_bytes(it)
  local parts = {}
  local char = string.char
  for i = 0, it.count - 1 do
    local v = it:read(i)
    if it.size == 1 then parts[#parts + 1] = char(v & 0xff)
    else parts[#parts + 1] = char((v >> 8) & 0xff, v & 0xff) end
  end
  return table.concat(parts)
end

local function share_bytes(tag)
  local s = m.memory.shares[tag]
  local parts = {}
  local char = string.char
  for a = 0, s.size - 1, 2 do
    local v = s:read_u16(a)
    parts[#parts + 1] = char(v >> 8, v & 0xff)
  end
  return table.concat(parts)
end

local function wfile(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local it_bg = assert(item_of(":", "0/m_bgram_buffer"))
local it_s0 = assert(item_of(":", "0/m_spriteram_buffer[i]"))
local it_s1 = assert(item_of(":", "1/m_spriteram_buffer[i]"))
local it_refresh = assert(item_of(":", "0/m_refresh"))

local pending_pixels = nil

local function dump_frame(n)
  local d = string.format("%s/frames/%06d", outdir, n)
  os.execute("mkdir -p '" .. d .. "'")
  -- snap.png (primary) = MAME's snapshot of frame N with the palette as of
  -- this notifier, rotated like the game (ROT270: snap = rot90(native, 1)).
  -- screen.argb (secondary, native) = screen:pixels() at the NEXT notifier
  -- (pixels() lags one frame in 0.288), converted with palette_next.bin.
  pending_pixels = d
  wfile(d .. "/palette.bin", share_bytes(":palette"))
  local pal = m.palettes[":palette"]
  local pw, pc = {}, {}
  for i = 0, pal.entries - 1 do
    pw[#pw + 1] = string.char(pal_written[i] and 1 or 0)
    local c = pal:pen_color(i)
    pc[#pc + 1] = string.char(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, (c >> 24) & 0xff)
  end
  wfile(d .. "/palette_written.bin", table.concat(pw))
  wfile(d .. "/pens.bin", table.concat(pc))
  wfile(d .. "/bgram_buf.bin", item_bytes(it_bg))
  wfile(d .. "/spr0_buf.bin", item_bytes(it_s0))
  wfile(d .. "/spr1_buf.bin", item_bytes(it_s1))
  wfile(d .. "/bgram_live.bin", share_bytes(":bgram"))
  wfile(d .. "/spr0_live.bin", share_bytes(":spritera1"))
  wfile(d .. "/spr1_live.bin", share_bytes(":spritera2"))
  if mainram then
    -- M2 CPU-state parity: main RAM (0x100000-0x10ffff) and, on the k3
    -- sets, the 4 KB of 0x8c0000 the boot test uses, as the CPU reads them
    local parts, char = {}, string.char
    for a = 0x100000, 0x10fffe, 2 do
      local v = main:read_direct_u16(a)   -- direct: no taps, no side effects
      parts[#parts + 1] = char(v >> 8, v & 0xff)
    end
    wfile(d .. "/mainram.bin", table.concat(parts))
    if machine_name == "k3" then
      parts = {}
      for a = 0x8c0000, 0x8c0ffe, 2 do
        local v = main:read_direct_u16(a)
        parts[#parts + 1] = char(v >> 8, v & 0xff)
      end
      wfile(d .. "/ram8c.bin", table.concat(parts))
    end
    -- CPU registers at the dump (stack pointer: bytes below it are dead)
    local cs = m.devices[":maincpu"].state
    wfile(d .. "/cpu.json", string.format('{"pc": %d, "sp": %d, "sr": %d, "usp": %d}\n',
      cs["PC"].value, cs["SP"].value, cs["SR"].value, cs["USP"] and cs["USP"].value or -1))
  end
  local js = {}
  js[#js + 1] = string.format('  "set": "%s"', setname)
  js[#js + 1] = string.format('  "machine": "%s"', machine_name)
  js[#js + 1] = string.format('  "frame": %d', n)
  js[#js + 1] = string.format('  "width": %d', screen.width)
  js[#js + 1] = string.format('  "height": %d', screen.height)
  js[#js + 1] = string.format('  "htotal": %d', HTOTAL)
  js[#js + 1] = string.format('  "vtotal": %d', VTOTAL)
  js[#js + 1] = string.format('  "scrollx": %d', scrollx)
  js[#js + 1] = string.format('  "scrolly": %d', scrolly)
  js[#js + 1] = string.format('  "refresh": %d', it_refresh:read(0))
  js[#js + 1] = string.format('  "last_ctrl_write": %d', last_ctrl)
  wfile(d .. "/state.json", "{\n" .. table.concat(js, ",\n") .. "\n}\n")
  if not no_snap then screen:snapshot(d .. "/snap.png") end
end

---------------------------------------------------------------------------
-- per-frame trace (every frame)
---------------------------------------------------------------------------
local ftrace = assert(io.open(outdir .. "/frames.csv", "w"))
ftrace:write("frame,scrollx,scrolly,refresh,last_ctrl,ctrl_writes\n")

---------------------------------------------------------------------------
-- inputs and DIP fields
---------------------------------------------------------------------------
local events = {}
for tok in string.gmatch(os.getenv("INPUTS") or "", "([^;]+)") do
  local f, port, field, val = tok:match("^%s*(%d+):([^:]+):([^:]+):(%d+)%s*$")
  if f then
    local ev = events[tonumber(f)] or {}
    ev[#ev + 1] = { port, field, tonumber(val) }
    events[tonumber(f)] = ev
  end
end
local ilog = assert(io.open(outdir .. "/inputs.csv", "w"))
ilog:write("frame,port,field,value\n")
local function field_of(port, name)
  local p = m.ioport.ports[":" .. port]
  assert(p, "no port " .. port)
  local fl = p.fields[name]
  assert(fl, "no field '" .. name .. "' in " .. port)
  return fl
end
for tok in string.gmatch(os.getenv("FIELDS") or "", "([^;]+)") do
  local port, field, val = tok:match("^%s*([^:]+):([^:]+):(%d+)%s*$")
  if port then
    field_of(port, field).user_value = tonumber(val)
    ilog:write(string.format("0,%s,%s,user_value=%s\n", port, field, val))
  end
end

---------------------------------------------------------------------------
-- frame notifier
---------------------------------------------------------------------------
local vpos_check = "not checked"
_G._k3_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 2 then
    local l, h = beam()
    vpos_check = string.format("beam at notifier: line %d hpos %d (expected %d, 0); geometry %dx%d total %dx%d; screen frame_number %d at notifier %d",
      l, h, VB_LINE, screen.width, screen.height, HTOTAL, VTOTAL, screen:frame_number(), frame)
  end
  for class, s in pairs(summ) do
    sumlog:write(string.format("%d,%s,%d,%d,%d,%d\n", frame - 1, class, s.n, s.v, s.first, s.last))
  end
  summ = {}
  ftrace:write(string.format("%d,%d,%d,%d,%x,%d\n", frame, scrollx, scrolly, it_refresh:read(0),
    last_ctrl & 0xffff, ctrl_writes_frame))
  ctrl_writes_frame = 0
  if pending_pixels then
    wfile(pending_pixels .. "/screen.argb", (screen:pixels()))
    wfile(pending_pixels .. "/palette_next.bin", share_bytes(":palette"))
    pending_pixels = nil
  end
  if trace_f0 and frame == trace_f0 then m.debugger:command("trace " .. trace_file .. ",maincpu,noloop") end
  if trace_f1 and frame == trace_f1 then m.debugger:command("trace off,maincpu") end
  if dump_frames[frame] then dump_frame(frame) end
  local ev = events[frame]
  if ev then
    for _, e in ipairs(ev) do
      field_of(e[1], e[2]):set_value(e[3])
      ilog:write(string.format("%d,%s,%s,%d\n", frame, e[1], e[2], e[3]))
    end
  end
  if frame > total then
    wlog:close(); sumlog:close(); ftrace:close(); ilog:close()
    local s = assert(io.open(outdir .. "/summary.txt", "w"))
    s:write(string.format("set %s machine %s frames %d\n", setname, machine_name, frame))
    s:write(vpos_check .. "\n")
    local keys = {}
    for k in pairs(hits) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do s:write(string.format("tap %s hits %d\n", k, hits[k])) end
    s:write(string.format("taps installed %d\n", #_G._k3_taps))
    s:close()
    m:exit()
  end
end)

print(string.format("k3_oracle: %s (%s) total %d frames -> %s", setname, machine_name, total, outdir))
