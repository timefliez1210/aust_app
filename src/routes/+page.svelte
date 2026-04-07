<script lang="ts">
  import { goto } from '$app/navigation';
  import { auth } from '$lib/stores/auth.svelte';
  import { capture } from '$lib/stores/capture.svelte';
  import { apiGet } from '$lib/api/client';
  import BottomNav from '$lib/components/BottomNav.svelte';

  interface LatestInquiry {
    id: string;
    status: string;
    origin_city: string | null;
    destination_city: string | null;
    price_cents: number | null;
  }

  let latestInquiry: LatestInquiry | null = $state(null);

  const IN_PROGRESS = ['pending','info_requested','estimating','estimated'];
  const OFFER_READY = ['offer_ready','offer_sent'];

  function inquiryStatusLabel(s: string): string {
    if (IN_PROGRESS.includes(s)) return 'KI analysiert Ihren Umzug...';
    if (OFFER_READY.includes(s)) return 'Angebot bereit — jetzt ansehen';
    if (s === 'accepted') return 'Umzug bestätigt';
    return '';
  }

  function inquiryStatusIcon(s: string): string {
    if (IN_PROGRESS.includes(s)) return 'pending';
    if (OFFER_READY.includes(s)) return 'check_circle';
    if (s === 'accepted') return 'celebration';
    return 'pending';
  }

  function inquiryStatusColor(s: string): string {
    if (OFFER_READY.includes(s) || s === 'accepted') return 'text-secondary';
    return 'text-primary';
  }

  function inquiryTarget(inquiry: LatestInquiry): string {
    if (IN_PROGRESS.includes(inquiry.status)) {
      const pending = localStorage.getItem('aust_pending_inquiry');
      if (pending === inquiry.id) return `/scan/processing?inquiry_id=${inquiry.id}`;
    }
    return `/offers/${inquiry.id}`;
  }

  async function loadLatestInquiry() {
    if (!auth.isAuthenticated) return;
    try {
      const list = await apiGet<LatestInquiry[]>('/api/v1/customer/inquiries');
      const active = list.find(i =>
        [...IN_PROGRESS, ...OFFER_READY, 'accepted'].includes(i.status)
      );
      latestInquiry = active ?? list[0] ?? null;
    } catch { /* ignore */ }
  }

  $effect(() => {
    if (auth.isAuthenticated) loadLatestInquiry();
    else latestInquiry = null;
  });

  async function startScan() {
    // If a previous scan was interrupted, offer to resume it instead.
    await capture.waitReady();
    if (capture.items.length > 0) {
      goto('/scan/resume');
      return;
    }
    if (auth.isAuthenticated) {
      const seen = localStorage.getItem('tutorialSeen');
      goto(seen ? '/scan' : '/tutorial');
    } else {
      goto('/auth?redirect=/tutorial');
    }
  }

  function viewOffers() {
    if (auth.isAuthenticated) goto('/offers');
    else goto('/auth?redirect=/offers');
  }

  const tips = [
    { icon: 'lightbulb', title: 'Gutes Licht', desc: 'Alle Lampen einschalten.' },
    { icon: 'door_open', title: 'Türen öffnen', desc: 'Schränke und Lager zeigen.' },
    { icon: 'cleaning_services', title: 'Freie Wege', desc: 'Möbel gut zugänglich halten.' },
  ];
</script>

