import { DIFFS_TAG_NAME, FileDiff, parsePatchFiles } from "@pierre/diffs";
import baseStyles from "../node_modules/@pierre/diffs/dist/style.js";

const state = {
  instances: [],
  patchText: "",
  diffStyle: "split",
  theme: "light",
};

if (typeof HTMLElement !== "undefined" && customElements.get(DIFFS_TAG_NAME) == null) {
  class DiffsContainerElement extends HTMLElement {
    constructor() {
      super();
      if (this.shadowRoot != null) {
        return;
      }
      const shadowRoot = this.attachShadow({ mode: "open" });
      const style = document.createElement("style");
      style.textContent = baseStyles;
      shadowRoot.append(style);
    }
  }

  customElements.define(DIFFS_TAG_NAME, DiffsContainerElement);
}

function rootElement() {
  return document.getElementById("panel-root");
}

function clearInstances() {
  for (const instance of state.instances) {
    instance.cleanUp();
  }
  state.instances = [];
}

function clearRoot(root) {
  clearInstances();
  root.removeAttribute("data-empty");
  root.replaceChildren();
}

function renderError(message) {
  const root = rootElement();
  if (root == null) {
    return;
  }
  clearRoot(root);
  const error = document.createElement("div");
  error.dataset.panelError = "";
  error.textContent = message;
  root.append(error);
}

function renderCurrent() {
  const root = rootElement();
  if (root == null) {
    return;
  }
  clearRoot(root);
  const patchText = typeof state.patchText === "string" ? state.patchText : "";
  if (patchText.trim().length === 0) {
    root.dataset.empty = "";
    return;
  }
  let parsedPatchFiles;
  try {
    parsedPatchFiles = parsePatchFiles(patchText, "supacode-patch");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    renderError(message);
    return;
  }
  let renderedFileCount = 0;
  for (const patch of parsedPatchFiles) {
    for (const fileDiff of patch.files) {
      const container = document.createElement(DIFFS_TAG_NAME);
      root.append(container);
      const instance = new FileDiff({
        theme: { light: "pierre-light", dark: "pierre-dark" },
        themeType: state.theme,
        diffStyle: state.diffStyle,
        overflow: "scroll",
      });
      instance.render({ fileDiff, fileContainer: container });
      state.instances.push(instance);
      renderedFileCount += 1;
    }
  }
  if (renderedFileCount == 0) {
    root.dataset.empty = "";
  }
}

function normalizeTheme(themeName) {
  return themeName === "dark" ? "dark" : "light";
}

function normalizeDiffStyle(diffStyle) {
  return diffStyle === "unified" ? "unified" : "split";
}

window.SupacodePierrePanel = {
  renderPatch(patchText, options = {}) {
    state.patchText = typeof patchText === "string" ? patchText : "";
    state.diffStyle = normalizeDiffStyle(options.diffStyle);
    renderCurrent();
  },
  clear() {
    state.patchText = "";
    renderCurrent();
  },
  setTheme(themeName) {
    state.theme = normalizeTheme(themeName);
    renderCurrent();
  },
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    renderCurrent();
  });
} else {
  renderCurrent();
}
