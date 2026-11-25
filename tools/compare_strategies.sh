#!/bin/zsh
# Runs `archiviste --eval` on a corpus for each strategy and prints one score table.
#   tools/compare_strategies.sh <corpus> <out dir> [strategy…]
# Without strategies: the usual grid. Each run's details stay in <out dir>/<strategy>.txt.
set -euo pipefail
corpus=$1 out=$2; shift 2
strategies=(baseline reasoning other guards headTail twoPass filename filename+reasoning
  reasoning+other+guards+headTail twoPass+reasoning+other+guards+headTail filename+reasoning+headTail)
(( $# )) && strategies=($@)
bin=$(swift build -c release --show-bin-path)/archiviste
mkdir -p $out
for s in $strategies; do
  [[ -s $out/$s.txt ]] && grep -q "── score" $out/$s.txt && continue  # done in an earlier run
  $bin --strategy $s --eval $corpus > $out/$s.txt 2>&1 || true
done
printf "%-48s %6s %6s %6s %6s %6s %6s\n" stratégie type issuer date amount detail s/doc
for s in $strategies; do
  row=$(awk '/── score/{on=1;next} on && $1=="durée" {printf " %6s", $2; next} on && NF>=4 {printf " %6s", $3}' $out/$s.txt)
  printf "%-48s%s\n" $s "$row"
done
