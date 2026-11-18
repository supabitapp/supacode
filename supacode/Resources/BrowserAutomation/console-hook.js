(() => {
  if (window.__supacodeConsoleHooked) return;
  Object.defineProperty(window, '__supacodeConsoleHooked', { value: true });

  const format = (value) => {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return value.stack || String(value);
    try {
      const json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (error) {
      return String(value);
    }
  };

  const post = (level, values) => {
    try {
      window.webkit.messageHandlers.supacodeConsole.postMessage({ level, text: values.map(format).join(' ') });
    } catch (error) {
      return;
    }
  };

  for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
    const original = console[level];
    console[level] = function (...values) {
      post(level, values);
      return original.apply(this, values);
    };
  }

  window.addEventListener('error', (event) => {
    if (!event.filename && (!event.message || event.message === 'Script error.')) return;
    const where = event.filename ? ' (' + event.filename + ':' + event.lineno + ')' : '';
    post('error', [event.message + where]);
  });

  window.addEventListener('unhandledrejection', (event) => {
    post('error', ['Unhandled rejection: ' + format(event.reason)]);
  });
})();
