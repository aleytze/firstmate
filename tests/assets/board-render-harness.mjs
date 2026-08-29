// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}],
//     underway|landed|charted:[{title,sub,badges,pickable,textTag,tooltip,disclosure}],
//     presses:[{open,expanded,tooltip}], empty, more, error }
// The shim has no layout, so it reports what the renderer builds unconditionally
// and never what a real browser measures: the clamp and the clipped-row pass are
// verified in a browser, not here. Pressing the disclosure needs no layout, so
// the shim does dispatch it and reports what the row became.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const on = force === undefined ? !this.classList.contains(c) : !!force;
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; }
  removeAttribute(k) { delete this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  // no event system, just the handlers this node registered for itself
  dispatch(type) { for (const fn of this.listeners[type] || []) fn({ target: this }); }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowNodesOf = (containerId) =>
  (byId.get(containerId) || new Node("div")).children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"));

const mainOf = (row) => row.children.find((c) => c.className.includes("bb-row__main"));
const chevronOf = (row) => mainOf(row)?.children.find((c) => c.className.includes("bb-row__more"));

const reportRow = (row) => {
  const main = mainOf(row);
  const more = chevronOf(row);
  return {
    title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
    sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
    badges: badgesOf(row),
    pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
    // the text block itself: plain, selectable, and carrying the whole string
    // for a mouse hover
    textTag: main?.tagName ?? null,
    tooltip: main?.getAttribute("title") ?? null,
    // the separate control a keyboard and a touch tap reach the rest through
    disclosure: more
      ? { tag: more.tagName, type: more.type,
          expanded: more.getAttribute("aria-expanded"),
          label: more.getAttribute("aria-label") }
      : null,
  };
};

const ch = byId.get("bb-charted") || new Node("div");
const chartedNodes = rowNodesOf("bb-charted");
const underwayNodes = rowNodesOf("bb-underway");
const landedNodes = rowNodesOf("bb-landed");
const charted = chartedNodes.map(reportRow);
const underway = underwayNodes.map(reportRow);
const landed = landedNodes.map(reportRow);

// Opening a row needs no layout engine, so the shim presses the chevron twice
// and reports what the row, the button and the hover tooltip became each time.
const pressDisclosure = (row) => {
  const more = chevronOf(row);
  if (!more) return null;
  more.dispatch("click");
  return { open: row.classList.contains("is-open"), expanded: more.getAttribute("aria-expanded"),
    tooltip: mainOf(row).getAttribute("title") };
};
const firstRow = chartedNodes[0] ?? underwayNodes[0] ?? landedNodes[0];
const presses = firstRow ? [pressDisclosure(firstRow), pressDisclosure(firstRow)] : [];
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, charted, underway, landed, presses, empty, more, error: errorText }) + "\n");
