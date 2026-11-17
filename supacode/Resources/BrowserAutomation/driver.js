function supacodeCreateDriver(engine, config) {
  const refPrefix = config.refPrefix || '';
  const refPattern = /^(p\d+)?e\d+$/;
  const snapshotOptions = { mode: 'ai', refPrefix, doNotRenderActive: true };
  const maskedValue = '[masked]';

  class DriverError extends Error {}

  const fail = (message) => {
    throw new DriverError(message);
  };

  const snapshotRoot = () => document.body || document.documentElement;

  const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  const maskPasswords = (text) => {
    if (!text) return text;
    let masked = text;
    for (const input of document.querySelectorAll('input[type="password"]')) {
      const ref = input._ariaRef && input._ariaRef.ref;
      if (!ref || !input.value) continue;
      const line = new RegExp('^(\\s*- .*\\[ref=' + escapeRegExp(ref) + '\\](?: \\[[^\\]\\n]*\\])*\'?): .*$', 'm');
      masked = masked.replace(line, '$1: ' + maskedValue);
    }
    return masked;
  };

  const snapshot = () => ({
    text: maskPasswords(engine.ariaSnapshot(snapshotRoot(), snapshotOptions)),
    url: location.href,
    title: document.title,
  });

  const describe = (element) => {
    const role = engine.utils.getAriaRole(element) || element.nodeName.toLowerCase();
    const name = (engine.utils.getElementAccessibleName(element, false) || '').replace(/\s+/g, ' ').trim();
    const shortName = name.length > 60 ? name.slice(0, 57) + '...' : name;
    const ref = element._ariaRef && element._ariaRef.ref;
    return role + (shortName ? ' ' + JSON.stringify(shortName) : '') + (ref ? ' [ref=' + ref + ']' : '');
  };

  const resolveRef = (ref) => {
    const prefix = ref.slice(0, ref.lastIndexOf('e'));
    if (prefix !== refPrefix) {
      fail('Ref ' + ref + ' is from a page that is gone. Run `snapshot` for current refs.');
    }
    if (!engine._lastAriaSnapshotForQuery) snapshot();
    const matches = engine.querySelectorAll(engine.parseSelector('aria-ref=' + ref), document);
    if (!matches.length) {
      fail('Ref ' + ref + ' is not on the page now. Run `snapshot` for current refs.');
    }
    return matches[0];
  };

  const resolveLocator = (locator) => {
    let parsed;
    try {
      parsed = engine.parseSelector(locator);
    } catch (error) {
      fail('Cannot parse locator ' + JSON.stringify(locator) + ': ' + error.message);
    }
    const matches = engine.querySelectorAll(parsed, document);
    if (!matches.length) fail('No element matches ' + JSON.stringify(locator) + '.');
    if (matches.length > 1) {
      const shown = matches.slice(0, 3).map((match) => '  ' + describe(match)).join('\n');
      fail(
        matches.length + ' elements match ' + JSON.stringify(locator) + '. Use a ref or a narrower locator:\n' + shown
      );
    }
    return matches[0];
  };

  const resolve = (target) => {
    if (typeof target !== 'string' || !target) fail('Missing target.');
    return refPattern.test(target) ? resolveRef(target) : resolveLocator(target);
  };

  const requireState = (element, state, problem) => {
    const result = engine.elementState(element, state);
    if (!result.matches) fail(describe(element) + ' ' + problem + '.');
  };

  const deepElementFromPoint = (x, y) => {
    let hit = document.elementFromPoint(x, y);
    while (hit && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  };

  const clickPoint = (element) => {
    element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const rect = Array.from(element.getClientRects()).find((box) => box.width > 0 && box.height > 0);
    if (!rect) fail(describe(element) + ' has no visible area to click.');
    const left = Math.max(rect.left, 0);
    const top = Math.max(rect.top, 0);
    const right = Math.min(rect.right, window.innerWidth);
    const bottom = Math.min(rect.bottom, window.innerHeight);
    if (right <= left || bottom <= top) fail(describe(element) + ' is outside the viewport and cannot scroll into it.');
    return { x: (left + right) / 2, y: (top + bottom) / 2 };
  };

  const focusableAncestor = (element) => {
    for (let node = element; node; node = node.parentElement || (node.getRootNode() && node.getRootNode().host)) {
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      if (node.matches('input, select, textarea, button') && node.disabled) return null;
      if (node.tabIndex >= 0 || node.isContentEditable) return node;
    }
    return null;
  };

  const activeElement = () => {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) {
      active = active.shadowRoot.activeElement;
    }
    return active || document.body;
  };

  const ancestorsFromRoot = (element) => {
    const chain = [];
    for (let node = element; node; node = node.parentElement) chain.unshift(node);
    return chain;
  };

  const click = ({ target }) => {
    const element = resolve(target);
    requireState(element, 'visible', 'is not visible');
    requireState(element, 'enabled', 'is disabled');
    const point = clickPoint(element);
    const hitCheck = engine.expectHitTarget(point, element);
    if (hitCheck !== 'done') {
      fail(describe(element) + ' is covered by ' + hitCheck.hitTargetDescription + '.');
    }
    const hit = deepElementFromPoint(point.x, point.y) || element;
    const mouse = (buttons) => ({
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: point.x,
      clientY: point.y,
      screenX: point.x,
      screenY: point.y,
      button: 0,
      buttons,
      detail: 1,
    });
    const pointer = (buttons) => ({ ...mouse(buttons), pointerId: 1, pointerType: 'mouse', isPrimary: true });
    hit.dispatchEvent(new PointerEvent('pointerover', pointer(0)));
    hit.dispatchEvent(new MouseEvent('mouseover', mouse(0)));
    for (const node of ancestorsFromRoot(hit)) {
      node.dispatchEvent(new PointerEvent('pointerenter', { ...pointer(0), bubbles: false, cancelable: false }));
      node.dispatchEvent(new MouseEvent('mouseenter', { ...mouse(0), bubbles: false, cancelable: false }));
    }
    hit.dispatchEvent(new PointerEvent('pointermove', pointer(0)));
    hit.dispatchEvent(new MouseEvent('mousemove', mouse(0)));
    hit.dispatchEvent(new PointerEvent('pointerdown', pointer(1)));
    if (hit.dispatchEvent(new MouseEvent('mousedown', mouse(1)))) {
      const focusable = focusableAncestor(hit);
      if (focusable) focusable.focus({ preventScroll: true });
      else if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    }
    hit.dispatchEvent(new PointerEvent('pointerup', pointer(0)));
    hit.dispatchEvent(new MouseEvent('mouseup', mouse(0)));
    hit.dispatchEvent(new MouseEvent('click', mouse(0)));
    return { ack: 'clicked ' + describe(element) };
  };

  const editableValue = (element) =>
    element.matches('input, textarea') ? element.value : (element.innerText || '').replace(/\n$/, '');

  const writeValue = (element, text) => {
    if (element.matches('input, textarea')) {
      element.value = text;
    } else {
      element.textContent = text;
    }
    element.dispatchEvent(
      new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text })
    );
    element.dispatchEvent(new Event('change', { bubbles: true }));
  };

  const fill = ({ target, text }) => {
    if (typeof text !== 'string') fail('Missing text.');
    const resolved = resolve(target);
    const element = engine.retarget(resolved, 'follow-label') || resolved;
    if (element.nodeName === 'SELECT') {
      fail(describe(element) + ' is a select. Use `select` with an option label or value.');
    }
    requireState(element, 'visible', 'is not visible');
    let editable;
    try {
      editable = engine.elementState(element, 'editable');
    } catch (error) {
      fail(describe(element) + ' cannot be filled: ' + error.message);
    }
    if (!editable.matches) fail(describe(element) + ' is ' + editable.received + '.');
    let outcome;
    try {
      outcome = engine.fill(element, text);
    } catch (error) {
      fail(describe(element) + ' cannot be filled: ' + error.message);
    }
    if (outcome === 'needsinput') {
      if (text) document.execCommand('insertText', false, text);
      else document.execCommand('delete', false);
      if (editableValue(element) !== text) writeValue(element, text);
    }
    const shown = element.type === 'password' ? maskedValue : JSON.stringify(text);
    return { ack: 'filled ' + describe(element) + ' with ' + shown };
  };

  const select = ({ target, option }) => {
    if (typeof option !== 'string') fail('Missing option.');
    const resolved = resolve(target);
    const element = engine.retarget(resolved, 'follow-label') || resolved;
    if (element.nodeName !== 'SELECT') fail(describe(element) + ' is not a select.');
    requireState(element, 'enabled', 'is disabled');
    const options = Array.from(element.options);
    const match =
      options.find((candidate) => candidate.label === option || candidate.text.trim() === option) ||
      options.find((candidate) => candidate.value === option);
    if (!match) {
      const labels = options.slice(0, 12).map((candidate) => JSON.stringify(candidate.label));
      fail(describe(element) + ' has no option ' + JSON.stringify(option) + '. Options: ' + labels.join(', ') + '.');
    }
    if (match.disabled) fail('Option ' + JSON.stringify(option) + ' is disabled.');
    element.focus({ preventScroll: true });
    match.selected = true;
    element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    return { ack: 'selected ' + JSON.stringify(match.label) + ' in ' + describe(element) };
  };

  const namedKeys = {
    enter: { key: 'Enter', code: 'Enter', keyCode: 13 },
    return: { key: 'Enter', code: 'Enter', keyCode: 13 },
    tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
    escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
    esc: { key: 'Escape', code: 'Escape', keyCode: 27 },
    backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
    delete: { key: 'Delete', code: 'Delete', keyCode: 46 },
    space: { key: ' ', code: 'Space', keyCode: 32 },
    arrowup: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
    arrowdown: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
    arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
    arrowright: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
    home: { key: 'Home', code: 'Home', keyCode: 36 },
    end: { key: 'End', code: 'End', keyCode: 35 },
    pageup: { key: 'PageUp', code: 'PageUp', keyCode: 33 },
    pagedown: { key: 'PageDown', code: 'PageDown', keyCode: 34 },
  };

  const modifierNames = {
    control: 'ctrlKey',
    ctrl: 'ctrlKey',
    shift: 'shiftKey',
    alt: 'altKey',
    option: 'altKey',
    meta: 'metaKey',
    cmd: 'metaKey',
    command: 'metaKey',
  };

  const parseKey = (combo) => {
    if (typeof combo !== 'string' || !combo) fail('Missing key.');
    const parts = combo === '+' ? ['+'] : combo.split('+').map((part) => part || '+');
    const keyName = parts.pop();
    const modifiers = { ctrlKey: false, shiftKey: false, altKey: false, metaKey: false };
    for (const part of parts) {
      const modifier = modifierNames[part.toLowerCase()];
      if (!modifier) fail('Unknown modifier ' + JSON.stringify(part) + ' in ' + JSON.stringify(combo) + '.');
      modifiers[modifier] = true;
    }
    const named = namedKeys[keyName.toLowerCase()];
    if (named) return { ...named, ...modifiers, printable: named.key === ' ' };
    if (Array.from(keyName).length !== 1) {
      fail('Unknown key ' + JSON.stringify(keyName) + '. Use a character or a name such as Enter, Tab, or ArrowDown.');
    }
    const upper = keyName.toUpperCase();
    const code = /^[A-Z]$/.test(upper) ? 'Key' + upper : /^[0-9]$/.test(keyName) ? 'Digit' + keyName : '';
    return { key: keyName, code, keyCode: upper.charCodeAt(0), ...modifiers, printable: true };
  };

  const isEditable = (element) =>
    element.isContentEditable ||
    element.nodeName === 'TEXTAREA' ||
    (element.nodeName === 'INPUT' &&
      !['checkbox', 'radio', 'button', 'submit', 'reset', 'file', 'image', 'range', 'color'].includes(element.type));

  const tabbables = () =>
    Array.from(
      document.querySelectorAll('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]')
    ).filter(
      (element) => element.tabIndex >= 0 && !element.disabled && engine.utils.isElementVisible(element)
    );

  const moveFocus = (backwards) => {
    const candidates = tabbables();
    if (!candidates.length) return;
    const index = candidates.indexOf(activeElement());
    const step = backwards ? -1 : 1;
    const next = index < 0 ? (backwards ? candidates.length - 1 : 0) : index + step;
    candidates[(next + candidates.length) % candidates.length].focus();
  };

  const submitFrom = (input) => {
    const form = input.form;
    if (!form) return;
    const submitter = Array.from(form.elements).find(
      (element) => element.type === 'submit' && !element.disabled && element.matches('button, input')
    );
    if (submitter) submitter.click();
    else form.requestSubmit();
  };

  const applyKeyDefault = (element, key) => {
    const hasCommandModifier = key.ctrlKey || key.metaKey;
    if (key.key === 'Tab') return moveFocus(key.shiftKey);
    if (hasCommandModifier) {
      if (key.key.toLowerCase() === 'a' && isEditable(element)) document.execCommand('selectAll', false);
      return undefined;
    }
    if (key.key === 'Enter') {
      if (element.nodeName === 'TEXTAREA') return document.execCommand('insertText', false, '\n');
      if (element.isContentEditable) return document.execCommand('insertLineBreak', false);
      if (element.nodeName === 'INPUT' && isEditable(element)) return submitFrom(element);
      if (element.matches('button, a[href], summary, [role="button"], [role="link"]')) return element.click();
      return undefined;
    }
    if (key.key === ' ' && element.matches('button, summary, input[type="checkbox"], input[type="radio"], [role="button"]')) {
      return element.click();
    }
    if (!isEditable(element)) return undefined;
    if (key.key === 'Backspace') return document.execCommand('delete', false);
    if (key.key === 'Delete') return document.execCommand('forwardDelete', false);
    if (key.printable) return document.execCommand('insertText', false, key.key);
    return undefined;
  };

  const press = ({ key: combo, target }) => {
    const key = parseKey(combo);
    if (target) {
      const element = resolve(target);
      requireState(element, 'visible', 'is not visible');
      engine.focusNode(engine.retarget(element, 'follow-label') || element, false);
    }
    const element = activeElement();
    const init = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      key: key.key,
      code: key.code,
      keyCode: key.keyCode,
      which: key.keyCode,
      ctrlKey: key.ctrlKey,
      shiftKey: key.shiftKey,
      altKey: key.altKey,
      metaKey: key.metaKey,
    };
    let proceed = element.dispatchEvent(new KeyboardEvent('keydown', init));
    if (proceed && key.printable && !key.ctrlKey && !key.metaKey) {
      const charCode = key.key.charCodeAt(0);
      proceed = element.dispatchEvent(new KeyboardEvent('keypress', { ...init, keyCode: charCode, which: charCode, charCode }));
    }
    if (proceed) applyKeyDefault(element, key);
    activeElement().dispatchEvent(new KeyboardEvent('keyup', init));
    return { ack: 'pressed ' + combo + (element === document.body ? '' : ' on ' + describe(element)) };
  };

  const globToRegExp = (glob) => new RegExp('^' + glob.split('*').map(escapeRegExp).join('.*') + '$');

  const waitCondition = ({ text, url, target, state }) => {
    if (typeof text === 'string') {
      return {
        label: 'text ' + JSON.stringify(text),
        met: () => (snapshotRoot().innerText || '').includes(text),
      };
    }
    if (typeof url === 'string') {
      const pattern = url.includes('*') ? globToRegExp(url) : null;
      return {
        label: 'URL ' + JSON.stringify(url),
        met: () => (pattern ? pattern.test(location.href) : location.href.includes(url)),
      };
    }
    if (typeof target === 'string') {
      const wanted = state === 'hidden' ? 'hidden' : 'visible';
      return {
        label: target + ' to be ' + wanted,
        met: () => {
          let element;
          try {
            if (refPattern.test(target)) snapshot();
            element = resolve(target);
          } catch (error) {
            if (error instanceof DriverError) return wanted === 'hidden';
            throw error;
          }
          return engine.elementState(element, wanted).matches;
        },
      };
    }
    return fail('Nothing to wait for. Pass --text, --url, or a target.');
  };

  const wait = (args) => {
    const condition = waitCondition(args);
    const timeoutMs = typeof args.timeoutMs === 'number' ? args.timeoutMs : 10000;
    const started = Date.now();
    return new Promise((resolvePromise, rejectPromise) => {
      let timer;
      const observer = new MutationObserver(() => check());
      const finish = (settle, value) => {
        observer.disconnect();
        clearTimeout(timer);
        settle(value);
      };
      const check = () => {
        let met;
        try {
          met = condition.met();
        } catch (error) {
          finish(rejectPromise, error);
          return;
        }
        if (met) {
          finish(resolvePromise, { ack: 'found ' + condition.label });
        } else if (Date.now() - started >= timeoutMs) {
          finish(
            rejectPromise,
            new DriverError(
              'Timed out after ' + Math.round(timeoutMs / 100) / 10 + 's waiting for ' + condition.label + '.'
            )
          );
        } else {
          clearTimeout(timer);
          timer = setTimeout(check, 100);
        }
      };
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      check();
    });
  };

  const settle = ({ quietMs, maxMs }) => {
    const quiet = typeof quietMs === 'number' ? quietMs : 120;
    const limit = typeof maxMs === 'number' ? maxMs : 1500;
    return new Promise((resolvePromise) => {
      let quietTimer;
      const observer = new MutationObserver(() => {
        clearTimeout(quietTimer);
        quietTimer = setTimeout(done, quiet);
      });
      const limitTimer = setTimeout(done, limit);
      function done() {
        observer.disconnect();
        clearTimeout(quietTimer);
        clearTimeout(limitTimer);
        resolvePromise({});
      }
      observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      quietTimer = setTimeout(done, quiet);
    });
  };

  const commands = { snapshot, click, fill, select, press, wait, settle };

  const run = async (command, args) => {
    const handler = commands[command];
    if (!handler) return { ok: false, error: 'Unknown browser command ' + JSON.stringify(command) + '.' };
    try {
      return { ok: true, ...(await handler(args || {})) };
    } catch (error) {
      if (error instanceof DriverError) return { ok: false, error: error.message };
      return { ok: false, error: 'Page script error: ' + ((error && error.message) || String(error)) };
    }
  };

  return { run };
}
