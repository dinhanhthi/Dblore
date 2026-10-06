function compareFeatureVersions(a, b) {
  const special = { Unreleased: 1, Unknown: 2 };
  const rank = (special[a] || 0) - (special[b] || 0);
  if (rank) return rank;
  if (special[a]) return 0;
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] || 0) - (right[i] || 0);
    if (difference) return difference;
  }
  return 0;
}

function sortFeatures(features, column = "id", direction = "descending") {
  return [...features].sort((a, b) => {
    let difference;
    if (column === "feature") {
      difference = a.feature.localeCompare(b.feature, "en", { sensitivity: "base" });
    } else if (column === "version") {
      difference = compareFeatureVersions(a.version, b.version);
    } else {
      difference = a.id - b.id;
    }
    return (direction === "descending" ? -difference : difference) || a.id - b.id;
  });
}

function normalizeFeatureSearch(text) {
  return text.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function isFeatureSubsequence(token, text) {
  let index = 0;
  for (const character of text) {
    if (character === token[index]) index++;
    if (index === token.length) return true;
  }
  return false;
}

function isFeatureTypo(token, word) {
  if (Math.abs(token.length - word.length) > 1) return false;
  let left = 0;
  let right = 0;
  let edits = 0;
  while (left < token.length && right < word.length) {
    if (token[left] === word[right]) {
      left++;
      right++;
    } else {
      if (++edits > 1) return false;
      if (token.length >= word.length) left++;
      if (word.length >= token.length) right++;
    }
  }
  return edits + (left < token.length || right < word.length ? 1 : 0) <= 1;
}

function filterFeatures(features, query) {
  const tokens = normalizeFeatureSearch(query).trim().split(/\s+/).filter(Boolean);
  if (!tokens.length) return features;
  return features.filter(({ feature }) => {
    const text = normalizeFeatureSearch(feature);
    const words = text.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    return tokens.every(token => text.includes(token) || words.some(word =>
      isFeatureSubsequence(token, word) || (token.length >= 3 && isFeatureTypo(token, word))
    ));
  });
}

function featureIssueURL(feature) {
  const params = new URLSearchParams({ template: "bug_report.md", title: `Bug: ${feature}` });
  return `https://github.com/dinhanhthi/Dblore/issues/new?${params}`;
}

if (typeof document !== "undefined") {
  const table = document.getElementById("features-table");
  if (table) {
    const body = table.querySelector("tbody");
    const search = document.getElementById("feature-search");
    const searchPanel = document.getElementById("feature-search-panel");
    const searchButton = document.getElementById("feature-search-button");
    const clearButton = document.getElementById("feature-search-clear");
    const count = document.getElementById("feature-count");
    let column = "id";
    let direction = "descending";

    const render = () => {
      const features = sortFeatures(filterFeatures(FEATURES, search.value), column, direction);
      const fragment = document.createDocumentFragment();
      for (const entry of features) {
        const row = document.createElement("tr");
        const id = document.createElement("td");
        id.textContent = entry.id;
        const feature = document.createElement("td");
        const content = document.createElement("div");
        content.className = "feature-cell";
        const text = document.createElement("span");
        text.textContent = entry.feature;
        const bug = document.createElement("a");
        bug.className = "feature-bug";
        bug.href = featureIssueURL(entry.feature);
        bug.target = "_blank";
        bug.rel = "noopener noreferrer";
        bug.textContent = "Find a bug";
        bug.setAttribute("aria-label", `Find a bug: ${entry.feature}`);
        content.append(text, bug);
        feature.append(content);
        const version = document.createElement("td");
        version.textContent = entry.version;
        row.append(id, feature, version);
        fragment.append(row);
      }
      if (!features.length) {
        const row = document.createElement("tr");
        const empty = document.createElement("td");
        empty.colSpan = 3;
        empty.className = "feature-empty";
        empty.textContent = "No matching features. Try another search or clear the search.";
        row.append(empty);
        fragment.append(row);
      }
      body.replaceChildren(fragment);
      count.textContent = search.value.trim()
        ? `${features.length} of ${FEATURES.length} features`
        : `${FEATURES.length} features`;
      clearButton.disabled = !search.value;
      for (const header of table.querySelectorAll("th")) {
        const button = header.querySelector("button");
        const active = button.dataset.sort === column;
        header.setAttribute("aria-sort", active ? direction : "none");
        button.querySelector("span").textContent = active ? (direction === "ascending" ? "↑" : "↓") : "↕";
        button.setAttribute("aria-label", `Sort by ${button.dataset.sort === "id" ? "ID" : button.dataset.sort}, ${active && direction === "ascending" ? "descending" : "ascending"}`);
      }
    };

    for (const button of table.querySelectorAll("th button")) {
      button.addEventListener("click", () => {
        direction = column === button.dataset.sort && direction === "ascending" ? "descending" : "ascending";
        column = button.dataset.sort;
        render();
      });
    }
    searchButton.addEventListener("click", () => {
      searchPanel.hidden = false;
      searchButton.setAttribute("aria-expanded", "true");
      search.focus();
    });
    search.addEventListener("input", render);
    clearButton.addEventListener("click", () => {
      search.value = "";
      render();
      search.focus();
    });
    search.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        search.value = "";
        render();
        searchPanel.hidden = true;
        searchButton.setAttribute("aria-expanded", "false");
        searchButton.focus();
      }
    });
    document.getElementById("feature-controls").hidden = false;
    document.getElementById("feature-table-wrap").hidden = false;
    render();
  }
}
