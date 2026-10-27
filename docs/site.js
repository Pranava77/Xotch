// Xotch site behaviour. Everything that moves is CSS; this file only flips states.
// See DESIGN.md: one IntersectionObserver per job, one pointer listener, no loops of our own.

const root = document.documentElement;
const base = root.dataset.base || "";
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const nav = document.querySelector(".notch");

// The toggle flips away from whatever is showing now, and remembers it.
document.querySelector(".theme-toggle")?.addEventListener("click", () => {
  const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  try { localStorage.setItem("xotch-theme", root.dataset.theme); } catch {}
});

// Going to another page of the site: the notch drops down over this one first, and the next
// page opens back out of it (the head script there adds `arriving`).
document.addEventListener("click", (event) => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest("a[href]");
  if (!link || link.target || link.hasAttribute("download") || reduceMotion) return;
  const url = new URL(link.href, location.href);
  if (url.origin !== location.origin || url.pathname === location.pathname) return;
  event.preventDefault();
  // The black beat says where you're going, and the next page keeps saying it as it opens.
  const label = url.pathname.endsWith("/compare/") ? "Compare" : url.pathname === "/" || url.pathname.endsWith("/index.html") ? "Xotch" : link.textContent.trim();
  try { sessionStorage.setItem("xotch-curtain", label); } catch {}
  root.dataset.curtain = label;
  root.classList.add("leaving");
  setTimeout(() => { location.href = url.href; }, 420);
});
if (root.classList.contains("arriving")) setTimeout(() => root.classList.remove("arriving"), 900);
// Back to a page kept in memory: it should not still be covered.
addEventListener("pageshow", (event) => { if (event.persisted) root.classList.remove("leaving", "arriving"); });

// Smooth scrolling is only for following a link within the page. Focus, find-in-page and
// everything else land at once.
document.addEventListener("click", (event) => {
  const link = event.target.closest("a[href*='#']");
  if (!link || reduceMotion || link.pathname !== location.pathname) return;
  root.style.scrollBehavior = "smooth";
  setTimeout(() => { root.style.scrollBehavior = ""; }, 1200);
});

// ── The driver: the section in view sets the ears and the current link, the way the app's
//    ears show what's live. ──────────────────────────────────────────────────────────────
if (nav) {
  const earItems = nav.querySelectorAll(".ear-slot > span");
  const navLinks = nav.querySelectorAll("a[href*='#']:not(.name)");
  const now = new Date();
  const today = nav.querySelector("[data-today]");
  if (today) today.textContent = `${now.toLocaleDateString("en-US", { weekday: "short" })} ${now.getDate()}`;

  // When a section has more than one live thing for an ear, they take turns every 4 s, as the
  // app's ears do. Not under reduced motion, and not while the tab is hidden.
  let turnTimer = 0;
  const takeTurns = (id) => {
    clearInterval(turnTimer);
    const turns = [...nav.querySelectorAll(`[data-for="${id}"][data-turn]`)];
    if (turns.length < 2 || reduceMotion) return;
    let index = 0;
    turnTimer = setInterval(() => {
      if (document.hidden) return;
      turns[index].classList.remove("on");
      index = (index + 1) % turns.length;
      turns[index].classList.add("on");
    }, 4000);
  };
  const showSection = (id) => {
    root.dataset.section = id;
    nav.classList.toggle("ears-on", Boolean(id));
    let firstTurn = true;
    for (const item of earItems) {
      const mine = item.dataset.for === id && (!("turn" in item.dataset) || firstTurn);
      if (item.dataset.for === id && "turn" in item.dataset) firstTurn = false;
      item.classList.toggle("on", mine);
    }
    takeTurns(id);
    for (const link of navLinks) {
      if (link.hash === `#${id}` && link.pathname === location.pathname) link.setAttribute("aria-current", "location");
      else if (link.getAttribute("aria-current") === "location") link.removeAttribute("aria-current");
    }
  };
  const sections = document.querySelectorAll("[data-ear]");
  const watcher = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) showSection(entry.target.dataset.ear);
  }, { rootMargin: "-35% 0px -60% 0px" });
  sections.forEach((section) => watcher.observe(section));
  if (sections[0] && scrollY < 40) showSection(sections[0].dataset.ear);

  // On a phone, the sections drop out of the notch.
  const menuToggle = nav.querySelector(".menu-toggle");
  const setMenu = (open) => {
    nav.classList.toggle("open", open);
    menuToggle?.setAttribute("aria-expanded", String(open));
    if (open) nav.querySelector(".notch-menu a")?.focus({ preventScroll: true });
  };
  menuToggle?.addEventListener("click", () => setMenu(!nav.classList.contains("open")));
  nav.querySelector(".notch-menu")?.addEventListener("click", (event) => { if (event.target.closest("a")) setMenu(false); });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && nav.classList.contains("open")) { setMenu(false); menuToggle.focus(); }
  });
  document.addEventListener("click", (event) => { if (!nav.contains(event.target)) setMenu(false); });
}

