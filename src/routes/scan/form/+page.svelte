<script lang="ts">
  import { goto } from '$app/navigation';
  import { capture } from '$lib/stores/capture.svelte';
  import { auth } from '$lib/stores/auth.svelte';
  import { apiPostForm, ApiError } from '$lib/api/client';

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

  const floors = ['EG', '1. OG', '2. OG', '3. OG', '4. OG', '5. OG', 'DG', 'UG'];

  const serviceOptions = [
    { key: 'Montage', icon: 'build' },
    { key: 'Demontage', icon: 'handyman' },
    { key: 'Verpackungsservice', icon: 'inventory_2' },
    { key: 'Einlagerung', icon: 'warehouse' },
    { key: 'Entsorgung', icon: 'delete_forever' },
  ];

  function toggleService(s: string) {
    if (services.includes(s)) services = services.filter(x => x !== s);
    else services = [...services, s];
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    submitting = true;
    error = null;
    errorDetail = null;
    try {
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

      // AR item manifest — tells the backend which frames belong to which item
      formData.append('item_manifest', JSON.stringify(
        capture.items.map(item => ({ label: item.label, frame_count: item.frames.length }))
      ));
      if (capture.intrinsics) {
        formData.append('intrinsics', JSON.stringify(capture.intrinsics));
      }
      // Flat list of poses in the same order as images[]
      formData.append('poses', JSON.stringify(
        capture.items.flatMap(item => item.frames.map(f => f.pose ?? null))
      ));

      let idx = 0;
      for (const item of capture.items) {
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
      capture.clear();
      localStorage.setItem('aust_pending_inquiry', result.inquiry_id);
      goto(`/scan/processing?inquiry_id=${result.inquiry_id}`);
    } catch (e: any) {
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

  let formEl: HTMLFormElement;
</script>

<!-- Glass header -->
<header class="fixed top-0 w-full z-50 glass-header bento-shadow" style="padding-top: env(safe-area-inset-top, 0px);">
  <div class="h-16 flex justify-between items-center px-6">
    <div class="flex items-center gap-3">
      <button onclick={() => goto('/scan')} class="text-white/80 active:scale-95 transition-all">
        <span class="material-symbols-outlined">arrow_back</span>
      </button>
      <h1 class="text-white text-sm font-bold tracking-tight uppercase">Umzugsdetails</h1>
    </div>
    <span class="text-secondary-container text-xs font-bold uppercase tracking-widest">Schritt 2/3</span>
  </div>
</header>

<main class="px-5 max-w-lg mx-auto" style="padding-top: calc(4rem + env(safe-area-inset-top, 0px) + 1rem); padding-bottom: calc(8rem + env(safe-area-inset-bottom, 0px));">
  <!-- Progress bar -->
  <div class="mb-7 pt-4">
    <div class="flex justify-between mb-2">
      <span class="text-primary font-bold text-xs tracking-widest uppercase">Adressdetails</span>
      <span class="text-secondary font-bold text-xs tracking-widest uppercase">66%</span>
    </div>
    <div class="h-2 w-full bg-primary-fixed rounded-full overflow-hidden">
      <div class="h-full bg-secondary rounded-full transition-all duration-700 ease-out" style="width: 66%;"></div>
    </div>
  </div>

  <form bind:this={formEl} onsubmit={submit} class="space-y-4">
    <!-- Contact info -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-primary" style="font-size: 20px;">person</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">Kontaktdaten</h3>
      </div>
      <div class="space-y-3">
        <div>
          <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Name *</label>
          <input
            bind:value={name}
            required
            placeholder="Max Mustermann"
            class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
            style="border: none;"
          />
        </div>
        <div>
          <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">E-Mail *</label>
          <input
            type="email"
            bind:value={email}
            required
            placeholder="max@beispiel.de"
            class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
            style="border: none;"
          />
        </div>
        <div>
          <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Telefon <span class="normal-case font-normal tracking-normal">(optional)</span></label>
          <input
            type="tel"
            bind:value={phone}
            placeholder="+49 151 12345678"
            class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
            style="border: none;"
          />
        </div>
      </div>
    </div>

    <!-- Departure address -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-primary" style="font-size: 20px;">location_on</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">Auszugsadresse</h3>
      </div>
      <div class="space-y-3">
        <div>
          <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Straße & Hausnr., PLZ Ort</label>
          <input
            bind:value={departureAddress}
            required
            placeholder="Musterstr. 1, 80331 München"
            class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
            style="border: none;"
          />
        </div>
        <div class="flex items-center gap-2">
          <div class="flex-1">
            <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Etage</label>
            <select
              bind:value={departureFloor}
              class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface outline-none transition-all"
              style="border: none;"
            >
              {#each floors as f}<option>{f}</option>{/each}
            </select>
          </div>
          <button
            type="button"
            onclick={() => departureElevator = !departureElevator}
            class="flex flex-col items-center gap-1 px-4 py-2.5 rounded-xl transition-all duration-200 mt-5 {departureElevator ? 'bg-primary text-white' : 'bg-surface-container text-on-surface-variant'}"
          >
            <span class="material-symbols-outlined" style="font-size: 18px;">elevator</span>
            <span class="text-[9px] font-bold uppercase tracking-wide">Aufzug</span>
          </button>
          <button
            type="button"
            onclick={() => departureParkingBan = !departureParkingBan}
            class="flex flex-col items-center gap-1 px-3 py-2.5 rounded-xl transition-all duration-200 mt-5 {departureParkingBan ? 'bg-secondary-container text-on-secondary-container' : 'bg-surface-container text-on-surface-variant'}"
          >
            <span class="material-symbols-outlined" style="font-size: 18px;">traffic</span>
            <span class="text-[9px] font-bold uppercase tracking-wide leading-none text-center">Halte-<br/>verbot</span>
          </button>
        </div>
      </div>
    </div>

    <!-- Arrival address -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-secondary" style="font-size: 20px;">flag</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">Einzugsadresse</h3>
      </div>
      <div class="space-y-3">
        <div>
          <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Straße & Hausnr., PLZ Ort</label>
          <input
            bind:value={arrivalAddress}
            required
            placeholder="Zielstr. 2, 80331 München"
            class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
            style="border: none;"
          />
        </div>
        <div class="flex items-center gap-2">
          <div class="flex-1">
            <label class="text-[10px] font-bold uppercase tracking-wider text-outline block mb-1 ml-1">Etage</label>
            <select
              bind:value={arrivalFloor}
              class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface outline-none transition-all"
              style="border: none;"
            >
              {#each floors as f}<option>{f}</option>{/each}
            </select>
          </div>
          <button
            type="button"
            onclick={() => arrivalElevator = !arrivalElevator}
            class="flex flex-col items-center gap-1 px-4 py-2.5 rounded-xl transition-all duration-200 mt-5 {arrivalElevator ? 'bg-primary text-white' : 'bg-surface-container text-on-surface-variant'}"
          >
            <span class="material-symbols-outlined" style="font-size: 18px;">elevator</span>
            <span class="text-[9px] font-bold uppercase tracking-wide">Aufzug</span>
          </button>
          <button
            type="button"
            onclick={() => arrivalParkingBan = !arrivalParkingBan}
            class="flex flex-col items-center gap-1 px-3 py-2.5 rounded-xl transition-all duration-200 mt-5 {arrivalParkingBan ? 'bg-secondary-container text-on-secondary-container' : 'bg-surface-container text-on-surface-variant'}"
          >
            <span class="material-symbols-outlined" style="font-size: 18px;">traffic</span>
            <span class="text-[9px] font-bold uppercase tracking-wide leading-none text-center">Halte-<br/>verbot</span>
          </button>
        </div>
      </div>
    </div>

    <!-- Preferred date -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-primary" style="font-size: 20px;">calendar_today</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">Wunschtermin</h3>
      </div>
      <input
        type="date"
        bind:value={preferredDate}
        class="w-full h-12 px-4 bg-surface-container-high rounded-xl text-on-surface outline-none transition-all"
        style="border: none;"
      />
    </div>

    <!-- Services -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-primary" style="font-size: 20px;">home_repair_service</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">Zusatzleistungen</h3>
      </div>
      <div class="flex flex-wrap gap-2">
        {#each serviceOptions as svc}
          <button
            type="button"
            onclick={() => toggleService(svc.key)}
            class="flex items-center gap-1.5 px-3.5 py-2 rounded-xl text-xs font-bold uppercase tracking-wide transition-all duration-200
              {services.includes(svc.key)
                ? 'bg-primary text-white'
                : 'bg-surface-container text-on-surface-variant hover:bg-surface-container-high'}"
          >
            <span class="material-symbols-outlined" style="font-size: 14px;">{svc.icon}</span>
            {svc.key}
          </button>
        {/each}
      </div>
    </div>

    <!-- Notes -->
    <div class="bg-surface-container-lowest rounded-2xl p-5 bento-shadow">
      <div class="flex items-center gap-2 mb-4">
        <span class="material-symbols-outlined text-primary" style="font-size: 20px;">edit_note</span>
        <h3 class="font-bold text-xs tracking-widest uppercase text-on-surface">
          Besondere Hinweise
          <span class="text-outline normal-case font-normal tracking-normal text-xs"> (optional)</span>
        </h3>
      </div>
      <textarea
        bind:value={message}
        rows="3"
        placeholder="Antikes Klavier, empfindliche Kunstwerke, Besonderheiten..."
        class="w-full px-4 py-3 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all resize-none"
        style="border: none;"
      ></textarea>
    </div>

    {#if error}
      <div class="rounded-xl bg-error-container p-4 text-sm text-on-error-container">
        <div class="flex items-center gap-2 mb-1">
          <span class="material-symbols-outlined text-error" style="font-size: 18px;">error</span>
          <span class="font-bold">{error}</span>
        </div>
        {#if errorDetail}
          <pre class="mt-2 p-2 bg-error/10 rounded-lg text-[11px] text-on-error-container/70 whitespace-pre-wrap break-all font-mono overflow-x-auto">{errorDetail}</pre>
        {/if}
      </div>
    {/if}
  </form>
</main>

<!-- Fixed bottom action bar -->
<div class="fixed bottom-0 left-0 w-full z-50" style="background: rgba(255,255,255,0.92); backdrop-filter: blur(20px); border-top: 1px solid rgba(196,198,207,0.15); padding-bottom: env(safe-area-inset-bottom, 0px);">
  <div class="max-w-lg mx-auto flex items-center justify-between gap-4 px-5 py-4">
    <button
      onclick={() => goto('/scan')}
      class="text-secondary font-bold text-sm tracking-widest uppercase"
    >
      Zurück
    </button>
    <button
      type="button"
      onclick={() => formEl?.requestSubmit()}
      disabled={submitting || !name || !email || !departureAddress || !arrivalAddress}
      class="bg-gradient-to-br from-primary to-primary-container text-white px-8 py-3.5 rounded-xl font-bold text-sm tracking-wide uppercase bento-shadow active:scale-95 transition-all disabled:opacity-50 flex items-center gap-2"
    >
      {#if submitting}
        <div class="w-4 h-4 border-2 border-white/40 border-t-white rounded-full animate-spin"></div>
        Wird gesendet...
      {:else}
        Anfrage senden
        <span class="material-symbols-outlined" style="font-size: 16px;">send</span>
      {/if}
    </button>
  </div>
</div>
