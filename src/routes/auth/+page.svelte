<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { auth } from '$lib/stores/auth.svelte';

  let email = $state('');
  let code = $state('');
  let step: 'email' | 'code' = $state('email');
  let codeInputs: HTMLInputElement[] = $state([]);

  const redirect = $derived($page.url.searchParams.get('redirect') || '/');

  async function requestCode(e: SubmitEvent) {
    e.preventDefault();
    await auth.requestOtp(email);
    step = 'code';
  }

  async function verifyCode() {
    await auth.verifyOtp(email, code);
    goto(redirect);
  }

  function handleCodeInput(index: number, event: Event) {
    const input = event.target as HTMLInputElement;
    const value = input.value;
    if (value.length === 1 && index < 5) {
      codeInputs[index + 1]?.focus();
    }
    code = codeInputs.map(i => i?.value || '').join('');
    if (code.length === 6) verifyCode();
  }

  function handleCodeKeydown(index: number, event: KeyboardEvent) {
    if (event.key === 'Backspace' && !codeInputs[index]?.value && index > 0) {
      codeInputs[index - 1]?.focus();
    }
  }
</script>

<div class="min-h-screen flex flex-col md:flex-row">
  <!-- Left panel (desktop only) -->
  <div class="hidden md:flex md:w-1/2 relative bg-primary items-center justify-center p-12 overflow-hidden">
    <div class="absolute inset-0 bg-gradient-to-br from-primary via-primary-container/60 to-transparent"></div>
    <div class="relative z-10 max-w-md">
      <span class="text-white font-black tracking-tighter text-2xl uppercase block mb-8">AUST Umzüge</span>
      <h1 class="text-5xl font-extrabold text-white tracking-tight leading-tight mb-6">
        Präzision bei jedem Umzug.
      </h1>
      <p class="text-primary-fixed-dim text-lg leading-relaxed mb-8 opacity-90">
        Professionelle Umzugsplanung mit moderner KI-Technologie. Präzise Angebote in Minuten — nicht in Tagen.
      </p>
      <div class="flex items-center gap-4">
        <div class="h-1 w-12 bg-secondary rounded-full"></div>
        <span class="text-secondary-fixed-dim text-xs tracking-widest uppercase font-bold">München & Umgebung</span>
      </div>
    </div>
  </div>

  <!-- Right panel -->
  <main class="flex-1 flex flex-col justify-center items-center px-6 py-12 bg-surface">
    <!-- Mobile logo -->
    <div class="md:hidden self-start mb-8">
      <span class="text-primary font-black tracking-tighter text-xl uppercase">AUST Umzüge</span>
    </div>

    <div class="w-full max-w-sm space-y-8">
      {#if step === 'email'}
        <header>
          <h2 class="text-2xl font-bold text-on-surface tracking-tight mb-1">Willkommen</h2>
          <p class="text-on-surface-variant text-sm">Melden Sie sich mit Ihrer E-Mail-Adresse an</p>
        </header>

        <form onsubmit={requestCode} class="space-y-5">
          <div class="space-y-1.5">
            <label class="block text-[10px] font-bold tracking-widest text-on-surface-variant uppercase ml-1" for="email">
              E-Mail-Adresse
            </label>
            <div class="relative">
              <div class="absolute inset-y-0 left-4 flex items-center pointer-events-none text-outline">
                <span class="material-symbols-outlined" style="font-size: 20px;">mail</span>
              </div>
              <input
                id="email"
                type="email"
                bind:value={email}
                required
                placeholder="ihre@email.de"
                class="w-full h-14 pl-12 pr-4 bg-surface-container-high rounded-xl text-on-surface placeholder:text-outline outline-none transition-all duration-200"
              />
            </div>
          </div>

          <button
            type="submit"
            disabled={auth.loading || !email}
            class="w-full h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-[0.98] transition-all duration-200 flex items-center justify-center gap-2 disabled:opacity-50"
          >
            <span>{auth.loading ? 'Wird gesendet...' : 'Code anfordern'}</span>
            <span class="material-symbols-outlined" style="font-size: 18px;">arrow_forward</span>
          </button>
        </form>

      {:else}
        <div class="space-y-8">
          <div class="text-center">
            <div class="mx-auto w-16 h-16 bg-secondary-container rounded-2xl flex items-center justify-center text-on-secondary-container mb-4">
              <span class="material-symbols-outlined" style="font-size: 32px;">phonelink_lock</span>
            </div>
            <h2 class="text-2xl font-bold text-on-surface tracking-tight mb-1">Identität bestätigen</h2>
            <p class="text-on-surface-variant text-sm leading-relaxed">
              Wir haben einen 6-stelligen Code an<br/>
              <strong class="text-on-surface">{email}</strong> gesendet.
            </p>
          </div>

          <div class="flex justify-between gap-2">
            {#each Array(6) as _, i}
              <input
                bind:this={codeInputs[i]}
                type="text"
                inputmode="numeric"
                maxlength="1"
                class="w-12 h-14 text-center bg-surface-container-high rounded-xl text-xl font-bold text-primary outline-none transition-all"
                style="border: none;"
                oninput={(e) => handleCodeInput(i, e)}
                onkeydown={(e) => handleCodeKeydown(i, e)}
              />
            {/each}
          </div>

          <div class="space-y-3">
            <button
              onclick={verifyCode}
              disabled={auth.loading || code.length < 6}
              class="w-full h-14 bg-gradient-to-br from-primary to-primary-container text-white font-bold rounded-xl bento-shadow active:scale-95 transition-all disabled:opacity-50"
            >
              Bestätigen & Weiter
            </button>
            <button
              onclick={() => { step = 'email'; code = ''; }}
              class="w-full py-2 text-on-surface-variant text-xs font-bold uppercase tracking-widest hover:text-secondary transition-colors"
            >
              Andere E-Mail verwenden
            </button>
          </div>
        </div>
      {/if}

      {#if auth.error}
        <div class="rounded-xl bg-error-container p-4 text-sm text-on-error-container">{auth.error}</div>
      {/if}
    </div>
  </main>
</div>

<!-- Footer -->
<footer class="fixed bottom-0 w-full md:w-1/2 md:right-0 px-8 py-5 flex justify-between items-center text-[10px] font-bold uppercase tracking-widest text-outline">
  <div class="flex gap-5">
    <a href="#" class="hover:text-primary transition-colors">Datenschutz</a>
    <a href="#" class="hover:text-primary transition-colors">AGB</a>
  </div>
  <span>© 2025 AUST Umzüge</span>
</footer>
