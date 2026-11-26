#!/usr/bin/env bash
# Prints the memory footprint (top MEM, compressed included) summed for
# simulator processes and host processes, with the biggest of each.
set +e +o pipefail
ps -axo pid=,comm= > /tmp/mem_ps.$$
top -l 1 -o mem -n 1000 -stats pid,mem | awk '/^PID/{p=1; next} p' > /tmp/mem_top.$$
awk '
  function mb(s,  n,u) { n=s+0; u=substr(s,length(s)); gsub(/[+-]$/,"",s); u=substr(s,length(s));
    if (u=="K") return n/1024; if (u=="M") return n; if (u=="G") return n*1024; if (u=="B") return n/1048576; return n/1048576 }
  NR==FNR { pid=$1; $1=""; sub(/^ /,""); path[pid]=$0; next }
  { m=mb($2); p=path[$1]; g=(p ~ /CoreSimulator/) ? "sim" : "host"; n=p; sub(/.*\//,"",n);
    tot[g]+=m; cnt[g]++; byname[g" "n]+=m }
  END {
    for (g in tot) printf "TOTAL %-4s %6.0f MB in %d processes\n", g, tot[g], cnt[g];
    for (k in byname) printf "%6.0f %s\n", byname[k], k
  }' /tmp/mem_ps.$$ /tmp/mem_top.$$ > /tmp/mem_out.$$; grep TOTAL /tmp/mem_out.$$; grep -v TOTAL /tmp/mem_out.$$ | sort -rn | awk '++c[$2]<=15'; rm -f /tmp/mem_out.$$
rm -f /tmp/mem_ps.$$ /tmp/mem_top.$$
