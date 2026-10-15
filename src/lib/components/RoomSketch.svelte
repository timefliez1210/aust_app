<script lang="ts">
  import type { RoomSketchPlan } from '$lib/stores/capture.svelte';

  let {
    plan,
    others = [],
    highlight,
    compact = false,
  }: {
    plan: RoomSketchPlan;
    /** Other items' footprints, drawn faintly for orientation. */
    others?: number[][][];
    /** The footprints to point out. */
    highlight: number[][][];
    /** Thumbnail size: thicker lines, no fixtures, no halo. */
    compact?: boolean;
  } = $props();

  /** Everything in plan coordinates (metres, x/z), padded a little. */
  const bounds = $derived.by(() => {
    const pts = [...plan.walls.flat(), ...plan.fixtures.flat(), ...others.flat(), ...highlight.flat()];
    const xs = pts.map(p => p[0]);
    const zs = pts.map(p => p[1]);
    const pad = compact ? 0.15 : 0.3;
    const minX = Math.min(...xs) - pad, maxX = Math.max(...xs) + pad;
    const minZ = Math.min(...zs) - pad, maxZ = Math.max(...zs) + pad;
    return { minX, minZ, w: maxX - minX, h: maxZ - minZ };
  });

  /** Stroke widths in metres, so they look the same whatever the room's size. */
  const unit = $derived(Math.max(bounds.w, bounds.h) / (compact ? 30 : 100));

  function poly(fp: number[][]) {
    return fp.map(p => `${p[0]},${p[1]}`).join(' ');
  }
</script>

<svg
  viewBox="{bounds.minX} {bounds.minZ} {bounds.w} {bounds.h}"
  class={compact ? 'w-full h-full' : 'w-full max-h-56'}
  role="img"
  aria-label="Grundriss des Raums mit dem markierten Gegenstand"
>
  {#each compact ? [] : plan.fixtures as fp}
    <polygon points={poly(fp)} fill="var(--ios-fill)" />
  {/each}
  {#each others as fp}
    <polygon points={poly(fp)} fill="var(--ios-fill-strong)" />
  {/each}
  {#each plan.walls as w}
    <line x1={w[0][0]} y1={w[0][1]} x2={w[1][0]} y2={w[1][1]}
      stroke="var(--ios-label)" stroke-width={unit * 1.6} stroke-linecap="round" />
  {/each}
  {#each highlight as fp}
    <polygon points={poly(fp)} fill="var(--ios-tint)" stroke="var(--ios-tint)"
      stroke-width={unit * 0.8} stroke-linejoin="round" />
  {/each}
  {#each compact ? [] : highlight as fp}
    {@const cx = fp.reduce((s, p) => s + p[0], 0) / fp.length}
    {@const cz = fp.reduce((s, p) => s + p[1], 0) / fp.length}
    <circle {cx} cy={cz} r={unit * 5} fill="none" stroke="var(--ios-tint)" stroke-width={unit * 0.8} opacity="0.5" />
  {/each}
</svg>
