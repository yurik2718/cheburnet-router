<script>
  // type: 'text' | 'password' | 'number' — как у нативного input, стили общие.
  // el — сам DOM-узел наружу (bind:el): нужен там, где вызывающему надо .focus().
  let { value = $bindable(''), type = 'text', el = $bindable(null), ...rest } = $props();
</script>

<input bind:this={el} {type} bind:value {...rest} />

<style>
  input {
    width: 100%;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--line);
    border-radius: var(--radius-md);
    padding: 0.6rem;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 0.9rem;
    transition: border-color 0.15s;
  }
  /* Числовое поле на всю ширину выглядело бы полем для длинного значения — а тут 2–4 цифры. */
  input[type="number"] { width: 8rem; }
  input:hover:not(:disabled) { border-color: var(--muted); }
  input:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; border-color: var(--accent); }
  /* Квирк iOS: шрифт < 16px на фокусе зумит страницу — подробнее в app.css. */
  @media (max-width: 640px) { input { font-size: 1rem; } }
</style>
