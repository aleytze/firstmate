// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], measured,
//     underway|landed|charted:[{title,sub,badges,pickable,textTag,tooltip,textIds,clip,disclosure}],
//     presses:[{open,expanded,tooltip}], empty, more, error }
// There is no layout engine here, so text is modeled as a monospace paragraph
// wrapped at WRAP_COLS and clamped to CLAMP_LINES - the stylesheet's own
// two-line clamp - which is enough for the renderer's clipped-row pass to run
// and decide the same way it does in a browser. How wide a real glyph is stays
// a browser question; that a row hiding text keeps its disclosure is decided
// here. Setting FM_BOARD_HARNESS_MEASURE=off makes every measurement throw and
// =zero makes every measurement read zero, the two shapes of an environment
// where the pass cannot run at all.
import { readFileSync } from "node:fs";

const WRAP_COLS = 48;
const CLAMP_LINES = 2;
const LINE_PX = 20;
const MEASURE_MODE = process.env.FM_BOARD_HARNESS_MEASURE || "on";
const MEASURABLE = MEASURE_MODE !== "off";
const NO_LAYOUT = MEASURE_MODE === "zero";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.id = "";
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
  get _lines() {
    if (!MEASURABLE) throw new Error("layout is unavailable");
    return Math.max(1, Math.ceil(this.textContent.length / WRAP_COLS));
  }
  get scrollHeight() { return NO_LAYOUT ? 0 : this._lines * LINE_PX; }
  // clamped like the stylesheet, except inside a row the renderer has opened
  get clientHeight() {
    if (NO_LAYOUT) return 0;
    const lines = this._lines;
    let clamp = true;
    for (let n = this.parentNode; n; n = n.parentNode) {
      if (n.classList.contains("is-open")) { clamp = false; break; }
    }
    return (clamp ? Math.min(lines, CLAMP_LINES) : lines) * LINE_PX;
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
  dispatch(type) {
    if (this.disabled) return;
    for (const fn of this.listeners[type] || []) fn({ target: this });
  }
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

const body = new Node("body");
globalThis.document = {
  // the clipped-row pass is gated on a body carrying a classList, and marks it
  // once it has measured, so the shim supplies a real one
  body,
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
  const titleNode = main?.children.find((c) => c.className.includes("bb-row__title"));
  const subNode = main?.children.find((c) => c.className.includes("bb-row__sub"));
  return {
    title: titleNode?.textContent ?? "",
    sub: subNode?.textContent ?? "",
    badges: badgesOf(row),
    pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
    // the text block itself: plain, selectable, and carrying the whole string
    // for a mouse hover
    textTag: main?.tagName ?? null,
    tooltip: main?.getAttribute("title") ?? null,
    // the ids of the two spans the row actually expands, so a caller can check
    // what the button points at and that no two rows were given the same name
    textIds: [titleNode?.id ?? "", subNode?.id ?? ""],
    // what the measurement pass concluded this row hides
    clip: row.classList.contains("bb-row--clip"),
    // the separate control a keyboard and a touch tap reach the rest through
    disclosure: more
      ? { tag: more.tagName, type: more.type,
          expanded: more.getAttribute("aria-expanded"),
          label: more.getAttribute("aria-label"),
          controls: more.getAttribute("aria-controls"),
          disabled: more.disabled }
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
  JSON.stringify({ stats, measured: body.classList.contains("bb-measured"),
    charted, underway, landed, presses, empty, more, error: errorText }) + "\n");
