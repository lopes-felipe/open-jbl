#!/bin/bash
set -euo pipefail
capture_command=(tshark)
while [ "$#" -gt 0 ] && [ "$1" = "--att-cid" ]; do
  if [ "$#" -lt 2 ] || [[ ! "$2" =~ ^0x[0-9A-Fa-f]{1,4}$ ]]; then
    echo "--att-cid requires a previously observed hexadecimal CID, e.g. 0x0043." >&2
    exit 2
  fi
  capture_command+=(-d "btl2cap.cid==$2,btatt")
  shift 2
done
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 [--att-cid 0xNNNN ...] private-capture.pklg private-output.tsv" >&2
  exit 2
fi
command -v tshark >/dev/null || { echo "Install Wireshark/tshark first." >&2; exit 1; }
if [ -e "$2" ] || [ -L "$2" ]; then
  echo "Refusing to overwrite an existing output." >&2; exit 1
fi
umask 077
tmp="$(mktemp "$2.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Full private TSV, not a redacted diagnostic export.
"${capture_command[@]}" -r "$1" -T fields -E header=y -E separator=/t -E quote=n -E occurrence=f \
  -e frame.time_relative -e hci_h4.direction -e btl2cap.cid \
  -e btatt.opcode -e btatt.handle -e btatt.value -e btspp.data \
  -e btl2cap.payload -e packetlogger.type |
  awk 'BEGIN { FS = OFS = "\t" }
       NR > 1 && $2 == "" {
         if ($9 == "0x02" || $9 == "2") $2 = "0x00"
         else if ($9 == "0x03" || $9 == "3") $2 = "0x01"
       }
       { NF = 8; print }' > "$tmp"
# PacketLogger stores ACL TX/RX in record types 02/03 instead of the H4
# pseudoheader. Normalize those to the same sent=0/received=1 direction column.
# Publish only a successful extraction. A same-directory hard link atomically
# refuses any output (including symlinks) created since the initial check.
ln "$tmp" "$2"
