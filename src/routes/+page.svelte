<script lang="ts">
  import { goto } from '$app/navigation';
  import { auth } from '$lib/stores/auth.svelte';

  function startScan() {
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
</script>

<div class="flex min-h-screen flex-col items-center justify-center px-6 text-center">
  <div class="mb-8">
    <div class="mx-auto mb-4 flex h-20 w-20 items-center justify-center rounded-2xl bg-primary text-3xl font-bold text-white">
      A
    </div>
    <h1 class="mb-2 text-3xl font-bold text-primary">Aust Umzüge</h1>
    <p class="text-lg text-text-muted">Ihr Umzug, einfach geplant</p>
  </div>

  <p class="mb-12 max-w-sm text-text-muted">
    Fotografieren Sie Ihre Wohnung — wir erstellen Ihr persönliches Angebot innerhalb weniger Minuten.
  </p>

  <div class="flex w-full max-w-xs flex-col gap-4">
    <button
      onclick={startScan}
      class="rounded-xl bg-accent px-6 py-4 text-lg font-semibold text-white shadow-md transition hover:bg-accent-hover active:scale-[0.98]"
    >
      Jetzt scannen
    </button>
    <button
      onclick={viewOffers}
      class="rounded-xl border border-border bg-surface px-6 py-4 text-lg font-semibold text-primary shadow-sm transition hover:bg-bg active:scale-[0.98]"
    >
      Meine Angebote
    </button>
  </div>

  {#if auth.isAuthenticated && auth.customer}
    <p class="mt-8 text-sm text-text-muted">
      Angemeldet als {auth.customer.email}
      <button onclick={() => auth.logout()} class="ml-2 text-accent hover:underline">Abmelden</button>
    </p>
  {/if}
</div>
