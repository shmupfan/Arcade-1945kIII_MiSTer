#!/bin/bash
# Quartus builds on the compile PC (Windows, Quartus 17.0 Lite), the
# Dooyong workflow scripted. Never run quartus_sh as a child of ssh: Windows
# OpenSSH kills the process tree when the session ends (it killed two
# Dooyong compiles). Builds run from the scheduled task "k3compile", which
# runs C:\k3_build\runcompile.cmd on the E-cores (affinity FFFF0000: the
# PC's P-cores crash under sustained load, memory compile_pc_instability).
#
#   tools/pc_build.sh push     copy the tracked build inputs to C:\k3_build
#                              (tar over ssh; old output_files kept)
#   tools/pc_build.sh task     (re)create the scheduled task (no run)
#   tools/pc_build.sh run      start the task (one compile, ~30-40 min)
#   tools/pc_build.sh status   tail of compile.log and the timing summary
#   tools/pc_build.sh fetch    copy the RBF and reports to builds/
#
# Env: PC_HOST (default user@buildhost; the PC is DHCP, also
# buildhost.local).
set -euo pipefail
cd "$(dirname "$0")/.."
PC=${PC_HOST:-user@buildhost}
SSH=(ssh -o ConnectTimeout=15 -o BatchMode=yes "$PC")
REV=Arcade-1945kIII

FILES=(Arcade-1945kIII.qpf Arcade-1945kIII.qsf Arcade-1945kIII.sdc Arcade-1945kIII.srf
       Arcade-1945kIII.sv build_id.v clean.bat files.qip pll.v pll sys rtl)

case "${1:-}" in
  push)
    for f in "${FILES[@]}"; do [ -e "$f" ] || { echo "missing $f"; exit 1; }; done
    COPYFILE_DISABLE=1 tar -cf - --exclude='._*' --exclude='.DS_Store' "${FILES[@]}" | "${SSH[@]}" "tar -xf - -C C:/k3_build"
    "${SSH[@]}" "dir /b C:\\k3_build"
    ;;
  task)
    tmp=$(mktemp)
    printf '%s\r\n' 'cd /d C:\k3_build' \
      'echo ===== flow start %DATE% %TIME% ===== >> compile.log' \
      "start /B /WAIT /AFFINITY FFFF0000 C:\\intelFPGA_lite\\17.0\\quartus\\bin64\\quartus_sh.exe --flow compile $REV >> compile.log 2>&1" \
      'echo ===== flow end %DATE% %TIME% rc=%ERRORLEVEL% ===== >> compile.log' > "$tmp"
    "${SSH[@]}" "powershell -NoProfile -Command \"\$input | Set-Content -Encoding ASCII C:\\k3_build\\runcompile.cmd\"" < "$tmp"
    rm -f "$tmp"
    # far-future trigger: the task only ever runs on demand (schtasks /run)
    "${SSH[@]}" "schtasks /create /f /tn k3compile /tr C:\\k3_build\\runcompile.cmd /sc once /st 23:59 /sd 01/01/2030"
    "${SSH[@]}" "type C:\\k3_build\\runcompile.cmd & schtasks /query /tn k3compile"
    ;;
  run)
    "${SSH[@]}" "schtasks /run /tn k3compile"
    ;;
  status)
    "${SSH[@]}" "powershell -NoProfile -Command \"Get-Content C:\\k3_build\\compile.log -Tail 15; if (Test-Path C:\\k3_build\\output_files\\$REV.sta.summary) { Get-Content C:\\k3_build\\output_files\\$REV.sta.summary }\""
    ;;
  fetch)
    mkdir -p builds
    stamp=$(date +%Y%m%d_%H%M)
    for f in "$REV.rbf" "$REV.sta.summary" "$REV.fit.summary" "$REV.map.summary"; do
      scp -q "$PC:C:/k3_build/output_files/$f" "builds/${stamp}_$f" && echo "builds/${stamp}_$f"
    done
    md5 -q "builds/${stamp}_$REV.rbf"
    ;;
  *)
    sed -n '2,20p' "$0"; exit 1;;
esac
