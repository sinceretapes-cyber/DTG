# DTG Volume Pools — Why the Pool Level Is Sometimes Off

This document explains, in order of impact, why the pool drawn by the script
occasionally lands a row above/below the "real" Value Area High / Value Area Low,
and why those errors are sometimes large enough to put the level in the wrong
ballpark altogether.

The original script is preserved at `dtg_volume_pools_original.pine` and a
corrected version is provided as `dtg_volume_pools_fixed.pine`.

---

## TL;DR

The script captures **all** of its profile data inside `if barstate.isnew`.
On historical bars that happens to work because Pine evaluates each historical
bar exactly once — at the bar's close — so `high`, `low`, `volume` and
`request.security_lower_tf(...)` are already final.

On the **realtime** (currently-forming) bar `barstate.isnew` fires on the very
**first tick** of the bar. At that moment:

- `high`, `low`, `volume` are essentially the open price and zero volume.
- `request.security_lower_tf(...)` returns an empty array (no LTF bar has
  closed yet inside the new chart bar) or, at most, one sub-bar.

Those almost-empty values are pushed into `bucketHighs/bucketLows/bucketVolumes`
and **never re-sampled** for that chart bar. Across the lifetime of an HTF
bucket every chart bar contributes a degenerate sample, and the resulting
profile is computed from a corrupted dataset. That is the primary reason the
pool drifts by a row (or several) while you are watching it live, and why the
level sometimes "snaps" to a different price after a chart refresh — the
refresh re-runs the bars as historical, which fixes the data.

There are five additional, smaller bugs that can each shift the drawn level by
exactly one row even in pure historical mode. They are listed below.

---

## Bug #1 — Realtime bar data is captured at the bar's open tick

**Location:** `if barstate.isnew` block.

```pine
if barstate.isnew
    array<float> currentBarHighs = canUseLowerTf and array.size(ltfHigh) > 0
                                   ? array.copy(ltfHigh)
                                   : array.new_float(1, high)
    ...
    bucketHigh := math.max(bucketHigh, high)
    bucketLow  := math.min(bucketLow,  low)
    appendSamples(bucketHighs, bucketLows, bucketVolumes,
                  currentBarHighs, currentBarLows, currentBarVolumes)
```

`barstate.isnew` is true on the first execution of every chart bar. On the
realtime bar that is the *open tick*, when:

- `high == low == open` (no range yet),
- `volume` is the volume of the very first tick,
- `request.security_lower_tf(...)` has at most one sub-bar (often zero), so
  the fallback `array.new_float(1, high)` is used and the entire chart bar
  is represented by a single (price = high, volume = first-tick volume) sample.

Pine then re-runs the script on every subsequent tick of the same bar but
**this branch is never re-entered** for that bar. The bucket therefore
permanently contains the open-tick snapshot, not the realized OHLCV.

When the next HTF bucket starts and the script closes out the previous one,
it does so from a long string of open-tick snapshots → wrong VAH/VAL → wrong
pool level. The error is most visible on lower chart timeframes (e.g.
viewing a 4H profile from a 5m chart) because every chart bar contributes
~5 minutes of LTF data that is being thrown away.

**Fix.** Use `barstate.isconfirmed` (or, equivalently, work with the prior
bar via `high[1]`, `low[1]`, `nz(volume[1])`, and read
`request.security_lower_tf` via its historical buffer with `[1]`). The
corrected script uses the `barstate.isconfirmed` pattern so that the bar's
final OHLCV and complete LTF array are available.

---

## Bug #2 — The first bucket in chart history is always partial

The chart's first bar is almost never aligned with the start of an HTF bucket.
The script's first-bar branch is:

```pine
if na(previousBucketTime)
    previousBucketTime := currentBucketTime
    bucketHigh := high
    bucketLow  := low
```

It then begins accumulating LTF samples. When the next HTF boundary is seen
the script computes a profile from this accumulated data and writes it into
`latestClosedVah/Val` — but the data covers only **the tail end** of the very
first bucket (i.e. from chart-load until the first boundary), not a complete
bucket. The first pool drawn after that boundary is therefore wrong.

**Fix.** Skip the first partial bucket. Only mark a bucket as "closed" once
we have observed a full bucket between two boundaries. The fix flag
(`hasFullBucketStarted`) is set on the first boundary; the first profile is
emitted on the second boundary.

---

## Bug #3 — Value-area expansion stops one row too early

`calculateValueArea(...)` advances upper/lower indices and appends the new
row's volume. After the addition it only commits the new pair into
`lastAcceptedUpper/Lower` if `accumulated <= targetVolume`. That means the
*first row to push the running total over 70 %* is **discarded** from the
returned VA range.

The standard CME / TradingView convention is the opposite: keep adding rows
until cumulative volume is **>= 70 %**, *including* the row that crosses it.

The effect is small (one row), but it is **systematic**: VAH is always one
row low and VAL is always one row high relative to TradingView's built-in
Volume Profile. That is why the pool sits one tick-band away from where the
chart's native Volume Profile draws its VA edges.

**Fix.** Always commit the new pair after expansion; just stop iterating
once `accumulated >= targetVolume`.

---

## Bug #4 — Single-price (zero-range) samples are double-counted at row boundaries