// ── Mascots: page-mascot's sheets, moved the way Xotch moves them (Design/Mascot.swift). ──
const Cell = { upLeft: 0, up: 1, upRight: 2, left: 3, center: 4, right: 5, downLeft: 6, down: 7, downRight: 8 };
const Reaction = { blink: 0, heart: 1, sparkle: 2, dizzy: 7, delighted: 8 };
const PAYOFFS = [Reaction.heart, Reaction.sparkle, Reaction.delighted];
const SECTORS = [Cell.right, Cell.downRight, Cell.down, Cell.downLeft, Cell.left, Cell.upLeft, Cell.up, Cell.upRight];
const DEAD_ZONE = 70;
const HYSTERESIS = 0.12;

// The cell to show for a pointer dx, dy away (y down), given the one showing now.
function direction(dx, dy, previous) {
  if (Math.hypot(dx, dy) < DEAD_ZONE) return Cell.center;
  const angle = Math.atan2(dy, dx);
  const width = Math.PI / 4;
  const index = SECTORS.indexOf(previous);
  if (index >= 0) {
    let offset = angle - index * width;
    while (offset > Math.PI) offset -= 2 * Math.PI;
    while (offset < -Math.PI) offset += 2 * Math.PI;
    if (Math.abs(offset) <= width / 2 + HYSTERESIS) return previous;
  }
  let slot = Math.round(angle / width) % 8;
  if (slot < 0) slot += 8;
  return SECTORS[slot];
}

// The poses a turn passes through, one step of the 3 × 3 grid at a time, as a head would.
function path(from, to) {
  let col = from % 3, row = Math.floor(from / 3);
  const steps = [];
  while (col !== to % 3 || row !== Math.floor(to / 3)) {
    col += Math.sign((to % 3) - col);
    row += Math.sign(Math.floor(to / 3) - row);
    steps.push(row * 3 + col);
  }
  return steps;
}

const mascots = [...document.querySelectorAll(".mascot[data-character]")].map((el, i) => {
  const id = el.dataset.character;
  el.style.setProperty("--sheet", `url("${base}images/mascots/${id}-directions.avif")`);
  el.style.setProperty("--phase", `${-(i * 0.37) % 3.2}s`);
  if (!el.querySelector(".sprite")) el.insertAdjacentHTML("afterbegin", '<span class="sprite"></span>');
  return { el, id, cell: Cell.center, steps: [], timer: 0, visible: false, reaction: null, boops: [] };
});

function show(m, cell, reaction = false) {
  m.el.classList.toggle("reacting", reaction);
  m.el.style.setProperty("--col", cell % 3);
  m.el.style.setProperty("--row", Math.floor(cell / 3));
}

function lookAt(m, target) {
  if (m.reaction !== null) return;
  if (target === (m.steps.at(-1) ?? m.cell)) return;
  m.steps = reduceMotion ? [target] : path(m.cell, target);
  if (m.timer) return;
  const step = () => {
    const next = m.steps.shift();
    if (next === undefined) { m.timer = 0; return; }
    m.cell = next;
    show(m, next);
    m.timer = setTimeout(step, 60);
  };
  step();
}

function react(m, reaction, ms) {
  if (!m.el.style.getPropertyValue("--reactions")) {
    m.el.style.setProperty("--reactions", `url("${base}images/mascots/${m.id}-reactions.avif")`);
  }
  clearTimeout(m.reactTimer);
  m.reaction = reaction;
  show(m, reaction, true);
  m.reactTimer = setTimeout(() => { m.reaction = null; show(m, m.cell); }, ms);
}

// A boop blinks, then shows a heart, a sparkle or delight in turn; the fourth within 1.6 s
// makes it dizzy instead.
function boop(m) {
  const now = performance.now();
  m.boops = [...m.boops.filter((t) => now - t < 1600), now];
  let payoff = PAYOFFS[(m.boops.length - 1) % PAYOFFS.length];
  if (m.boops.length >= 4) { m.boops = []; payoff = Reaction.dizzy; }
  if (!reduceMotion) {
    m.el.classList.remove("squash");
    void m.el.offsetWidth;
    m.el.classList.add("squash");
  }
  react(m, Reaction.blink, 140);
  setTimeout(() => react(m, payoff, 1100), 140);
}

