<script lang="ts">
  import { goto } from '$app/navigation';

  let currentSlide = $state(0);

  const slides = [
    { title: 'Gehen Sie durch jeden Raum', desc: 'Öffnen Sie Schränke und zeigen Sie alle Möbel, die umgezogen werden sollen.' },
    { title: 'Halten Sie die Kamera ruhig', desc: 'Sorgen Sie für gute Beleuchtung und bewegen Sie die Kamera langsam.' },
    { title: 'Erfassen Sie alle Möbel', desc: 'Fotografieren Sie Möbel aus verschiedenen Winkeln für eine genaue Berechnung.' },
    { title: 'Wir berechnen Ihr Volumen', desc: 'Unsere KI analysiert Ihre Fotos und erstellt ein maßgeschneidertes Angebot.' },
  ];

  function next() {
    if (currentSlide < slides.length - 1) currentSlide++;
    else finish();
  }

  function finish() {
    localStorage.setItem('tutorialSeen', 'true');
    goto('/scan');
  }
</script>

<div class="flex min-h-screen flex-col items-center justify-between px-6 py-12">
  <button onclick={finish} class="self-end text-sm text-text-muted hover:text-accent">Überspringen</button>

  <div class="flex flex-1 flex-col items-center justify-center text-center">
    <div class="mb-4 text-6xl">
      {['🏠', '📷', '🛋️', '🤖'][currentSlide]}
    </div>
    <h2 class="mb-3 text-2xl font-bold text-primary">{slides[currentSlide].title}</h2>
    <p class="max-w-sm text-text-muted">{slides[currentSlide].desc}</p>
  </div>

  <div class="flex w-full max-w-xs flex-col items-center gap-4">
    <div class="flex gap-2">
      {#each slides as _, i}
        <div class="h-2 w-2 rounded-full transition {i === currentSlide ? 'bg-accent w-6' : 'bg-border'}"></div>
      {/each}
    </div>
    <button
      onclick={next}
      class="w-full rounded-xl bg-accent px-6 py-3 font-semibold text-white shadow-md transition hover:bg-accent-hover"
    >
      {currentSlide < slides.length - 1 ? 'Weiter' : 'Los geht\'s'}
    </button>
  </div>
</div>
