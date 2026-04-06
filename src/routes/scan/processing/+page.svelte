<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { apiGet, ApiError } from '$lib/api/client';

  const STORAGE_KEY = 'aust_pending_inquiry';
  const MAX_POLLS = 72; // ~6 min at 5s intervals — then tell user to check email

  interface InquiryStatus {
    id: string;
    status: string;
    estimated_volume_m3: number | null;
  }

  type UiState = 'processing' | 'ready' | 'error' | 'timeout';

  let inquiryId: string | null = $state(null);
  let status: InquiryStatus | null = $state(null);
  let pollCount = $state(0);
  let uiState: UiState = $state('processing');
  let pollTimer: ReturnType<typeof setInterval>;

  const TERMINAL = ['offer_ready', 'offer_sent', 'accepted'];
  const FAILED   = ['cancelled', 'rejected', 'expired'];

  const steps = [
    { key: 'pending',   label: 'Bilder hochgeladen', icon: 'cloud_upload' },
    { key: 'estimated', label: 'Volumen berechnet',  icon: 'calculate'    },
    { key: 'offer_ready', label: 'Angebot erstellt', icon: 'description'  },
  ];

  const statusOrder = ['pending','info_requested','estimating','estimated','offer_ready','offer_sent','accepted'];

  function stepDone(key: string): boolean {
    if (!status) return false;
    return statusOrder.indexOf(status.status) >= statusOrder.indexOf(key);
  }

  async function poll() {
    if (!inquiryId) return;
    pollCount++;
    try {
      const data = await apiGet<InquiryStatus>(`/api/v1/customer/inquiries/${inquiryId}`);
      status = data;

      if (TERMINAL.includes(data.status)) {
        clearInterval(pollTimer);
        localStorage.removeItem(STORAGE_KEY);
        uiState = 'ready';
        return;
      }
      if (FAILED.includes(data.status)) {
        clearInterval(pollTimer);
        uiState = 'error';
        return;
      }
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        clearInterval(pollTimer);
        goto('/auth?redirect=/offers');
        return;
      }
      // network error — keep polling
    }

    if (pollCount >= MAX_POLLS) {
      clearInterval(pollTimer);
      uiState = 'timeout';
    }
  }

  $effect(() => {
    inquiryId = $page.url.searchParams.get('inquiry_id') || localStorage.getItem(STORAGE_KEY);
    if (!inquiryId) { goto('/offers'); return; }

    // Ensure it's persisted so the user can return after backgrounding
    localStorage.setItem(STORAGE_KEY, inquiryId);

    poll();
    pollTimer = setInterval(poll, 5000);
    return () => clearInterval(pollTimer);
  });
</script>

