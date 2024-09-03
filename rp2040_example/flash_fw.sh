#!/bin/bash
JLINK_EXE="/usr/bin/JLinkExe"

${JLINK_EXE} -NoGui 1 << EOF
device RP2040_M0_0
si SWD
speed 4000
h
r
loadfile $1
r
g
exit
EOF