<!-- Glass header -->
<header class="fixed top-0 w-full z-50 glass-header bento-shadow" style="padding-top: env(safe-area-inset-top, 0px);">
  <div class="h-16 flex justify-between items-center px-6">
  <h1 class="text-white text-base font-black tracking-tighter uppercase">AUST Umzüge</h1>
  {#if auth.isAuthenticated}
    <button onclick={() => auth.logout()} class="flex items-center gap-1.5 text-on-primary-container text-xs font-bold uppercase tracking-wide hover:text-white transition-colors">
      <span class="material-symbols-outlined" style="font-size: 18px;">logout</span>
    </button>
  {:else}
    <button onclick={() => goto('/auth')} class="text-on-primary-container text-xs font-bold uppercase tracking-widest hover:text-white transition-colors">
      Anmelden
    </button>
  {/if}
  </div>
</header>

<main class="px-5 max-w-lg mx-auto" style="padding-top: calc(4rem + env(safe-area-inset-top, 0px) + 2rem); padding-bottom: calc(7rem + env(safe-area-inset-bottom, 0px));">
  <!-- Welcome -->
  <section class="mb-8">
    <p class="text-secondary font-bold tracking-widest uppercase text-xs mb-1.5">Bereit zum Umzug?</p>
    <h2 class="text-3xl font-extrabold text-on-surface tracking-tight leading-tight">
      {#if auth.isAuthenticated && auth.customer}
        Willkommen zurück.
      {:else}
        Ihr Umzug, einfach geplant.
      {/if}
    </h2>
    <p class="text-on-surface-variant mt-2 text-sm leading-relaxed max-w-xs">
      Fotografieren Sie Ihre Wohnung — wir erstellen Ihr persönliches Angebot in Minuten.
    </p>
  </section>

  <!-- Bento grid -->
  <div class="space-y-4">
    <!-- Hero card -->
    <div class="relative overflow-hidden rounded-3xl bg-primary text-white p-7 min-h-[220px] flex flex-col justify-end bento-shadow">
      <div class="absolute inset-0 bg-gradient-to-t from-primary via-primary-container/50 to-primary-container/10"></div>
      <div class="relative z-10">
        <div class="inline-flex items-center bg-secondary-container text-on-secondary-container px-3 py-1 rounded-full text-[10px] font-black tracking-widest uppercase mb-3">
          KI-Scan · Schritt 1
        </div>
        <h3 class="text-2xl font-extrabold mb-1.5 tracking-tight">Raumscan starten</h3>
        <p class="text-primary-fixed/75 text-sm mb-5 max-w-xs leading-relaxed">
          KI analysiert Ihre Räume per Foto und erstellt ein präzises Angebot.
        </p>
        <button
          onclick={startScan}
          class="bg-gradient-to-br from-secondary to-secondary/80 text-white font-bold py-3.5 px-7 rounded-xl active:scale-95 transition-all duration-200 shadow-lg text-sm"
        >
          Jetzt scannen
        </button>
      </div>
    </div>

    <!-- Two smaller cards -->
    <div class="grid grid-cols-2 gap-4">
      <!-- Prep tips -->
      <div class="rounded-3xl bg-surface-container-lowest p-5 flex flex-col gap-4 bento-shadow">
        <h4 class="text-on-surface font-bold text-xs uppercase tracking-wider">Vorbereitung</h4>
        <div class="space-y-3">
          {#each tips as tip}
            <div class="flex items-start gap-2.5">
              <div class="w-7 h-7 rounded-xl bg-surface-container flex items-center justify-center text-primary shrink-0">
                <span class="material-symbols-outlined" style="font-size: 14px;">{tip.icon}</span>
              </div>
              <div>
                <p class="font-bold text-[11px] text-on-surface leading-tight">{tip.title}</p>
                <p class="text-[10px] text-on-surface-variant leading-tight mt-0.5">{tip.desc}</p>
              </div>
            </div>
          {/each}
        </div>
        <div class="mt-auto pt-3 border-t border-outline-variant/10">
          <p class="text-[9px] font-bold uppercase tracking-widest text-on-surface-variant">Dauer ca.</p>
          <div class="flex items-center gap-1.5 mt-0.5">
            <span class="material-symbols-outlined text-secondary" style="font-size: 14px;">schedule</span>
            <span class="font-bold text-on-surface text-xs">15–20 Min.</span>
          </div>
        </div>
      </div>

      <!-- Offers card -->
      <div class="rounded-3xl bg-primary-container p-5 flex flex-col justify-between text-white">
        <span class="material-symbols-outlined text-on-primary-container" style="font-size: 36px;">description</span>
        <div>
          <h4 class="font-bold text-sm mb-1">Meine Angebote</h4>
          <p class="text-[10px] text-on-primary-container leading-tight mb-3">Alle Ihre Umzugsangebote auf einen Blick.</p>
          <button onclick={viewOffers} class="flex items-center gap-1 text-secondary-container text-[10px] font-black uppercase tracking-widest">
            Ansehen <span class="material-symbols-outlined" style="font-size: 14px;">arrow_forward</span>
          </button>
        </div>
      </div>
    </div>

    <!-- Status timeline (authenticated) -->
    {#if auth.isAuthenticated}
      <section>
        <h5 class="text-[10px] font-bold tracking-widest uppercase text-on-surface-variant mb-3">Ihr Umzugsstatus</h5>
        <div class="space-y-2.5">
          <!-- Logged-in row -->
          <div class="flex items-center gap-4 bg-surface-container-high/50 p-4 rounded-2xl">
            <div class="w-2 h-2 rounded-full bg-secondary shrink-0"></div>
            <div class="flex-grow">
              <p class="text-sm font-bold text-on-surface">Angemeldet</p>
              <p class="text-xs text-on-surface-variant">{auth.customer?.email}</p>
            </div>
            <span class="material-symbols-outlined text-secondary" style="font-size: 18px; font-variation-settings: 'FILL' 1;">check_circle</span>
          </div>

          <!-- Latest inquiry status -->
          {#if latestInquiry && inquiryStatusLabel(latestInquiry.status)}
            <button
              onclick={() => goto(inquiryTarget(latestInquiry!))}
              class="w-full flex items-center gap-4 bg-surface-container-lowest p-4 rounded-2xl active:scale-[0.99] transition-all text-left"
              style="border: 1px solid rgba(196,198,207,0.1);"
            >
              {#if IN_PROGRESS.includes(latestInquiry.status)}
                <div class="w-2 h-2 rounded-full bg-primary animate-pulse shrink-0"></div>
              {:else}
                <div class="w-2 h-2 rounded-full bg-secondary shrink-0"></div>
              {/if}
              <div class="flex-grow min-w-0">
                <p class="text-sm font-bold text-on-surface truncate">
                  {latestInquiry.origin_city || '?'} → {latestInquiry.destination_city || '?'}
                </p>
                <p class="text-xs text-on-surface-variant">{inquiryStatusLabel(latestInquiry.status)}</p>
              </div>
              <span class="material-symbols-outlined shrink-0 {inquiryStatusColor(latestInquiry.status)}"
                style="font-size: 18px; font-variation-settings: 'FILL' 1;"
              >{inquiryStatusIcon(latestInquiry.status)}</span>
            </button>
          {:else}
            <!-- No active inquiry -->
            <div class="flex items-center gap-4 bg-surface-container-lowest p-4 rounded-2xl" style="border: 1px solid rgba(196,198,207,0.1);">
              <div class="w-2 h-2 rounded-full bg-primary animate-pulse shrink-0"></div>
              <div class="flex-grow">
                <p class="text-sm font-bold text-on-surface">Inventurscan</p>
                <p class="text-xs text-on-surface-variant">Ausstehend — Scan jetzt starten</p>
              </div>
              <span class="material-symbols-outlined text-outline-variant" style="font-size: 18px;">pending</span>
            </div>
          {/if}
        </div>
      </section>
    {/if}
  </div>
</main>

<BottomNav />
