<script lang="ts">
  import '../app.css';
  let { children } = $props();
</script>

<div class="min-h-screen bg-bg text-label font-sans">
  {@render children()}
</div>
