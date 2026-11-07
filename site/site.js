(function () {
  var root = document.documentElement;
  var themeApi = window.glassforce;

  var HERO_MEDIA = [
    { kind: "video", src: "demo.mp4" },
    { kind: "image", src: "demo.gif" },
    { kind: "stills" }
  ];

  function choice() {
    var value = root.dataset.themeChoice;
    if (value === "light" || value === "dark") return value;
    return "unset";
  }

  function resolvedTheme() {
    return root.dataset.theme === "dark" ? "dark" : "light";
  }

  function syncToggle() {
    var button = document.querySelector("[data-theme-toggle]");
    if (!button) return;
    var nextLabel = resolvedTheme() === "dark" ? "Use light theme" : "Use dark theme";
    button.setAttribute("aria-label", nextLabel);
  }

  function persist(next) {
    if (!themeApi) return;
    try {
      localStorage.setItem(themeApi.key, next);
    } catch {}
    themeApi.apply(next);
    syncToggle();
  }

  var toggle = document.querySelector("[data-theme-toggle]");
  if (toggle) {
    toggle.addEventListener("click", function () {
      persist(resolvedTheme() === "dark" ? "light" : "dark");
    });
  }

  var scheme = window.matchMedia("(prefers-color-scheme: dark)");
  scheme.addEventListener("change", function () {
    if (choice() === "unset" && themeApi) {
      themeApi.apply("unset");
      syncToggle();
    }
  });

  syncToggle();

  function contentType(res) {
    return (res.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  }

  function accepts(item, res) {
    if (!res.ok) return false;
    var type = contentType(res);
    if (type.indexOf("text/html") === 0) return false;
    if (item.kind === "video") {
      return type === "" || type.indexOf("video/") === 0 || type === "application/octet-stream";
    }
    if (item.kind === "image") {
      return type === "" || type.indexOf("image/") === 0;
    }
    return false;
  }

  function probe(item) {
    return fetch(item.src, { method: "HEAD" }).then(function (res) {
      if (res.status === 405 || res.status === 501) {
        return fetch(item.src, { method: "GET" }).then(function (getRes) {
          return accepts(item, getRes);
        }, function () {
          return false;
        });
      }
      return accepts(item, res);
    }, function () {
      return false;
    });
  }

  function selectHero(list, reduceMotion) {
    var index = 0;
    function step() {
      if (index >= list.length) return Promise.resolve({ kind: "stills" });
      var item = list[index];
      index += 1;
      if (item.kind === "stills") return Promise.resolve(item);
      if (reduceMotion) return step();
      return probe(item).then(function (ok) {
        return ok ? item : step();
      });
    }
    return step();
  }

  function showHero(item) {
    var frame = document.querySelector("[data-hero]");
    if (!frame) return;
    frame.dataset.heroMode = item.kind;
    frame.dataset.heroSettled = "true";
    if (item.kind === "stills") return;

    var media;
    if (item.kind === "video") {
      media = document.createElement("video");
      media.muted = true;
      media.defaultMuted = true;
      media.loop = true;
      media.autoplay = true;
      media.playsInline = true;
      media.setAttribute("playsinline", "");
      media.setAttribute("aria-label", "Glassforce demo");
      media.src = item.src;
    } else {
      media = document.createElement("img");
      media.alt = "Glassforce demo";
      media.src = item.src;
    }
    media.className = "demo";
    frame.classList.add("is-file");
    frame.appendChild(media);
    if (item.kind === "video") {
      var played = media.play();
      if (played && typeof played.catch === "function") {
        played.catch(function () {
          media.controls = true;
        });
      }
    }
  }

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  selectHero(HERO_MEDIA, reduceMotion).then(showHero);
})();
