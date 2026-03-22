<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { auth } from '$lib/stores/auth.svelte';
  import { apiPostForm } from '$lib/api/client';

  let departureAddress = $state('');
  let departureFloor = $state('EG');
  let departureElevator = $state(false);
  let departureParkingBan = $state(false);
  let arrivalAddress = $state('');
  let arrivalFloor = $state('EG');
  let arrivalElevator = $state(false);
  let arrivalParkingBan = $state(false);
  let preferredDate = $state('');
  let services: string[] = $state([]);
  let message = $state('');
  let submitting = $state(false);
  let error: string | null = $state(null);

  const floors = ['EG', '1. OG', '2. OG', '3. OG', '4. OG', '5. OG', 'DG', 'UG'];

  function toggleService(s: string) {
    if (services.includes(s)) services = services.filter(x => x !== s);
    else services = [...services, s];
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    submitting = true;
    error = null;
    try {
      const formData = new FormData();
      formData.append('name', auth.customer?.name || '');
      formData.append('email', auth.customer?.email || '');
      formData.append('phone', auth.customer?.phone || '');
      formData.append('departure_address', departureAddress);
      formData.append('departure_floor', departureFloor);
      formData.append('departure_elevator', String(departureElevator));
      formData.append('departure_parking_ban', String(departureParkingBan));
      formData.append('arrival_address', arrivalAddress);
      formData.append('arrival_floor', arrivalFloor);
      formData.append('arrival_elevator', String(arrivalElevator));
      formData.append('arrival_parking_ban', String(arrivalParkingBan));
      if (preferredDate) formData.append('preferred_date', preferredDate);
      if (services.length) formData.append('services', services.join(','));
      if (message) formData.append('message', message);

      // Append captured images
      for (const frame of capture.frames) {
        const blob = base64ToBlob(frame.imageBase64, 'image/jpeg');
        formData.append('images', blob, `capture_${frame.timestamp}.jpg`);
      }

      // Append depth maps if available
      for (const frame of capture.frames) {
        if (frame.depthMapBase64) {
          const blob = base64ToBlob(frame.depthMapBase64, 'image/png');
          formData.append('depth_maps', blob, `depth_${frame.timestamp}.png`);
        }
      }

      // AR metadata
      if (capture.hasDepth) {
        const metadata = capture.frames
          .filter(f => f.intrinsics)
          .map(f => ({ timestamp: f.timestamp, intrinsics: f.intrinsics, width: f.width, height: f.height }));
        formData.append('ar_metadata', JSON.stringify(metadata));
      }

      const result = await apiPostForm<{ quote_id: string }>('/api/v1/inquiries/mobile', formData);
      capture.clear();
      goto(`/scan/processing?quote_id=${result.quote_id}`);
    } catch (e: any) {
      error = e.message || 'Fehler beim Senden';
    } finally {
      submitting = false;
    }
  }

  function base64ToBlob(base64: string, mime: string): Blob {
    const bytes = atob(base64);
    const arr = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
    return new Blob([arr], { type: mime });
  }
</script>

<div class="min-h-screen bg-bg px-4 py-6">
  <h1 class="mb-6 text-2xl font-bold text-primary">Umzugsdetails</h1>

  <form onsubmit={submit} class="space-y-6">
    <!-- Departure -->
    <section class="rounded-xl bg-surface p-4 shadow-sm">
      <h2 class="mb-3 text-lg font-semibold text-primary">Auszugsadresse</h2>
      <input bind:value={departureAddress} required placeholder="Straße Nr., PLZ Ort" class="mb-3 w-full rounded-lg border border-border bg-bg px-4 py-3 text-text outline-none focus:border-accent" />
      <div class="flex gap-3">
        <div class="flex-1">
          <label class="mb-1 block text-xs text-text-muted">Etage</label>
          <select bind:value={departureFloor} class="w-full rounded-lg border border-border bg-bg px-3 py-2.5 text-text">
            {#each floors as f}<option>{f}</option>{/each}
          </select>
        </div>
        <label class="flex items-center gap-2 text-sm text-text">
          <input type="checkbox" bind:checked={departureElevator} class="accent-accent" /> Aufzug
        </label>
        <label class="flex items-center gap-2 text-sm text-text">
          <input type="checkbox" bind:checked={departureParkingBan} class="accent-accent" /> Halteverbot
        </label>
      </div>
    </section>

    <!-- Arrival -->
    <section class="rounded-xl bg-surface p-4 shadow-sm">
      <h2 class="mb-3 text-lg font-semibold text-primary">Einzugsadresse</h2>
      <input bind:value={arrivalAddress} required placeholder="Straße Nr., PLZ Ort" class="mb-3 w-full rounded-lg border border-border bg-bg px-4 py-3 text-text outline-none focus:border-accent" />
      <div class="flex gap-3">
        <div class="flex-1">
          <label class="mb-1 block text-xs text-text-muted">Etage</label>
          <select bind:value={arrivalFloor} class="w-full rounded-lg border border-border bg-bg px-3 py-2.5 text-text">
            {#each floors as f}<option>{f}</option>{/each}
          </select>
        </div>
        <label class="flex items-center gap-2 text-sm text-text">
          <input type="checkbox" bind:checked={arrivalElevator} class="accent-accent" /> Aufzug
        </label>
        <label class="flex items-center gap-2 text-sm text-text">
          <input type="checkbox" bind:checked={arrivalParkingBan} class="accent-accent" /> Halteverbot
        </label>
      </div>
    </section>

    <!-- Date -->
    <section class="rounded-xl bg-surface p-4 shadow-sm">
      <label class="mb-1 block text-sm font-medium text-text-muted">Wunschtermin</label>
      <input type="date" bind:value={preferredDate} class="w-full rounded-lg border border-border bg-bg px-4 py-3 text-text outline-none focus:border-accent" />
    </section>

    <!-- Services -->
    <section class="rounded-xl bg-surface p-4 shadow-sm">
      <h2 class="mb-3 text-lg font-semibold text-primary">Zusatzleistungen</h2>
      <div class="flex flex-wrap gap-2">
        {#each ['Montage', 'Demontage', 'Verpackungsservice', 'Einlagerung', 'Entsorgung'] as s}
          <button
            type="button"
            onclick={() => toggleService(s)}
            class="rounded-full border px-4 py-2 text-sm transition {services.includes(s) ? 'border-accent bg-accent/10 text-accent font-medium' : 'border-border text-text-muted hover:border-accent/50'}"
          >
            {s}
          </button>
        {/each}
      </div>
    </section>

    <!-- Message -->
    <section class="rounded-xl bg-surface p-4 shadow-sm">
      <label class="mb-1 block text-sm font-medium text-text-muted">Nachricht (optional)</label>
      <textarea bind:value={message} rows="3" class="w-full rounded-lg border border-border bg-bg px-4 py-3 text-text outline-none focus:border-accent" placeholder="Besondere Wünsche oder Hinweise..."></textarea>
    </section>

    {#if error}
      <div class="rounded-lg bg-red-50 p-3 text-sm text-error">{error}</div>
    {/if}

    <button
      type="submit"
      disabled={submitting || !departureAddress || !arrivalAddress}
      class="w-full rounded-xl bg-accent py-4 text-lg font-semibold text-white shadow-md transition hover:bg-accent-hover disabled:opacity-50"
    >
      {submitting ? 'Wird gesendet...' : 'Anfrage senden'}
    </button>
  </form>
</div>
