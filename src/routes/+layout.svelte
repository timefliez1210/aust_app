<script lang="ts">
  import '../app.css';
  let { children } = $props();
</script>

<div class="min-h-screen bg-bg font-sans text-text">
  {@render children()}
</div>