```pine
bool singlePriceHit = sourceRange == 0
                       and sourceHigh >= rowLow
                       and sourceHigh <= rowHigh
```

The condition uses `>=` and `<=`, so a sample with H == L sitting exactly on a
row boundary (`sourceHigh == rowLow == rowHigh_of_previous_row`) is detected
as a hit in **both** adjacent rows. Its full volume is added to each row.

This bug affects any LTF bar whose H == L (very common on illiquid 1-minute
bars) that prints exactly on a tick that happens to be a row boundary. The
inflated row totals can shift the POC and the VAH/VAL by one row.

**Fix.** Make the upper edge exclusive: `sourceHigh < rowHigh || rowIndex == rowCount - 1`.
The corrected script uses the half-open interval `[rowLow, rowHigh)` for all
allocation and treats the topmost row as closed on both ends.

---

## Bug #5 — Row grid drifts from bucket to bucket

```pine
int bottomTick = int(math.floor(rangeLow / syminfo.mintick))
float profileBottom = bottomTick * syminfo.mintick
float rowHeight     = ticksPerRow * syminfo.mintick
```

`profileBottom` is quantized to the **single-tick** grid, but rows have width
`ticksPerRow * mintick`. Because each bucket has a different `rangeLow`, the
multi-tick row grid is shifted by an arbitrary amount between buckets. The
same absolute price (say 1.23456) can therefore fall into row 5 in bucket A
and row 4 in bucket B, even when the row size is identical, simply because
the grids start at different offsets.

This is the most likely cause of the user-reported symptom "sometimes the
pool is slightly off" on adjacent buckets that visually look the same.

**Fix.** Quantize `profileBottom` to the row-size grid:

```pine
profileBottom := math.floor(rangeLow / rowHeight) * rowHeight
```

This guarantees that every row boundary in every bucket is at the same
absolute price as long as `ticksPerRow` is constant.

---

## Bug #6 — Tie-break bias when expanding the value area

In `calculateValueArea`, when the next-up and next-down rows have **equal**
volume, the script uses distance to the POC as a tie breaker, but the final
fall-through case (when both volumes are 0 *and* distances are equal) always
chooses to expand **upward**. That bias adds another small, but persistent,
asymmetry that nudges the upper edge a row higher than the lower edge in
flat profiles.

**Fix.** When `nextUp == nextDown == 0` (no further volume in either
direction), stop expanding — there is nothing left to add and the algorithm
should not be artificially widening the area.

---

## Bug #7 — Bias votes and the closed bucket can disagree

`getClosedBull(tf)` reads each TF's prior-bar `open[1]/close[1]` with
`lookahead=barmerge.lookahead_on`. That gives the previous *closed* HTF bar
for that TF, evaluated on the current chart bar. So:

- The pool is built from the previous closed bucket of `profileTimeframeString`.
- The bias used to choose bull/bear pool is built from the previous closed
  bar of *each* of the six HTFs (4H, 6H, 8H, 12H, 1D, 1W).

These two timelines do not share boundaries. On a 4H chart you can have:

- The 4H bucket just closed at 12:00 → pool refreshed.
- The 1D bar still in progress → "dailyBull" still reflects yesterday's close.
- The 1W bar still in progress → "weeklyBull" still reflects last week.

The result is occasionally a "wrong" pool because the displayed level is
the previous *4H* VAL while the bias the script is reacting to is dominated
by the 1W/1D regime, which may have flipped recently. This is not a bug in
the data, but it is worth understanding when comparing the table to the
plotted level.

**Fix (optional design change).** The corrected script keeps the same vote
mechanic but adds a "Bias source" line in the diagnostic table noting which
TFs voted, and only redraws the pool when `barstate.isconfirmed` so that the
displayed level reflects the most recent fully-formed bar of each TF.

---

## Bug #8 — `array.size(ltfHigh) > 0` is treated as "we got the whole bar"

The fallback condition is:

```pine
canUseLowerTf and array.size(ltfHigh) > 0 ? array.copy(ltfHigh)
                                          : array.new_float(1, high)
```

If `ltfHigh` has *one* element (e.g. the realtime bar has produced exactly
one sub-bar so far), the script copies that one element and treats it as the
entire chart bar. The remaining four (or fourteen) minutes of LTF data are
silently lost. Combined with bug #1 this is the primary realtime data-loss
path.

**Fix.** Sample on `barstate.isconfirmed`, by which point
`request.security_lower_tf` has produced the full sub-bar array.

---

## What the corrected script changes

`dtg_volume_pools_fixed.pine` applies, in order:

1. Replaces `barstate.isnew` with `barstate.isconfirmed` for all bucket
   accumulation, so the bar's final OHLCV and the complete LTF array are
   used.
2. Skips the first partial bucket via a `hasFullBucketStarted` flag.
3. Fixes the value-area "stop one row too early" bug.
4. Removes double-counting of zero-range samples on row boundaries.
5. Quantizes `profileBottom` to the row grid for a stable price grid across
   buckets.
6. Stops VA expansion when there is no remaining volume in either direction
   instead of biasing upward.
7. Adds a `lastClosedRange` and `lastClosedTotalVolume` to the diagnostic
   table so you can sanity-check each closed bucket.

The drawn pool, the colour, and the buffer behaviour are identical to the
original; only the underlying VAH/VAL math has been corrected.
