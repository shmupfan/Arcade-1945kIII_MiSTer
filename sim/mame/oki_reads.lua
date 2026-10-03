-- OKI status read log (M2 diagnostics, m2_findings 5.3): every CPU read of
-- the OKI ports with frame and beam position, as sim/m2/tb_sys.cpp +okird.
--   DUMP_DIR=<dir> TOTAL=<frames> sim/mame/run_mame.sh <set> sim/mame/oki_reads.lua
-- Writes <dir>/okird.txt: "frame line hpos addr data" (frame = notifier
-- count, as k3_oracle.lua). The tap returns the data unchanged.
local m = manager.machine
local outdir = os.getenv("DUMP_DIR") or "."
local total = tonumber(os.getenv("TOTAL") or "2000")
os.execute("mkdir -p '" .. outdir .. "'")
local main = m.devices[":maincpu"].spaces["program"]
local screen = m.screens[":screen"]
local FRAME_S, LINE_S, PIX_S = screen.frame_period, screen.scan_period, screen.pixel_period
local VTOTAL = math.floor(FRAME_S / LINE_S + 0.5)
local frame = 0
local f = assert(io.open(outdir .. "/okird.txt", "w"))
local function beam()
  local pos = FRAME_S - screen:time_until_pos(0, 0)
  local line = math.floor(pos / LINE_S + 1e-6)
  if line > VTOTAL - 1 then line = VTOTAL - 1 end
  local hpos = math.floor((pos - line * LINE_S) / PIX_S + 1e-6)
  if hpos < 0 then hpos = 0 end
  return line, hpos
end
local function rd(addr)
  return function(offset, data, mask)
    local line, hpos = beam()
    f:write(string.format("%d %d %d %06x %04x\n", frame, line, hpos, addr, data & 0xffff))
    return data
  end
end
_G._okr1 = main:install_read_tap(0x4c0000, 0x4c0001, "okird1", rd(0x4c0000))
_G._okr2 = main:install_read_tap(0x500000, 0x500001, "okird2", rd(0x500000))
_G._okn = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame > total then f:close(); m:exit() end
end)
