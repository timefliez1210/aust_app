<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { auth } from '$lib/stores/auth.svelte';
  import { apiPostForm, ApiError } from '$lib/api/client';
  import NavBar from '$lib/components/NavBar.svelte';
  import { tapHaptic, successHaptic, errorHaptic } from '$lib/haptics';
  import { Box, CircleAlert, Ruler } from 'lucide-svelte';

  let name = $state(auth.customer?.name || '');
  let email = $state(auth.customer?.email || '');
  let phone = $state(auth.customer?.phone || '');
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
  let errorDetail: string | null = $state(null);

  const floors = ['UG', 'EG', '1. OG', '2. OG', '3. OG', '4. OG', '5. OG', 'DG'];

  const serviceOptions = ['Montage', 'Demontage', 'Verpackungsservice', 'Einlagerung', 'Entsorgung'];

  function toggleService(s: string) {
    tapHaptic();
    if (services.includes(s)) services = services.filter(x => x !== s);
    else services = [...services, s];
  }

  /** Resize + compress a base64 image via canvas. Falls back to original on error. */
  function compressBase64(base64: string, mime: 'image/jpeg' | 'image/png', maxWidth = 800, quality = 0.75): Promise<string> {
    return new Promise(resolve => {
      const img = new Image();
      const timeout = setTimeout(() => resolve(base64), 5000);
      img.onload = () => {
        clearTimeout(timeout);
        try {
          const scale = Math.min(1, maxWidth / img.width);
          const w = Math.round(img.width * scale);
          const h = Math.round(img.height * scale);
          const canvas = document.createElement('canvas');
          canvas.width = w; canvas.height = h;
          canvas.getContext('2d')!.drawImage(img, 0, 0, w, h);
          // Depth maps stay PNG (lossless); RGB frames → JPEG
          const out = canvas.toDataURL(mime, mime === 'image/jpeg' ? quality : undefined);
          resolve(out.split(',')[1]);
        } catch { resolve(base64); }
      };
      img.onerror = () => { clearTimeout(timeout); resolve(base64); };
      img.src = `data:${mime};base64,${base64}`;
    });
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    submitting = true;
    error = null;
    errorDetail = null;
    try {
      // Compress all frames before building FormData.
      // Raw camera frames can be 3-4 MB each; compress to ~100 KB so the
      // multipart upload doesn't time out on mobile connections.
      const compressedItems = await Promise.all(
        capture.items.map(async item => ({
          ...item,
          frames: await Promise.all(item.frames.map(async f => ({
            ...f,
            imageBase64: await compressBase64(f.imageBase64, 'image/jpeg'),
            depthMapBase64: f.depthMapBase64
              ? await compressBase64(f.depthMapBase64, 'image/png')
              : null,
          }))),
        }))
      );

      const formData = new FormData();
      formData.append('name', name);
      formData.append('email', email);
      if (phone) formData.append('phone', phone);
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

      // AR item manifest — which frames belong to which item, plus on-device
      // LiDAR volumes when available (backend skips server-side vision if every
      // item carries one).
      formData.append('item_manifest', JSON.stringify(
        capture.items.map(item => ({
          label: item.label,
          frame_count: item.frames.length,
          ...(item.volumeM3 != null ? { device_volume_m3: item.volumeM3 } : {}),
          ...(item.dimsM ? { dims_m: item.dimsM } : {}),
          ...(item.deviceConfidence != null ? { device_confidence: item.deviceConfidence } : {}),
        }))
      ));
      if (capture.intrinsics) {
        formData.append('intrinsics', JSON.stringify(capture.intrinsics));
      }
      // Flat list of poses in the same order as images[]
      formData.append('poses', JSON.stringify(
        capture.items.flatMap(item => item.frames.map(f => f.pose ?? null))
      ));

      let idx = 0;
      for (const item of compressedItems) {
        for (const frame of item.frames) {
          const blob = base64ToBlob(frame.imageBase64, 'image/jpeg');
          formData.append('images', blob, `item_${item.id}_frame_${idx}.jpg`);
          if (frame.depthMapBase64) {
            const dBlob = base64ToBlob(frame.depthMapBase64, 'image/png');
            formData.append('depth_maps', dBlob, `item_${item.id}_depth_${idx}.png`);
          }
          idx++;
        }
      }

      const result = await apiPostForm<{ inquiry_id: string }>('/api/v1/submit/mobile/ar', formData);
      successHaptic();
      capture.clear();
      localStorage.setItem('aust_pending_inquiry', result.inquiry_id);
      goto(`/scan/processing?inquiry_id=${result.inquiry_id}`);
    } catch (e: any) {
      errorHaptic();
      const isApi = e instanceof ApiError;
      const safeMeta = (() => {
        // Don't expose the full API base URL on the off-chance this is a
        // production build, but keep the path so we know *which* endpoint failed.
        try {
          const u = new URL(`${(import.meta.env.VITE_API_BASE || 'http://localhost:8080').replace(/\/$/, '')}/api/v1/submit/mobile/ar`);
          return u.pathname;
        } catch { return '/api/v1/submit/mobile/ar'; }
      })();

      if (isApi) {
        if (e.status === 0) {
          error = e.message;
          errorDetail = `Endpoint: ${safeMeta}`;
        } else if (e.status === 401) {
          error = 'Sitzung abgelaufen — bitte erneut anmelden.';
          errorDetail = `HTTP 401 · ${safeMeta}`;
        } else if (e.status === 413) {
          error = 'Die hochgeladenen Daten sind zu groß. Bitte weniger Bilder verwenden.';
          errorDetail = `HTTP 413 · ${safeMeta}`;
        } else if (e.status >= 500) {
          error = `Serverfehler (${e.status}). Bitte versuchen Sie es später erneut.`;
          errorDetail = `HTTP ${e.status} · ${safeMeta}\n${e.message}`;
        } else {
          error = e.message || 'Fehler beim Senden.';
          errorDetail = `HTTP ${e.status} · ${safeMeta}\n${e.message}`;
        }
      } else {
        error = e.message || 'Unerwarteter Fehler beim Senden.';
        errorDetail = `Non-API error\n${e?.constructor?.name || 'Error'}: ${e?.message}`;
      }
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

  let formEl: HTMLFormElement | undefined = $state();
</script>

<NavBar title="Umzugsdetails" back="/scan" />

<main
  class="px-4 max-w-lg mx-auto rise-in"
  style="padding-top: calc(3rem + env(safe-area-inset-top, 0px) + 1rem); padding-bottom: calc(7.5rem + env(safe-area-inset-bottom, 0px));"
>
  <form bind:this={formEl} onsubmit={submit}>
    <!-- Scanned items summary -->
    {#if capture.items.length > 0}
      <p class="ios-section-header">Erfasste Objekte</p>
      <div class="ios-card mb-6">
        {#each capture.items as item}
          <div class="ios-row flex items-center gap-3 px-4 py-2.5">
            <div class="w-8 h-8 rounded-lg bg-tint-soft flex items-center justify-center shrink-0 text-tint">
              <Box size={15} strokeWidth={2} />
            </div>
            <span class="flex-1 text-[15px] text-label">{item.label}</span>
            {#if item.volumeM3 != null}
              <span class="inline-flex items-center gap-1 text-[13px] text-label-2">
                <Ruler size={12} />
                ≈ {item.volumeM3.toFixed(1)} m³
              </span>
            {:else}
              <span class="text-[13px] text-label-3">{item.frames.length} Fotos</span>
            {/if}
          </div>
        {/each}
        {#if capture.deviceVolumeM3 != null}
          <div class="ios-row flex items-center justify-between px-4 py-2.5">
            <span class="text-[15px] font-semibold text-label">Gesamtvolumen</span>
            <span class="text-[15px] font-semibold text-tint">≈ {capture.deviceVolumeM3.toFixed(1)} m³</span>
          </div>
        {/if}
      </div>
    {/if}

    <!-- Contact -->
    <p class="ios-section-header">Kontakt</p>
    <div class="ios-card mb-6">
      <div class="ios-row flex items-center px-4">
        <span class="w-20 text-[15px] text-label-2 shrink-0">Name</span>
        <input bind:value={name} required placeholder="Max Mustermann" class="ios-input" autocomplete="name" />
      </div>
      <div class="ios-row flex items-center px-4">
        <span class="w-20 text-[15px] text-label-2 shrink-0">E-Mail</span>
        <input type="email" bind:value={email} required placeholder="max@beispiel.de" class="ios-input" autocomplete="email" />
      </div>
      <div class="ios-row flex items-center px-4">
        <span class="w-20 text-[15px] text-label-2 shrink-0">Telefon</span>
        <input type="tel" bind:value={phone} placeholder="Optional" class="ios-input" autocomplete="tel" />
      </div>
    </div>

    <!-- Departure -->
    <p class="ios-section-header">Auszugsadresse</p>
    <div class="ios-card mb-6">
      <div class="ios-row px-4 py-1">
        <input bind:value={departureAddress} required placeholder="Straße Nr., PLZ Ort" class="ios-input" autocomplete="street-address" />
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Etage</span>
        <select bind:value={departureFloor} class="text-[15px] text-label-2 bg-transparent outline-none text-right">
          {#each floors as f}<option>{f}</option>{/each}
        </select>
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Aufzug vorhanden</span>
        <button type="button" role="switch" aria-checked={departureElevator} aria-label="Aufzug vorhanden"
          class="ios-switch" data-on={departureElevator}
          onclick={() => { tapHaptic(); departureElevator = !departureElevator; }}></button>
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Halteverbot beantragen</span>
        <button type="button" role="switch" aria-checked={departureParkingBan} aria-label="Halteverbot beantragen"
          class="ios-switch" data-on={departureParkingBan}
          onclick={() => { tapHaptic(); departureParkingBan = !departureParkingBan; }}></button>
      </div>
    </div>

    <!-- Arrival -->
    <p class="ios-section-header">Einzugsadresse</p>
    <div class="ios-card mb-6">
      <div class="ios-row px-4 py-1">
        <input bind:value={arrivalAddress} required placeholder="Straße Nr., PLZ Ort" class="ios-input" />
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Etage</span>
        <select bind:value={arrivalFloor} class="text-[15px] text-label-2 bg-transparent outline-none text-right">
          {#each floors as f}<option>{f}</option>{/each}
        </select>
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Aufzug vorhanden</span>
        <button type="button" role="switch" aria-checked={arrivalElevator} aria-label="Aufzug vorhanden"
          class="ios-switch" data-on={arrivalElevator}
          onclick={() => { tapHaptic(); arrivalElevator = !arrivalElevator; }}></button>
      </div>
      <div class="ios-row flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Halteverbot beantragen</span>
        <button type="button" role="switch" aria-checked={arrivalParkingBan} aria-label="Halteverbot beantragen"
          class="ios-switch" data-on={arrivalParkingBan}
          onclick={() => { tapHaptic(); arrivalParkingBan = !arrivalParkingBan; }}></button>
      </div>
    </div>

    <!-- Date -->
    <p class="ios-section-header">Wunschtermin</p>
    <div class="ios-card mb-6">
      <div class="flex items-center justify-between px-4 min-h-[44px]">
        <span class="text-[15px] text-label">Datum</span>
        <input type="date" bind:value={preferredDate} class="text-[15px] text-label-2 bg-transparent outline-none text-right" />
      </div>
    </div>

    <!-- Services -->
    <p class="ios-section-header">Zusatzleistungen</p>
    <div class="ios-card mb-6 p-4">
      <div class="flex flex-wrap gap-2">
        {#each serviceOptions as svc}
          <button
            type="button"
            onclick={() => toggleService(svc)}
            class="h-9 px-4 rounded-full text-[14px] font-medium transition-colors
              {services.includes(svc) ? 'bg-tint text-on-tint' : 'bg-fill text-label'}"
          >
            {svc}
          </button>
        {/each}
      </div>
    </div>

    <!-- Notes -->
    <p class="ios-section-header">Besondere Hinweise</p>
    <div class="ios-card mb-6 px-4 py-2">
      <textarea
        bind:value={message}
        rows="3"
        placeholder="Antikes Klavier, empfindliche Kunstwerke, Besonderheiten …"
        class="ios-input resize-none py-2"
      ></textarea>
    </div>

    {#if error}
      <div class="ios-card mb-6 p-4" style="background: var(--ios-red-soft);">
        <div class="flex items-center gap-2 mb-1 text-red">
          <CircleAlert size={18} />
          <span class="text-[15px] font-semibold">{error}</span>
        </div>
        {#if errorDetail}
          <pre class="mt-2 p-2 rounded-lg text-[11px] text-label-2 whitespace-pre-wrap break-all font-mono overflow-x-auto bg-fill">{errorDetail}</pre>
        {/if}
      </div>
    {/if}
  </form>
</main>

<!-- Bottom action bar -->
<div class="fixed bottom-0 left-0 w-full z-50 tab-bar" style="padding-bottom: env(safe-area-inset-bottom, 0px);">
  <div class="max-w-lg mx-auto px-4 py-3">
    <button
      type="button"
      onclick={() => { tapHaptic(); formEl?.requestSubmit(); }}
      disabled={submitting || !name || !email || !departureAddress || !arrivalAddress}
      class="btn-filled w-full"
    >
      {#if submitting}
        <span class="ios-spinner" style="width: 18px; height: 18px; border-top-color: #fff; border-color: rgba(255,255,255,0.3); border-top-color: #fff;"></span>
        Wird gesendet …
      {:else}
        Anfrage senden
      {/if}
    </button>
  </div>
</div>
