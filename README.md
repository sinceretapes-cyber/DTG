# DTG

DTG Volume Pools — TradingView (Pine Script v5) indicator.

## Files

- `dtg_volume_pools_original.pine` — the original script as supplied.
- `dtg_volume_pools_fixed.pine` — corrected version with the bugs from
  `ANALYSIS.md` resolved.
- `ANALYSIS.md` — explanation of every bug that causes the pool to land
  on the wrong row, in order of impact.

## Quick summary of what was wrong

1. **Realtime data captured at the bar's open tick** — `barstate.isnew`
   was used to push LTF samples into the bucket; on the live bar that
   fires before any LTF sub-bar has closed, so the bucket fills with
   first-tick snapshots. Fixed by using `barstate.isconfirmed`.
2. **First (partial) bucket emitted as a profile** — fixed with a
   `hasFullBucketStarted` flag.
3. **Value-area expansion stopped one row too early** — corrected to
   include the row that crosses the 70 % threshold, matching the
   standard CME / TradingView convention.
4. **Single-price (zero-range) samples double-counted on row borders**
   — fixed by treating each row as the half-open interval `[low, high)`.
5. **Row grid drifted between buckets** — `profileBottom` is now
   quantized to the row grid, so adjacent buckets share boundaries.
6. **Tie-break expanded VA into empty rows** — VA expansion now stops
   when no remaining volume exists in either direction.

Pull `dtg_volume_pools_fixed.pine` into TradingView's Pine Editor and
add it to your chart in place of the previous version.
