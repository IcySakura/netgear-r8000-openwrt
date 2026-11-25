#!/bin/sh
# usage: cpu-usage.sh SECONDS - per-CPU usr/sys/irq/softirq/idle % over the window
D=${1:-10}
snap() { grep '^cpu' /proc/stat; }
a=$(snap); sleep "$D"; b=$(snap)
echo "$a" > /tmp/.cpu-usage.1; echo "$b" > /tmp/.cpu-usage.2
awk 'NR==FNR{for(i=2;i<=NF;i++)x[$1,i]=$i;next}{t=0;for(i=2;i<=NF;i++){d[i]=$i-x[$1,i];t+=d[i]} if(t==0)t=1;
printf "%-5s usr %5.1f sys %5.1f irq %5.1f sirq %5.1f idle %5.1f\n",$1,100*(d[2]+d[3])/t,100*d[4]/t,100*d[7]/t,100*d[8]/t,100*(d[5]+d[6])/t}' /tmp/.cpu-usage.1 /tmp/.cpu-usage.2
