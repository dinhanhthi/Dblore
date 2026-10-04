// Theme toggle. The saved theme is applied early by a tiny inline script in <head>.
(() => {
  const root = document.documentElement;
  const button = document.getElementById("theme-toggle");
  if (!button) return;

  button.addEventListener("click", () => {
    const systemDark = matchMedia("(prefers-color-scheme: dark)").matches;
    const current = root.dataset.theme || (systemDark ? "dark" : "light");
    const next = current === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem("dblore.theme", next);
    } catch {
      // Storage blocked (private mode): the choice lasts for this visit only.
    }
  });
})();


// Docs scroll-spy: the active section is the last one whose top has passed near the viewport top.
(() => {
  const links = [...document.querySelectorAll(".toc a[href^='#']")];
  if (!links.length) return;
  const entries = links
    .map((link) => ({ link, section: document.getElementById(link.hash.slice(1)) }))
    .filter((entry) => entry.section);

  const update = () => {
    const atBottom = innerHeight + scrollY >= document.documentElement.scrollHeight - 2;
    let current = entries[0];
    for (const entry of entries) {
      if ((atBottom && scrollY > 0) || entry.section.getBoundingClientRect().top <= 120) current = entry;
    }
    for (const { link } of entries) {
      if (link === current.link) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    }
  };

  addEventListener("scroll", update, { passive: true });
  addEventListener("resize", update);
  update();
})();

// Header version: read from the same-origin appcast.xml, keeping the static fallback text on any failure.
(async () => {
  const badge = document.getElementById("version-badge");
  if (!badge) return;
  try {
    const response = await fetch("appcast.xml");
    if (!response.ok) return;
    const xml = new DOMParser().parseFromString(await response.text(), "application/xml");
    const ns = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    let best = null;
    for (const item of xml.getElementsByTagName("item")) {
      const build = Number(item.getElementsByTagNameNS(ns, "version")[0]?.textContent);
      const short = item.getElementsByTagNameNS(ns, "shortVersionString")[0]?.textContent?.trim();
      if (short && /^\d+(\.\d+)*$/.test(short) && Number.isFinite(build) && (!best || build > best.build)) best = { build, short };
    }
    if (!best) return;
    badge.textContent = `v${best.short}`;
    badge.href = `https://github.com/dinhanhthi/Dblore/releases/tag/v${best.short}`;
  } catch {
    // Offline or no appcast (local preview): keep the static version.
  }
})();

// Screenshot lightbox: click the poster or a thumbnail to open a full-screen carousel. Left/Right
// buttons or arrow keys navigate (looping); click anywhere or press Esc to close.
(() => {
  const triggers = [...document.querySelectorAll("[data-zoom]")];
  const slides = triggers
    .map((trigger) => trigger.querySelector("img"))
    .filter(Boolean)
    .map((img) => ({ src: img.src, alt: img.alt }));
  if (!slides.length || typeof HTMLDialogElement === "undefined") return;

  const dialog = document.createElement("dialog");
  dialog.className = "lightbox";
  dialog.setAttribute("aria-label", "Screenshot viewer");
  dialog.innerHTML = `
    <img alt="" />
    <button class="lightbox-arrow lightbox-arrow--prev" type="button" aria-label="Previous screenshot">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m15 6-6 6 6 6" /></svg>
    </button>
    <button class="lightbox-arrow lightbox-arrow--next" type="button" aria-label="Next screenshot">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg>
    </button>
    <span class="lightbox-counter" aria-live="polite"></span>`;
  if (slides.length < 2) {
    dialog.querySelectorAll(".lightbox-arrow, .lightbox-counter").forEach((el) => el.remove());
  }
  document.body.append(dialog);

  const image = dialog.querySelector("img");
  const counter = dialog.querySelector(".lightbox-counter");
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let index = 0;
  let preloaded = false;

  const show = (next, dir = 0) => {
    index = ((next % slides.length) + slides.length) % slides.length;
    image.src = slides[index].src;
    image.alt = slides[index].alt;
    if (counter) counter.textContent = `${index + 1} / ${slides.length}`;
    if (dir && !reduceMotion.matches) {
      image.animate(
        [
          { opacity: 0, transform: `translateX(${dir * 1.75}rem)` },
          { opacity: 1, transform: "translateX(0)" },
        ],
        { duration: 220, easing: "cubic-bezier(0.16, 1, 0.3, 1)" }
      );
    }
  };

  // Play the closing animation, then close; fall back to an immediate close if it never ends.
  const close = () => {
    if (!dialog.open || dialog.hasAttribute("data-closing")) return;
    if (reduceMotion.matches) return dialog.close();
    dialog.setAttribute("data-closing", "");
    const finish = () => {
      clearTimeout(timer);
      image.removeEventListener("animationend", finish);
      dialog.removeAttribute("data-closing");
      if (dialog.open) dialog.close();
    };
    const timer = setTimeout(finish, 400);
    image.addEventListener("animationend", finish);
  };

  triggers.forEach((trigger, i) =>
    trigger.addEventListener("click", () => {
      show(i);
      if (!preloaded) {
        preloaded = true;
        slides.forEach((slide) => (new Image().src = slide.src));
      }
      dialog.showModal();
    })
  );

  for (const [selector, step] of [[".lightbox-arrow--prev", -1], [".lightbox-arrow--next", 1]]) {
    dialog.querySelector(selector)?.addEventListener("click", (event) => {
      event.stopPropagation();
      show(index + step, step);
    });
  }

  document.addEventListener("keydown", (event) => {
    if (!dialog.open || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === "ArrowRight") {
      event.preventDefault();
      show(index + 1, 1);
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      show(index - 1, -1);
    }
  });

  dialog.addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    close();
  });
})();