if (mascots.length) {
  const seen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const m = mascots.find((x) => x.el === entry.target);
      if (m) m.visible = entry.isIntersecting;
    }
  });
  mascots.forEach((m) => { show(m, m.cell); seen.observe(m.el); });

  let pointer = null, queued = false;
  const update = () => {
    queued = false;
    if (!pointer) return;
    for (const m of mascots) {
      if (!m.visible) continue;
      const r = m.el.getBoundingClientRect();
      lookAt(m, direction(pointer.x - (r.left + r.width / 2), pointer.y - (r.top + r.height / 2), m.steps.at(-1) ?? m.cell));
    }
  };
  const track = (event) => {
    pointer = { x: event.clientX, y: event.clientY };
    if (!queued) { queued = true; requestAnimationFrame(update); }
  };
  addEventListener("pointermove", track, { passive: true });
  addEventListener("pointerdown", track, { passive: true });

  document.querySelectorAll("[data-boop]").forEach((button) => {
    const m = mascots.find((x) => button.contains(x.el));
    if (m) button.addEventListener("click", () => boop(m));
  });

  // Now and then, a mascot on screen blinks.
  if (!reduceMotion) {
    const blink = () => {
      const awake = mascots.filter((m) => m.visible && m.reaction === null && !document.hidden);
      const m = awake[Math.floor(Math.random() * awake.length)];
      if (m) react(m, Reaction.blink, 150);
      setTimeout(blink, 1400 + Math.random() * 2400);
    };
    setTimeout(blink, 2200);
  }
}

// ── Dictation poster: the three beats drop in when the section arrives. ──
document.querySelectorAll(".poster").forEach((poster) => {
  const once = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) { poster.classList.add("in-view"); once.disconnect(); }
  }, { rootMargin: "0px 0px -10% 0px" });
  once.observe(poster);
});

// ── Your day: the row you point at, or the one in the middle of the screen, fills the preview. ──
const modules = document.querySelector(".modules");
if (modules) {
  const rows = [...modules.querySelectorAll("li")];
  const pictures = [...document.querySelectorAll(".preview-frame img")];
  const caption = document.querySelector(".preview .caption");
  let hovering = false;
  const activate = (row) => {
    for (const r of rows) r.classList.toggle("active", r === row);
    modules.style.setProperty("--marker-y", `${row.offsetTop}px`);
    // The ear names the module you're on, as the app's tab does.
    const ear = document.querySelector("[data-module-label]");
    if (ear) ear.textContent = row.dataset.label;
    for (const p of pictures) p.classList.toggle("on", p.dataset.module === row.dataset.module);
    if (caption) caption.textContent = row.querySelector("img")?.alt ?? "";
  };
  rows.forEach((row) => row.addEventListener("pointerenter", () => { hovering = true; activate(row); }));
  modules.addEventListener("pointerleave", () => { hovering = false; });
  const middle = new IntersectionObserver((entries) => {
    if (hovering) return;
    for (const entry of entries) if (entry.isIntersecting) activate(entry.target);
  }, { rootMargin: "-45% 0px -50% 0px" });
  rows.forEach((row) => middle.observe(row));
  activate(rows[0]);
}

// ── While it's closed, the ears take turns: every 4 s, only on screen, never under a pointer
//    or focus, and not at all under reduced motion. A choice stops the turns. ──
const demo = document.querySelector(".ears-demo");
if (demo) {
  const pictures = [...demo.querySelectorAll(".ears-stage img")];
  const buttons = [...demo.querySelectorAll(".ears-legend button")];
  const pause = demo.querySelector(".ears-pause");
  let index = 0, timer = 0, onScreen = false, held = false, stopped = reduceMotion;
  const select = (i) => {
    index = i;
    pictures.forEach((p, n) => p.classList.toggle("on", n === i));
    buttons.forEach((b, n) => b.setAttribute("aria-pressed", String(n === i)));
  };
  const schedule = () => {
    clearTimeout(timer);
    if (onScreen && !held && !stopped) timer = setTimeout(() => { select((index + 1) % pictures.length); schedule(); }, 4000);
  };
  const setStopped = (value) => {
    stopped = value;
    pause.textContent = stopped ? "Take turns" : "Stop taking turns";
    schedule();
  };
  buttons.forEach((b, n) => b.addEventListener("click", () => { select(n); setStopped(true); }));
  pause.addEventListener("click", () => setStopped(!stopped));
  demo.addEventListener("pointerenter", () => { held = true; schedule(); });
  demo.addEventListener("pointerleave", () => { held = false; schedule(); });
  demo.addEventListener("focusin", () => { held = true; schedule(); });
  demo.addEventListener("focusout", () => { held = false; schedule(); });
  new IntersectionObserver(([entry]) => { onScreen = entry.isIntersecting; schedule(); }).observe(demo);
  select(0);
  setStopped(stopped);
}

// ── Compare table: its header stays under the menu bar only while the table is on screen. ──
const tableScroll = document.querySelector(".table-scroll");
const lastRow = tableScroll?.querySelector("caption") ?? tableScroll?.querySelector("tbody tr:last-child");
if (lastRow) {
  new IntersectionObserver(([entry]) => {
    tableScroll.classList.toggle("past", !entry.isIntersecting && entry.boundingClientRect.top < 0);
  }, { rootMargin: "-130px 0px 0px 0px" }).observe(lastRow);
}