<div class="min-h-screen bg-surface flex flex-col items-center justify-center px-6 text-center">

  {#if uiState === 'processing'}
    <!-- Spinner -->
    <div class="mb-10">
      <div class="w-24 h-24 rounded-3xl bg-primary flex items-center justify-center mx-auto mb-5 bento-shadow relative overflow-hidden">
        <div class="absolute inset-0 bg-gradient-to-br from-primary to-primary-container"></div>
        <div class="relative w-10 h-10 border-4 border-primary-fixed/30 border-t-primary-fixed rounded-full animate-spin"></div>
      </div>
      <p class="text-secondary font-bold text-xs tracking-widest uppercase mb-2">KI-Analyse</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Wird verarbeitet...</h1>
      <p class="text-on-surface-variant text-sm mt-2">Das dauert in der Regel 1–3 Minuten.</p>
    </div>

    <div class="w-full max-w-xs space-y-3">
      {#each steps as step}
        <div class="flex items-center gap-4 p-4 rounded-2xl transition-all duration-300 {stepDone(step.key) ? 'bg-surface-container-lowest bento-shadow' : 'bg-surface-container/50'}">
          <div class="w-9 h-9 rounded-xl flex items-center justify-center shrink-0 transition-all {stepDone(step.key) ? 'bg-secondary-container' : 'bg-surface-container'}">
            {#if stepDone(step.key)}
              <span class="material-symbols-outlined text-on-secondary-container" style="font-size: 18px; font-variation-settings: 'FILL' 1;">check</span>
            {:else}
              <span class="material-symbols-outlined text-on-surface-variant" style="font-size: 18px;">{step.icon}</span>
            {/if}
          </div>
          <span class="text-sm text-left transition-all {stepDone(step.key) ? 'text-on-surface font-bold' : 'text-on-surface-variant font-medium'}">
            {step.label}
          </span>
        </div>
      {/each}
    </div>

  {:else if uiState === 'ready'}
    <!-- Success -->
    <div class="mb-10">
      <div class="w-24 h-24 rounded-3xl bg-secondary-container flex items-center justify-center mx-auto mb-5 bento-shadow">
        <span class="material-symbols-outlined text-on-secondary-container" style="font-size: 44px; font-variation-settings: 'FILL' 1;">check_circle</span>
      </div>
      <p class="text-secondary font-bold text-xs tracking-widest uppercase mb-2">Abgeschlossen</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Ihr Angebot ist bereit</h1>
      <p class="text-on-surface-variant text-sm mt-2 max-w-xs mx-auto leading-relaxed">
        Unser Team hat Ihren Umzug analysiert und ein persönliches Angebot erstellt.
      </p>
    </div>
    <button
      onclick={() => goto(`/offers/${inquiryId}`)}
      class="w-full max-w-xs h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all flex items-center justify-center gap-2"
    >
      Angebot ansehen
      <span class="material-symbols-outlined" style="font-size: 18px;">arrow_forward</span>
    </button>

  {:else if uiState === 'error'}
    <!-- Failure -->
    <div class="mb-10">
      <div class="w-24 h-24 rounded-3xl bg-error-container flex items-center justify-center mx-auto mb-5 bento-shadow">
        <span class="material-symbols-outlined text-error" style="font-size: 44px;">error</span>
      </div>
      <p class="text-error font-bold text-xs tracking-widest uppercase mb-2">Fehler</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Verarbeitung fehlgeschlagen</h1>
      <p class="text-on-surface-variant text-sm mt-2 max-w-xs mx-auto leading-relaxed">
        Bei der Analyse ist ein Fehler aufgetreten. Bitte starten Sie einen neuen Scan oder kontaktieren Sie uns.
      </p>
    </div>
    <button
      onclick={() => goto('/scan')}
      class="w-full max-w-xs h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all flex items-center justify-center gap-2 mb-3"
    >
      <span class="material-symbols-outlined" style="font-size: 18px;">refresh</span>
      Neuer Scan
    </button>

  {:else}
    <!-- Timeout — still running, just slow -->
    <div class="mb-10">
      <div class="w-24 h-24 rounded-3xl bg-surface-container-high flex items-center justify-center mx-auto mb-5 bento-shadow">
        <span class="material-symbols-outlined text-on-surface-variant" style="font-size: 44px;">hourglass_bottom</span>
      </div>
      <p class="text-secondary font-bold text-xs tracking-widest uppercase mb-2">Dauert länger</p>
      <h1 class="text-2xl font-extrabold text-on-surface tracking-tight">Noch in Bearbeitung</h1>
      <p class="text-on-surface-variant text-sm mt-2 max-w-xs mx-auto leading-relaxed">
        Die Analyse läuft im Hintergrund weiter. Sie erhalten eine E-Mail, sobald das Angebot fertig ist.
      </p>
    </div>
    <button
      onclick={() => goto('/offers')}
      class="w-full max-w-xs h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all flex items-center justify-center gap-2 mb-3"
    >
      Meine Angebote
      <span class="material-symbols-outlined" style="font-size: 18px;">arrow_forward</span>
    </button>
    <button
      onclick={() => { uiState = 'processing'; pollCount = 0; pollTimer = setInterval(poll, 5000); }}
      class="text-on-surface-variant text-xs font-bold uppercase tracking-widest"
    >
      Weiter warten
    </button>
  {/if}

</div>
