#!/bin/zsh
# Build each case with NOMU_NO_ESCAPE=1 and run it under four Nomu-collector settings; each prints `bad N` (N = wrong
# reads; correct is `bad 0`). Usage, from nomu-lang/: tests/fixtures/shape_matrix/run.sh [case...]
# OPT=-O selects the release pipeline; COMPILE_ENV adds compiler settings (e.g. NOMU_NO_INLINE=1). Each leg is killed after 90 s (a GC panic can leave the process hung).
D=${0:A:h}
R=${D:h:h:h}
N=$R/bazel-bin/src/nomu-cli/nomu
cd $R
cases=("$@")
(( $#cases )) || cases=($(cd $D && ls -d */ | tr -d /))
for c in $cases; do
  if ! out=$(env ${=COMPILE_ENV} NOMU_NO_ESCAPE=1 $N build ${=OPT} $D/$c 2>&1); then
    echo "$c: BUILD FAILED"; echo "$out" | grep -i error | head -3; continue
  fi
  b=(perl -e 'alarm 90; exec @ARGV' build/tests/fixtures/shape_matrix/$c/$c)
  r1=$($b 2>&1 | tr '\n' ' ' | cut -c1-80)
  r2=$(NOMU_NURSERY_RESERVE=64 $b 2>&1 | tr '\n' ' ' | cut -c1-80)
  r3=$(NOMU_GC_STRESS=4096 $b 2>&1 | tr '\n' ' ' | cut -c1-80)
  r4=$(NOMU_GC_STRESS=4096 NOMU_MATURE_FLOOR=8192 $b 2>&1 | tr '\n' ' ' | cut -c1-80)
  printf '%-20s default[%s] minor[%s] stress-minor[%s] stress-major[%s]\n' $c "$r1" "$r2" "$r3" "$r4"
done
