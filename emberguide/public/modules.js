(() => {
  const filter = document.querySelector("[data-module-course-filter]");
  filter?.addEventListener("change", () => {
    document.querySelectorAll("[data-module-course]").forEach((course) => {
      course.hidden = Boolean(filter.value) && course.dataset.moduleCourse !== filter.value;
    });
  });

  document.querySelectorAll("[data-module-expand]").forEach((button) => {
    button.addEventListener("click", () => {
      const open = button.dataset.moduleExpand === "true";
      const selector = open ? "details:not(.module-item-details)" : "details";
      document.querySelectorAll(`[data-module-course]:not([hidden]) ${selector}`).forEach((details) => {
        details.open = open;
      });
    });
  });

  // Items outside this week load their instructions from Canvas on first open.
  document.querySelectorAll("details[data-module-content-url]").forEach((details) => {
    details.addEventListener("toggle", async () => {
      if (!details.open || details.dataset.moduleContentState) return;
      details.dataset.moduleContentState = "loading";
      const placeholder = details.querySelector(".module-content");
      try {
        const response = await fetch(details.dataset.moduleContentUrl, { headers: { Accept: "text/html" } });
        if (!response.ok) throw new Error(String(response.status));
        placeholder.outerHTML = await response.text();
        details.dataset.moduleContentState = "loaded";
      } catch {
        delete details.dataset.moduleContentState;
        placeholder.querySelector("[data-module-content-status]").textContent =
          "Couldn't load this from Canvas. Close and reopen to try again, or open it in Canvas.";
      }
    });
  });

  const revealLinkedModule = () => {
    const target = document.getElementById(location.hash.slice(1));
    if (!target?.classList.contains("module-card")) return;
    if (filter) {
      filter.value = "";
      filter.dispatchEvent(new Event("change"));
    }
    target.querySelector(".module-items-toggle").open = true;
    target.scrollIntoView({ block: "start" });
  };
  // Clicking a link to the hash already in the URL fires no hashchange event.
  document.querySelectorAll(".module-week-title").forEach((link) => {
    link.addEventListener("click", () => {
      if (link.hash === location.hash) revealLinkedModule();
    });
  });
  window.addEventListener("hashchange", revealLinkedModule);
  revealLinkedModule();
})();
