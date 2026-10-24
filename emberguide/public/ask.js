(() => {
  const status = document.querySelector("[data-ask-status]");
  const form = document.querySelector("[data-ask-form]");
  const log = document.querySelector("[data-ask-log]");
  const input = form?.querySelector("textarea");
  const webToggle = form?.querySelector("[data-ask-web-toggle]");
  const suggestionSelect = document.querySelector("[data-ask-suggestion-select]");
  const testButton = document.querySelector("[data-spark-test]");
  const checkResult = document.querySelector("[data-spark-check]");
  const historyList = document.querySelector("[data-ask-history-list]");
  const historyStatus = document.querySelector("[data-ask-history-status]");
  const historySummary = document.querySelector("[data-ask-history-summary]");
  const conversationTitle = document.querySelector("[data-ask-conversation-title]");
  const historyRefresh = document.querySelector("[data-ask-history-refresh]");
  let conversationId = null;
  let historyBusy = false;
  let remotePending = false;
  const STATUS_INTERVAL_MS = 30000;

  const timeLabel = (date) => date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

  const setStatus = (text, kind) => {
    if (!status) return;
    status.textContent = text;
    status.dataset.state = kind;
    status.title = `Checked at ${timeLabel(new Date())}`;
  };

  const showStatus = ({ enabled, online }) => {
    if (!enabled) setStatus("Not set up", "off");
    else if (online) setStatus("Online", "on");
    else setStatus("Offline", "off");
  };

  const fetchStatus = async (check = false) => {
    const response = await fetch(`/api/ai/status${check ? "?check=1" : ""}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  };

  // Answers can take a while on a busy GPU, so skip polling mid-question.
  // The first check always runs so a page opened in a background tab isn't
  // stuck on "Checking Spark…".
  const refreshStatus = (force = false) => {
    if (!force && (document.hidden || form?.dataset.busy)) return;
    fetchStatus()
      .then(showStatus)
      .catch(() => setStatus("Status unknown", "off"));
  };

  refreshStatus(true);
  setInterval(refreshStatus, STATUS_INTERVAL_MS);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refreshStatus();
  });

  testButton?.addEventListener("click", async () => {
    testButton.disabled = true;
    checkResult.textContent = "Testing…";
    try {
      const result = await fetchStatus(true);
      showStatus(result);
      const time = timeLabel(new Date());
      if (!result.online) {
        checkResult.textContent = `Couldn't reach the server at ${time}. Make sure the PC is on and llama-server is running.`;
      } else if (result.key_accepted === false) {
        checkResult.textContent = "The server is up, but it rejected the API key.";
      } else if (result.model_available === false) {
        checkResult.textContent = `The server is up, but the chosen model isn't installed anymore. Pick another model below.`;
      } else {
        const model = result.model ? ` Using ${result.model}${result.automatic ? " (automatic)" : ""}.` : "";
        checkResult.textContent = `Connected at ${time}. Spark is ready.${model}`;
      }
    } catch (error) {
      checkResult.textContent = `Status check failed (${error.message}).`;
    } finally {
      testButton.disabled = false;
    }
  });

  if (!form || !log || !input) return;

  // Renders the small Markdown subset models use (bold, italics, code, headings,
  // lists) with DOM nodes only, so model output can never inject HTML.
  const inlineSymbols = new Map([
    ["\\rightarrow", "\u2192"],
    ["\\to", "\u2192"],
    ["\\leftarrow", "\u2190"],
    ["\\leftrightarrow", "\u2194"],
  ]);
  const appendPlainText = (parent, text) => {
    parent.append(text.replace(/\$([^$\n]+)\$|\\\(([^)\n]+)\\\)/g, (original, dollar, parentheses) =>
      inlineSymbols.get((dollar ?? parentheses).trim()) ?? original));
  };

  const appendInline = (parent, text) => {
    const pattern = /(\*\*|__)(.+?)\1|(\*|_)(?=\S)(.+?)(?<=\S)\3(?![\w*])|`([^`]+)`/g;
    let last = 0;
    for (const match of text.matchAll(pattern)) {
      if (match.index > last) appendPlainText(parent, text.slice(last, match.index));
      let node;
      if (match[2] !== undefined) {
        node = document.createElement("strong");
        appendInline(node, match[2]);
      } else if (match[4] !== undefined) {
        node = document.createElement("em");
        appendInline(node, match[4]);
      } else {
        node = document.createElement("code");
        node.textContent = match[5];
      }
      parent.append(node);
      last = match.index + match[0].length;
    }
    if (last < text.length) appendPlainText(parent, text.slice(last));
  };

  const renderMarkdown = (container, markdown) => {
    container.replaceChildren();
    container.classList.add("ask-markdown");
    let list = null;
    let paragraph = null;
    const closeBlocks = () => {
      list = null;
      paragraph = null;
    };

    markdown.replace(/\r\n?/g, "\n").split("\n").forEach((rawLine) => {
      const line = rawLine.trimEnd();
      if (!line.trim()) return closeBlocks();

      const heading = line.match(/^\s*#{1,6}\s+(.*)$/);
      const bullet = line.match(/^(\s*)[*+-]\s+(.*)$/);
      const numbered = line.match(/^(\s*)\d+[.)]\s+(.*)$/);
      if (heading) {
        closeBlocks();
        const element = document.createElement("p");
        element.className = "ask-heading";
        appendInline(element, heading[1].replace(/\*\*/g, ""));
        container.append(element);
      } else if (bullet || numbered) {
        const [, indent, text] = bullet || numbered;
        const tag = bullet ? "UL" : "OL";
        if (!list || list.tagName !== tag) {
          paragraph = null;
          list = document.createElement(tag);
          container.append(list);
        }
        const item = document.createElement("li");
        if (indent.length >= 2) item.className = "is-nested";
        appendInline(item, text);
        list.append(item);
      } else if (/^\s*([-*_])\s*\1\s*\1[\s\1]*$/.test(line)) {
        closeBlocks();
      } else if (paragraph) {
        paragraph.append(document.createElement("br"));
        appendInline(paragraph, line.trim());
      } else {
        list = null;
        paragraph = document.createElement("p");
        appendInline(paragraph, line.trim());
        container.append(paragraph);
      }
    });
  };

  const isFollowing = () => log.scrollHeight - log.scrollTop - log.clientHeight <= 80;
  const scrollToLatest = () => { log.scrollTop = log.scrollHeight; };

  const addBubble = (role, text) => {
    const bubble = document.createElement("div");
    bubble.className = `ask-message ask-message-${role}`;
    bubble.textContent = text;
    log.append(bubble);
    scrollToLatest();
    return bubble;
  };

  const appendSources = (bubble, query, sources) => {
    if (!sources.length) return;
    const following = isFollowing();
    const section = document.createElement("section");
    section.className = "ask-sources";
    section.setAttribute("aria-label", "Web sources");
    const label = document.createElement("strong");
    label.textContent = "Web sources";
    const topic = document.createElement("p");
    topic.textContent = `Spark searched the web for: ${query}`;
    const list = document.createElement("ol");
    sources.forEach((source) => {
      let url;
      try {
        url = new URL(source.url);
      } catch {
        return;
      }
      if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) return;
      const item = document.createElement("li");
      item.value = source.id;
      const link = document.createElement("a");
      link.href = url.href;
      link.textContent = source.title;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      item.append(link);
      list.append(item);
    });
    section.append(label, topic, list);
    bubble.append(section);
    if (following) scrollToLatest();
  };

  const setConversation = (id, title = "New conversation") => {
    conversationId = id;
    conversationTitle.textContent = title;
    const url = new URL(window.location.href);
    url.searchParams.set("conversation", id || "new");
    window.history.replaceState(null, "", url);
    historyList.querySelectorAll("[data-conversation-id]").forEach((button) => {
      button.setAttribute("aria-current", String(button.dataset.conversationId === id));
    });
  };

  const updateControls = () => {
    const busy = Boolean(form.dataset.busy) || historyBusy;
    form.querySelector(".ask-send").disabled = busy || remotePending;
    form.querySelector("[data-ask-clear]").disabled = busy;
    if (webToggle) webToggle.disabled = busy;
    if (suggestionSelect) suggestionSelect.disabled = busy || remotePending;
    document.querySelectorAll(".ask-suggestion, [data-ask-history] button").forEach((button) => {
      button.disabled = busy;
    });
  };

  const historyJson = async (url, options = {}) => {
    const response = await fetch(url, { cache: "no-store", ...options });
    if (!response.headers.get("Content-Type")?.includes("application/json")) {
      throw new Error("The conversation service is unavailable. Restart EmberGuide and refresh this page.");
    }
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || `Conversation request failed (HTTP ${response.status}).`);
    return result;
  };

  const openConversation = async (id) => {
    const conversation = await historyJson(`/api/ai/conversations/${encodeURIComponent(id)}`);
    setConversation(conversation.id, conversation.title);
    log.replaceChildren();
    conversation.turns.forEach((turn) => {
      addBubble("user", turn.question);
      const bubble = addBubble("assistant", "");
      if (turn.answer) renderMarkdown(bubble, turn.answer);
      if (turn.status === "pending") {
        bubble.textContent = "Spark is still answering. Refresh conversations to check for the reply.";
      } else if (turn.error) {
        const error = document.createElement("p");
        error.textContent = turn.error;
        bubble.append(error);
        bubble.classList.add("is-error");
      }
      if (turn.search) appendSources(bubble, turn.search.query, turn.search.sources);
    });
    remotePending = conversation.turns.some((turn) => turn.status === "pending");
    historyStatus.textContent = remotePending ? "This conversation has an answer in progress. Refresh conversations when it finishes, or start a new conversation." : conversation.title_error || "";
    input.value = "";
    if (webToggle) webToggle.checked = false;
    scrollToLatest();
  };

  const withHistoryAction = async (action) => {
    if (form.dataset.busy || historyBusy) return;
    historyBusy = true;
    historyStatus.textContent = "";
    updateControls();
    try {
      await action();
    } catch (error) {
      historyStatus.textContent = `Previous conversations: ${error.message}`;
    } finally {
      historyBusy = false;
      updateControls();
    }
  };

  const resetConversation = () => {
    setConversation(null);
    remotePending = false;
    log.replaceChildren();
    input.value = "";
    if (webToggle) webToggle.checked = false;
    historyStatus.textContent = "";
    updateControls();
  };

  const sizeHistoryList = () => {
    const rows = historyList.querySelectorAll(".ask-history-row");
    if (rows.length <= 3) {
      historyList.style.removeProperty("max-height");
      return;
    }
    const first = rows[0].getBoundingClientRect();
    const third = rows[2].getBoundingClientRect();
    if (third.height > 0) historyList.style.maxHeight = `${third.bottom - first.top}px`;
  };
  const historyResizeObserver = new ResizeObserver(sizeHistoryList);

  const refreshHistory = async () => {
    const result = await historyJson("/api/ai/conversations");
    historyResizeObserver.disconnect();
    historyList.replaceChildren();
    historyList.style.removeProperty("max-height");
    historySummary.textContent = `Previous Conversations (${result.conversations.length})`;
    if (!result.conversations.length) {
      const empty = document.createElement("p");
      empty.className = "ask-footnote";
      empty.textContent = "No saved conversations yet.";
      historyList.append(empty);
    }
    result.conversations.forEach((conversation) => {
      const row = document.createElement("div");
      row.className = "ask-history-row";
      const open = document.createElement("button");
      open.type = "button";
      open.className = "ask-clear ask-history-open";
      open.textContent = conversation.title;
      open.dataset.conversationId = conversation.id;
      open.setAttribute("aria-current", String(conversation.id === conversationId));
      const date = document.createElement("time");
      date.dateTime = conversation.updated_at;
      date.textContent = new Date(conversation.updated_at).toLocaleString();
      open.append(date);
      open.addEventListener("click", () => withHistoryAction(() => openConversation(conversation.id)));
      const rename = document.createElement("button");
      rename.type = "button";
      rename.className = "ask-clear ask-history-action";
      rename.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m15 5 4 4M4 20l5-1L20 8a2.8 2.8 0 0 0-4-4L5 15Z"/></svg>';
      rename.title = "Rename conversation";
      rename.setAttribute("aria-label", `Rename ${conversation.title}`);
      rename.addEventListener("click", () => {
        const title = window.prompt("Conversation title", conversation.title);
        if (title === null) return;
        withHistoryAction(async () => {
          const saved = await historyJson(`/api/ai/conversations/${conversation.id}`, {
            method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title }),
          });
          if (conversation.id === conversationId) setConversation(saved.id, saved.title);
          await refreshHistory();
        });
      });
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "ask-clear ask-history-action";
      remove.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 10v7m4-7v7"/></svg>';
      remove.title = "Delete conversation";
      remove.setAttribute("aria-label", `Delete ${conversation.title}`);
      remove.addEventListener("click", () => {
        if (!window.confirm(`Delete "${conversation.title}"? Copies in existing backups will remain.`)) return;
        withHistoryAction(async () => {
          await historyJson(`/api/ai/conversations/${conversation.id}/delete`, {
            method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
          });
          if (conversation.id === conversationId) resetConversation();
          await refreshHistory();
        });
      });
      row.append(open, rename, remove);
      historyList.append(row);
    });
    sizeHistoryList();
    historyList.querySelectorAll(".ask-history-row").forEach((row, index) => {
      if (index < 3) historyResizeObserver.observe(row);
    });
    return result.conversations;
  };

  const showProgress = (bubble) => {
    const label = document.createElement("span");
    label.className = "ask-progress-label";
    const bar = document.createElement("span");
    bar.className = "ask-progress-bar is-indeterminate";
    const fill = document.createElement("span");
    bar.append(fill);
    bubble.replaceChildren(label, bar);
    const started = Date.now();
    let stage = "connecting";
    let detail = "";

    const paint = () => {
      const following = isFollowing();
      const seconds = Math.round((Date.now() - started) / 1000);
      const elapsed = seconds >= 3 ? ` · ${seconds}s` : "";
      if (stage === "connecting") label.textContent = `Waking up Spark…${elapsed}`;
      else if (stage === "preparing_search") label.textContent = `Finding study material locally…${elapsed}`;
      else if (stage === "retrying_search") label.textContent = `${detail}…${elapsed}`;
      else if (stage === "searching") label.textContent = `Searching the web…${elapsed}`;
      else if (stage === "reading") label.textContent = `Reading your class notes… ${detail}`;
      else label.textContent = `Writing an answer…${elapsed}`;
      if (following) scrollToLatest();
    };
    const timer = setInterval(paint, 1000);
    paint();

    return {
      preparingSearch() {
        stage = "preparing_search";
        paint();
      },
      searching() {
        stage = "searching";
        paint();
      },
      retryingSearch(message) {
        stage = "retrying_search";
        detail = message;
        paint();
      },
      connecting() {
        stage = "connecting";
        paint();
      },
      update({ total, cache = 0, processed, time_ms: timeMs }) {
        if (!total) return;
        const fraction = Math.min(processed / total, 1);
        if (fraction >= 1) {
          stage = "writing";
          bar.classList.add("is-indeterminate");
          fill.style.width = "";
        } else {
          stage = "reading";
          bar.classList.remove("is-indeterminate");
          fill.style.width = `${Math.round(fraction * 100)}%`;
          // Cached tokens come back instantly, so only fresh tokens set the pace.
          const fresh = processed - cache;
          const remainingMs = fresh > 0 && timeMs > 300 ? ((total - processed) * timeMs) / fresh : null;
          detail = `${Math.round(fraction * 100)}%`;
          if (remainingMs !== null) {
            const left = Math.max(1, Math.round(remainingMs / 1000));
            detail += left >= 60 ? ` · about ${Math.round(left / 60)} min left` : ` · about ${left}s left`;
          }
        }
        paint();
      },
      stop() {
        clearInterval(timer);
      },
    };
  };

  const readStream = async (response, onEvent) => {
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) onEvent(JSON.parse(line));
      }
      if (done) break;
    }
  };

  const ask = async (question) => {
    question = question.trim();
    if (!question || form.dataset.busy || historyBusy || remotePending) return;
    const useWeb = webToggle?.checked === true;
    let query = "";

    form.dataset.busy = "true";
    historyStatus.textContent = "";
    updateControls();
    addBubble("user", question);
    input.value = "";
    const pending = addBubble("assistant", "");
    pending.classList.add("is-pending");
    const progress = showProgress(pending);
    let answer = "";
    let sources = [];
    let paintTimer = 0;
    const PAINT_INTERVAL_MS = 120;

    // Hides a half-written trailing marker ("**Ma", a lone "-") until it's
    // complete, so text doesn't flip between raw and formatted as it streams.
    const settledMarkdown = (text) => {
      const lines = text.split("\n");
      let last = lines.pop();
      if ((last.match(/\*\*/g) || []).length % 2) last = last.slice(0, last.lastIndexOf("**"));
      if ((last.match(/`/g) || []).length % 2) last = last.slice(0, last.lastIndexOf("`"));
      last = last.replace(/(^|[^*])\*$/, "$1");
      if (/^\s*([-*+]|\d+\.?|#{1,6}|-{2,3})\s*$/.test(last)) last = "";
      return [...lines, last].join("\n");
    };

    const paintAnswer = (final = false) => {
      clearTimeout(paintTimer);
      paintTimer = 0;
      // Only follow the answer if the reader hasn't scrolled up to reread.
      const following = isFollowing();
      renderMarkdown(pending, final ? answer : settledMarkdown(answer));
      if (following) scrollToLatest();
    };

    try {
      const response = await fetch("/ai/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
        body: JSON.stringify({ question, conversation_id: conversationId, web_search: useWeb }),
      });
      if (!response.ok || !response.headers.get("Content-Type")?.includes("ndjson")) {
        const result = await response.json().catch(() => ({}));
        if (result.conversation_id) {
          setConversation(result.conversation_id, result.title);
        }
        throw new Error(result.error || "Spark didn't answer.");
      }

      let finished = false;
      await readStream(response, (event) => {
        if (event.type === "conversation") {
          setConversation(event.conversation_id, event.title);
        } else if (event.type === "preparing_search") {
          progress.preparingSearch();
        } else if (event.type === "retrying_search") {
          progress.retryingSearch(event.message);
        } else if (event.type === "searching") {
          progress.searching();
        } else if (event.type === "sources") {
          sources = event.sources;
          query = event.query;
          progress.connecting();
        } else if (event.type === "progress") {
          if (!answer) progress.update(event);
        } else if (event.type === "token") {
          if (!answer) {
            progress.stop();
            pending.classList.remove("is-pending");
            pending.classList.add("is-streaming");
          }
          answer += event.text;
          paintTimer ||= setTimeout(paintAnswer, PAINT_INTERVAL_MS);
        } else if (event.type === "naming") {
          historyStatus.textContent = "Saving a short conversation subject...";
        } else if (event.type === "done") {
          answer = event.answer;
          if (event.conversation_id) setConversation(event.conversation_id, event.title);
          historyStatus.textContent = event.title_error || "";
          finished = true;
        } else if (event.type === "error") {
          throw new Error(event.error);
        }
      });
      if (!finished) throw new Error("Spark stopped before finishing. Try asking again.");

      paintAnswer(true);
      appendSources(pending, query, sources);
      setStatus("Online", "on");
    } catch (error) {
      clearTimeout(paintTimer);
      const following = isFollowing();
      pending.classList.remove("ask-markdown");
      pending.textContent = error.message;
      pending.classList.add("is-error");
      if (following) scrollToLatest();
      appendSources(pending, query, sources);
      input.value = question;
      if (/offline/i.test(error.message)) setStatus("Offline", "off");
    } finally {
      progress.stop();
      pending.classList.remove("is-pending", "is-streaming");
      try {
        await refreshHistory();
      } catch (error) {
        historyStatus.textContent = `Conversation history couldn't be refreshed: ${error.message}`;
      }
      delete form.dataset.busy;
      updateControls();
      input.focus({ preventScroll: true });
    }
  };

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    ask(input.value);
  });

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      ask(input.value);
    }
  });

  document.querySelectorAll(".ask-suggestion").forEach((button) => {
    button.addEventListener("click", () => ask(button.textContent));
  });

  suggestionSelect?.addEventListener("change", () => {
    const question = suggestionSelect.value;
    suggestionSelect.value = "";
    ask(question);
  });

  document.querySelector("[data-ask-clear]")?.addEventListener("click", () => {
    if (form.dataset.busy || historyBusy) return;
    resetConversation();
    input.focus();
  });

  const restoreHistory = () => withHistoryAction(async () => {
    await refreshHistory();
    const requested = new URL(window.location.href).searchParams.get("conversation");
    if (requested && requested !== "new") await openConversation(requested);
  });
  historyRefresh.addEventListener("click", restoreHistory);
  restoreHistory();
})();
