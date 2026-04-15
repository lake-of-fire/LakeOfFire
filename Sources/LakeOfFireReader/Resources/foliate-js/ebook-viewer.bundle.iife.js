var ManabiEbookViewerBundle = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __esm = (fn2, res) => function __init() {
    return fn2 && (res = (0, fn2[__getOwnPropNames(fn2)[0]])(fn2 = 0)), res;
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };

  // epubcfi.js
  var epubcfi_exports = {};
  __export(epubcfi_exports, {
    collapse: () => collapse,
    compare: () => compare,
    fake: () => fake,
    fromCalibreHighlight: () => fromCalibreHighlight,
    fromCalibrePos: () => fromCalibrePos,
    fromElements: () => fromElements,
    fromRange: () => fromRange,
    isCFI: () => isCFI,
    joinIndir: () => joinIndir,
    parse: () => parse,
    toElement: () => toElement,
    toRange: () => toRange
  });
  var findIndices, splitAt, concatArrays, isNumber, isCFI, escapeCFI, wrap, unwrap, lift, joinIndir, tokenizer, findTokens, parser, parserIndir, parse, partToString, toInnerString, toString, collapse, buildRange, compare, isTextNode, isElementNode, indexChildNodes, getNodeByIndex, partsToNode, nodeToParts, fromRange, toRange, fromElements, toElement, fake, fromCalibrePos, fromCalibreHighlight;
  var init_epubcfi = __esm({
    "epubcfi.js"() {
      findIndices = (arr, f2) => arr.map((x2, i2, a2) => f2(x2, i2, a2) ? i2 : null).filter((x2) => x2 != null);
      splitAt = (arr, is) => [-1, ...is, arr.length].reduce(({ xs, a: a2 }, b2) => ({ xs: xs?.concat([arr.slice(a2 + 1, b2)]) ?? [], a: b2 }), {}).xs;
      concatArrays = (a2, b2) => a2.slice(0, -1).concat([a2[a2.length - 1].concat(b2[0])]).concat(b2.slice(1));
      isNumber = /\d/;
      isCFI = /^epubcfi\((.*)\)$/;
      escapeCFI = (str) => str.replace(/[\^[\](),;=]/g, "^$&");
      wrap = (x2) => isCFI.test(x2) ? x2 : `epubcfi(${x2})`;
      unwrap = (x2) => x2.match(isCFI)?.[1] ?? x2;
      lift = (f2) => (...xs) => `epubcfi(${f2(...xs.map((x2) => x2.match(isCFI)?.[1] ?? x2))})`;
      joinIndir = lift((...xs) => xs.join("!"));
      tokenizer = (str) => {
        const tokens = [];
        let state, escape, value = "";
        const push = (x2) => (tokens.push(x2), state = null, value = "");
        const cat = (x2) => (value += x2, escape = false);
        for (const char of Array.from(str.trim()).concat("")) {
          if (char === "^" && !escape) {
            escape = true;
            continue;
          }
          if (state === "!") push(["!"]);
          else if (state === ",") push([","]);
          else if (state === "/" || state === ":") {
            if (isNumber.test(char)) {
              cat(char);
              continue;
            } else push([state, parseInt(value)]);
          } else if (state === "~") {
            if (isNumber.test(char) || char === ".") {
              cat(char);
              continue;
            } else push(["~", parseFloat(value)]);
          } else if (state === "@") {
            if (char === ":") {
              push(["@", parseFloat(value)]);
              state = "@";
              continue;
            }
            if (isNumber.test(char) || char === ".") {
              cat(char);
              continue;
            } else push(["@", parseFloat(value)]);
          } else if (state === "[") {
            if (char === ";" && !escape) {
              push(["[", value]);
              state = ";";
            } else if (char === "," && !escape) {
              push(["[", value]);
              state = "[";
            } else if (char === "]" && !escape) push(["[", value]);
            else cat(char);
            continue;
          } else if (state?.startsWith(";")) {
            if (char === "=" && !escape) {
              state = `;${value}`;
              value = "";
            } else if (char === ";" && !escape) {
              push([state, value]);
              state = ";";
            } else if (char === "]" && !escape) push([state, value]);
            else cat(char);
            continue;
          }
          if (char === "/" || char === ":" || char === "~" || char === "@" || char === "[" || char === "!" || char === ",") state = char;
        }
        return tokens;
      };
      findTokens = (tokens, x2) => findIndices(tokens, ([t2]) => t2 === x2);
      parser = (tokens) => {
        const parts = [];
        let state;
        for (const [type, val] of tokens) {
          if (type === "/") parts.push({ index: val });
          else {
            const last = parts[parts.length - 1];
            if (type === ":") last.offset = val;
            else if (type === "~") last.temporal = val;
            else if (type === "@") last.spatial = (last.spatial ?? []).concat(val);
            else if (type === ";s") last.side = val;
            else if (type === "[") {
              if (state === "/" && val) last.id = val;
              else {
                last.text = (last.text ?? []).concat(val);
                continue;
              }
            }
          }
          state = type;
        }
        return parts;
      };
      parserIndir = (tokens) => splitAt(tokens, findTokens(tokens, "!")).map(parser);
      parse = (cfi) => {
        const tokens = tokenizer(unwrap(cfi));
        const commas = findTokens(tokens, ",");
        if (!commas.length) return parserIndir(tokens);
        const [parent, start, end] = splitAt(tokens, commas).map(parserIndir);
        return { parent, start, end };
      };
      partToString = ({ index, id, offset, temporal, spatial, text, side }) => {
        const param = side ? `;s=${side}` : "";
        return `/${index}` + (id ? `[${escapeCFI(id)}${param}]` : "") + (offset != null && index % 2 ? `:${offset}` : "") + (temporal ? `~${temporal}` : "") + (spatial ? `@${spatial.join(":")}` : "") + (text || !id && side ? "[" + (text?.map(escapeCFI)?.join(",") ?? "") + param + "]" : "");
      };
      toInnerString = (parsed) => parsed.parent ? [parsed.parent, parsed.start, parsed.end].map(toInnerString).join(",") : parsed.map((parts) => parts.map(partToString).join("")).join("!");
      toString = (parsed) => wrap(toInnerString(parsed));
      collapse = (x2, toEnd) => typeof x2 === "string" ? toString(collapse(parse(x2), toEnd)) : x2.parent ? concatArrays(x2.parent, x2[toEnd ? "end" : "start"]) : x2;
      buildRange = (from, to) => {
        if (typeof from === "string") from = parse(from);
        if (typeof to === "string") to = parse(to);
        from = collapse(from);
        to = collapse(to, true);
        const localFrom = from[from.length - 1], localTo = to[to.length - 1];
        const localParent = [], localStart = [], localEnd = [];
        let pushToParent = true;
        const len = Math.max(localFrom.length, localTo.length);
        for (let i2 = 0; i2 < len; i2++) {
          const a2 = localFrom[i2], b2 = localTo[i2];
          pushToParent &&= a2?.index === b2?.index && !a2?.offset && !b2?.offset;
          if (pushToParent) localParent.push(a2);
          else {
            if (a2) localStart.push(a2);
            if (b2) localEnd.push(b2);
          }
        }
        const parent = from.slice(0, -1).concat([localParent]);
        return toString({ parent, start: [localStart], end: [localEnd] });
      };
      compare = (a2, b2) => {
        if (typeof a2 === "string") a2 = parse(a2);
        if (typeof b2 === "string") b2 = parse(b2);
        if (a2.start || b2.start) return compare(collapse(a2), collapse(b2)) || compare(collapse(a2, true), collapse(b2, true));
        for (let i2 = 0; i2 < Math.max(a2.length, b2.length); i2++) {
          const p2 = a2[i2] ?? [], q2 = b2[i2] ?? [];
          const maxIndex = Math.max(p2.length, q2.length) - 1;
          for (let i3 = 0; i3 <= maxIndex; i3++) {
            const x2 = p2[i3], y2 = q2[i3];
            if (!x2) return -1;
            if (!y2) return 1;
            if (x2.index > y2.index) return 1;
            if (x2.index < y2.index) return -1;
            if (i3 === maxIndex) {
              if (x2.offset > y2.offset) return 1;
              if (x2.offset < y2.offset) return -1;
            }
          }
        }
        return 0;
      };
      isTextNode = ({ nodeType }) => nodeType === 3 || nodeType === 4;
      isElementNode = ({ nodeType }) => nodeType === 1;
      indexChildNodes = (node) => {
        const nodes = Array.from(node.childNodes).filter((node2) => isTextNode(node2) || isElementNode(node2) && node2.localName?.toLowerCase() !== "reader-sentinel").reduce((arr, node2) => {
          let last = arr[arr.length - 1];
          if (!last) arr.push(node2);
          else if (isTextNode(node2)) {
            if (Array.isArray(last)) last.push(node2);
            else if (isTextNode(last)) arr[arr.length - 1] = [last, node2];
            else arr.push(node2);
          } else {
            if (isElementNode(last)) arr.push(null, node2);
            else arr.push(node2);
          }
          return arr;
        }, []);
        if (isElementNode(nodes[0])) nodes.unshift("first");
        if (isElementNode(nodes[nodes.length - 1])) nodes.push("last");
        nodes.unshift("before");
        nodes.push("after");
        return nodes;
      };
      getNodeByIndex = (node, index) => node ? indexChildNodes(node)[index] : null;
      partsToNode = (node, parts) => {
        const { id } = parts[parts.length - 1];
        if (id) {
          const el = node.ownerDocument.getElementById(id);
          if (el) return { node: el, offset: 0 };
        }
        for (const { index } of parts) {
          let currentIndex = index;
          let newNode = getNodeByIndex(node, currentIndex);
          while (Array.isArray(newNode) ? false : newNode?.nodeType === 1 && newNode.localName?.toLowerCase() === "reader-sentinel") {
            currentIndex++;
            newNode = getNodeByIndex(node, currentIndex);
          }
          if (newNode === "first") return { node: node.firstChild ?? node };
          if (newNode === "last") return { node: node.lastChild ?? node };
          if (newNode === "before") return { node, before: true };
          if (newNode === "after") return { node, after: true };
          node = newNode;
        }
        const { offset } = parts[parts.length - 1];
        if (!Array.isArray(node)) return { node, offset };
        let sum = 0;
        for (const n2 of node) {
          const { length } = n2.nodeValue;
          if (sum + length >= offset) return { node: n2, offset: offset - sum };
          sum += length;
        }
      };
      nodeToParts = (node, offset) => {
        if (node.nodeType === 1 && node.localName?.toLowerCase() === "reader-sentinel") {
          return nodeToParts(node.parentNode, offset);
        }
        const { parentNode, id } = node;
        const indexed = indexChildNodes(parentNode);
        const index = indexed.findIndex((x2) => Array.isArray(x2) ? x2.some((x3) => x3 === node) : x2 === node);
        const chunk = indexed[index];
        if (Array.isArray(chunk)) {
          let sum = 0;
          for (const x2 of chunk) {
            if (x2 === node) {
              sum += offset;
              break;
            } else sum += x2.nodeValue.length;
          }
          offset = sum;
        }
        const tagName = node.nodeType === 1 ? node.localName?.toLowerCase() : "";
        const part = { id, index, offset };
        if (part.id?.startsWith("manabi-") || tagName?.startsWith("manabi-") || tagName === "reader-sentinel") {
          delete part.id;
        }
        const result = parentNode !== node.ownerDocument.documentElement ? nodeToParts(parentNode).concat(part) : [part];
        return result;
      };
      fromRange = (range) => {
        const { startContainer, startOffset, endContainer, endOffset } = range;
        const start = nodeToParts(startContainer, startOffset);
        if (range.collapsed) return toString([start]);
        const end = nodeToParts(endContainer, endOffset);
        return buildRange([start], [end]);
      };
      toRange = (doc, parts) => {
        const startParts = collapse(parts);
        const endParts = collapse(parts, true);
        const root = doc.documentElement;
        const start = partsToNode(root, startParts[0]);
        const end = partsToNode(root, endParts[0]);
        const range = doc.createRange();
        if (start.before) range.setStartBefore(start.node);
        else if (start.after) range.setStartAfter(start.node);
        else range.setStart(start.node, start.offset);
        if (end.before) range.setEndBefore(end.node);
        else if (end.after) range.setEndAfter(end.node);
        else range.setEnd(end.node, end.offset);
        return range;
      };
      fromElements = (elements) => {
        const results = [];
        const { parentNode } = elements[0];
        const parts = nodeToParts(parentNode);
        for (const [index, node] of indexChildNodes(parentNode).entries()) {
          const el = elements[results.length];
          if (node === el)
            results.push(toString([parts.concat({ id: el.id, index })]));
        }
        return results;
      };
      toElement = (doc, parts) => partsToNode(doc.documentElement, collapse(parts)).node;
      fake = {
        fromIndex: (index) => `/6/${(index + 1) * 2}`,
        toIndex: (parts) => parts?.at(-1).index / 2 - 1
      };
      fromCalibrePos = (pos) => {
        const [parts] = parse(pos);
        const item = parts.shift();
        parts.shift();
        return toString([[{ index: 6 }, item], parts]);
      };
      fromCalibreHighlight = ({ spine_index, start_cfi, end_cfi }) => {
        const pre = fake.fromIndex(spine_index) + "!";
        return buildRange(pre + start_cfi.slice(2), pre + end_cfi.slice(2));
      };
    }
  });

  // search.js
  var search_exports = {};
  __export(search_exports, {
    search: () => search,
    searchMatcher: () => searchMatcher
  });
  var CONTEXT_LENGTH, normalizeWhitespace, makeExcerpt, simpleSearch, segmenterSearch, search, searchMatcher;
  var init_search = __esm({
    "search.js"() {
      CONTEXT_LENGTH = 50;
      normalizeWhitespace = (str) => str.replace(/\s+/g, " ");
      makeExcerpt = (strs, { startIndex, startOffset, endIndex, endOffset }) => {
        const start = strs[startIndex];
        const end = strs[endIndex];
        const match = start === end ? start.slice(startOffset, endOffset) : start.slice(startOffset) + strs.slice(start + 1, end).join("") + end.slice(0, endOffset);
        const trimmedStart = normalizeWhitespace(start.slice(0, startOffset)).trimStart();
        const trimmedEnd = normalizeWhitespace(end.slice(endOffset)).trimEnd();
        const ellipsisPre = trimmedStart.length < CONTEXT_LENGTH ? "" : "\u2026";
        const ellipsisPost = trimmedEnd.length < CONTEXT_LENGTH ? "" : "\u2026";
        const pre = `${ellipsisPre}${trimmedStart.slice(-CONTEXT_LENGTH)}`;
        const post = `${trimmedEnd.slice(0, CONTEXT_LENGTH)}${ellipsisPost}`;
        return { pre, match, post };
      };
      simpleSearch = function* (strs, query, options = {}) {
        const { locales: locales2 = "en", sensitivity } = options;
        const matchCase = sensitivity === "variant";
        const haystack = strs.join("");
        const lowerHaystack = matchCase ? haystack : haystack.toLocaleLowerCase(locales2);
        const needle = matchCase ? query : query.toLocaleLowerCase(locales2);
        const needleLength = needle.length;
        let index = -1;
        let strIndex = -1;
        let sum = 0;
        do {
          index = lowerHaystack.indexOf(needle, index + 1);
          if (index > -1) {
            while (sum <= index) sum += strs[++strIndex].length;
            const startIndex = strIndex;
            const startOffset = index - (sum - strs[strIndex].length);
            const end = index + needleLength;
            while (sum <= end) sum += strs[++strIndex].length;
            const endIndex = strIndex;
            const endOffset = end - (sum - strs[strIndex].length);
            const range = { startIndex, startOffset, endIndex, endOffset };
            yield { range, excerpt: makeExcerpt(strs, range) };
          }
        } while (index > -1);
      };
      segmenterSearch = function* (strs, query, options = {}) {
        const { locales: locales2 = "en", granularity = "word", sensitivity = "base" } = options;
        let segmenter, collator;
        try {
          segmenter = new Intl.Segmenter(locales2, { usage: "search", granularity });
          collator = new Intl.Collator(locales2, { sensitivity });
        } catch (e2) {
          console.warn(e2);
          segmenter = new Intl.Segmenter("en", { usage: "search", granularity });
          collator = new Intl.Collator("en", { sensitivity });
        }
        const queryLength = Array.from(segmenter.segment(query)).length;
        const substrArr = [];
        let strIndex = 0;
        let segments = segmenter.segment(strs[strIndex])[Symbol.iterator]();
        main: while (strIndex < strs.length) {
          while (substrArr.length < queryLength) {
            const { done, value } = segments.next();
            if (done) {
              strIndex++;
              if (strIndex < strs.length) {
                segments = segmenter.segment(strs[strIndex])[Symbol.iterator]();
                continue;
              } else break main;
            }
            const { index, segment } = value;
            if (!/[^\p{Format}]/u.test(segment)) continue;
            if (/\s/u.test(segment)) {
              if (!/\s/u.test(substrArr[substrArr.length - 1]?.segment))
                substrArr.push({ strIndex, index, segment: " " });
              continue;
            }
            value.strIndex = strIndex;
            substrArr.push(value);
          }
          const substr = substrArr.map((x2) => x2.segment).join("");
          if (collator.compare(query, substr) === 0) {
            const endIndex = strIndex;
            const lastSeg = substrArr[substrArr.length - 1];
            const endOffset = lastSeg.index + lastSeg.segment.length;
            const startIndex = substrArr[0].strIndex;
            const startOffset = substrArr[0].index;
            const range = { startIndex, startOffset, endIndex, endOffset };
            yield { range, excerpt: makeExcerpt(strs, range) };
          }
          substrArr.shift();
        }
      };
      search = (strs, query, options) => {
        const { granularity = "grapheme", sensitivity = "base" } = options;
        if (!Intl?.Segmenter || granularity === "grapheme" && (sensitivity === "variant" || sensitivity === "accent"))
          return simpleSearch(strs, query, options);
        return segmenterSearch(strs, query, options);
      };
      searchMatcher = (textWalker2, opts) => {
        const { defalutLocale, matchCase, matchDiacritics, matchWholeWords } = opts;
        return function* (doc, query) {
          const iter = textWalker2(doc, function* (strs, makeRange) {
            for (const result of search(strs, query, {
              locales: doc.body.lang || doc.documentElement.lang || defalutLocale || "en",
              granularity: matchWholeWords ? "word" : "grapheme",
              sensitivity: matchDiacritics && matchCase ? "variant" : matchDiacritics && !matchCase ? "accent" : !matchDiacritics && matchCase ? "case" : "base"
            })) {
              const { startIndex, startOffset, endIndex, endOffset } = result.range;
              result.range = makeRange(startIndex, startOffset, endIndex, endOffset);
              yield result;
            }
          });
          for (const result of iter) yield result;
        };
      };
    }
  });

  // vendor/zip.js
  var zip_exports = {};
  __export(zip_exports, {
    BlobReader: () => on,
    BlobWriter: () => ln,
    TextWriter: () => cn,
    ZipReader: () => Pn,
    configure: () => Ae
  });
  function m() {
    let t2, n2, i2, o2, c2, u2;
    function d2(t3, n3, a2, d3, f3, _2, h2, w2, b2, m2, g2) {
      let y2, x2, k2, v2, S2, z2, A2, U2, D2, E2, F2, T2, O2, C2, W2;
      E2 = 0, S2 = a2;
      do {
        i2[t3[n3 + E2]]++, E2++, S2--;
      } while (0 !== S2);
      if (i2[0] == a2) return h2[0] = -1, w2[0] = 0, e;
      for (U2 = w2[0], z2 = 1; z2 <= p && 0 === i2[z2]; z2++) ;
      for (A2 = z2, U2 < z2 && (U2 = z2), S2 = p; 0 !== S2 && 0 === i2[S2]; S2--) ;
      for (k2 = S2, U2 > S2 && (U2 = S2), w2[0] = U2, C2 = 1 << z2; z2 < S2; z2++, C2 <<= 1) if ((C2 -= i2[z2]) < 0) return r;
      if ((C2 -= i2[S2]) < 0) return r;
      for (i2[S2] += C2, u2[1] = z2 = 0, E2 = 1, O2 = 2; 0 != --S2; ) u2[O2] = z2 += i2[E2], O2++, E2++;
      S2 = 0, E2 = 0;
      do {
        0 !== (z2 = t3[n3 + E2]) && (g2[u2[z2]++] = S2), E2++;
      } while (++S2 < a2);
      for (a2 = u2[k2], u2[0] = S2 = 0, E2 = 0, v2 = -1, T2 = -U2, c2[0] = 0, F2 = 0, W2 = 0; A2 <= k2; A2++) for (y2 = i2[A2]; 0 != y2--; ) {
        for (; A2 > T2 + U2; ) {
          if (v2++, T2 += U2, W2 = k2 - T2, W2 = W2 > U2 ? U2 : W2, (x2 = 1 << (z2 = A2 - T2)) > y2 + 1 && (x2 -= y2 + 1, O2 = A2, z2 < W2)) for (; ++z2 < W2 && !((x2 <<= 1) <= i2[++O2]); ) x2 -= i2[O2];
          if (W2 = 1 << z2, m2[0] + W2 > l) return r;
          c2[v2] = F2 = m2[0], m2[0] += W2, 0 !== v2 ? (u2[v2] = S2, o2[0] = z2, o2[1] = U2, z2 = S2 >>> T2 - U2, o2[2] = F2 - c2[v2 - 1] - z2, b2.set(o2, 3 * (c2[v2 - 1] + z2))) : h2[0] = F2;
        }
        for (o2[1] = A2 - T2, E2 >= a2 ? o2[0] = 192 : g2[E2] < d3 ? (o2[0] = g2[E2] < 256 ? 0 : 96, o2[2] = g2[E2++]) : (o2[0] = _2[g2[E2] - d3] + 16 + 64, o2[2] = f3[g2[E2++] - d3]), x2 = 1 << A2 - T2, z2 = S2 >>> T2; z2 < W2; z2 += x2) b2.set(o2, 3 * (F2 + z2));
        for (z2 = 1 << A2 - 1; 0 != (S2 & z2); z2 >>>= 1) S2 ^= z2;
        for (S2 ^= z2, D2 = (1 << T2) - 1; (S2 & D2) != u2[v2]; ) v2--, T2 -= U2, D2 = (1 << T2) - 1;
      }
      return 0 !== C2 && 1 != k2 ? s : e;
    }
    function f2(e2) {
      let r2;
      for (t2 || (t2 = [], n2 = [], i2 = new Int32Array(p + 1), o2 = [], c2 = new Int32Array(p), u2 = new Int32Array(p + 1)), n2.length < e2 && (n2 = []), r2 = 0; r2 < e2; r2++) n2[r2] = 0;
      for (r2 = 0; r2 < p + 1; r2++) i2[r2] = 0;
      for (r2 = 0; r2 < 3; r2++) o2[r2] = 0;
      c2.set(i2.subarray(0, p), 0), u2.set(i2.subarray(0, p + 1), 0);
    }
    this.inflate_trees_bits = function(e2, i3, a2, o3, l2) {
      let c3;
      return f2(19), t2[0] = 0, c3 = d2(e2, 0, 19, 19, null, null, a2, i3, o3, t2, n2), c3 == r ? l2.msg = "oversubscribed dynamic bit lengths tree" : c3 != s && 0 !== i3[0] || (l2.msg = "incomplete dynamic bit lengths tree", c3 = r), c3;
    }, this.inflate_trees_dynamic = function(i3, o3, l2, c3, u3, p2, m2, g2, y2) {
      let x2;
      return f2(288), t2[0] = 0, x2 = d2(l2, 0, i3, 257, _, h, p2, c3, g2, t2, n2), x2 != e || 0 === c3[0] ? (x2 == r ? y2.msg = "oversubscribed literal/length tree" : x2 != a && (y2.msg = "incomplete literal/length tree", x2 = r), x2) : (f2(288), x2 = d2(l2, i3, o3, 0, w, b, m2, u3, g2, t2, n2), x2 != e || 0 === u3[0] && i3 > 257 ? (x2 == r ? y2.msg = "oversubscribed distance tree" : x2 == s ? (y2.msg = "incomplete distance tree", x2 = r) : x2 != a && (y2.msg = "empty distance tree with lengths", x2 = r), x2) : e);
    };
  }
  function E() {
    const n2 = this;
    let a2, s2, l2, c2, u2 = 0, d2 = 0, f2 = 0, _2 = 0, h2 = 0, w2 = 0, b2 = 0, p2 = 0, m2 = 0, E2 = 0;
    function F2(n3, i2, a3, s3, l3, c3, u3, d3) {
      let f3, _3, h3, w3, b3, p3, m3, g2, y2, x2, k2, v2, S2, z2, A2, U2;
      m3 = d3.next_in_index, g2 = d3.avail_in, b3 = u3.bitb, p3 = u3.bitk, y2 = u3.write, x2 = y2 < u3.read ? u3.read - y2 - 1 : u3.end - y2, k2 = o[n3], v2 = o[i2];
      do {
        for (; p3 < 20; ) g2--, b3 |= (255 & d3.read_byte(m3++)) << p3, p3 += 8;
        if (f3 = b3 & k2, _3 = a3, h3 = s3, U2 = 3 * (h3 + f3), 0 !== (w3 = _3[U2])) for (; ; ) {
          if (b3 >>= _3[U2 + 1], p3 -= _3[U2 + 1], 0 != (16 & w3)) {
            for (w3 &= 15, S2 = _3[U2 + 2] + (b3 & o[w3]), b3 >>= w3, p3 -= w3; p3 < 15; ) g2--, b3 |= (255 & d3.read_byte(m3++)) << p3, p3 += 8;
            for (f3 = b3 & v2, _3 = l3, h3 = c3, U2 = 3 * (h3 + f3), w3 = _3[U2]; ; ) {
              if (b3 >>= _3[U2 + 1], p3 -= _3[U2 + 1], 0 != (16 & w3)) {
                for (w3 &= 15; p3 < w3; ) g2--, b3 |= (255 & d3.read_byte(m3++)) << p3, p3 += 8;
                if (z2 = _3[U2 + 2] + (b3 & o[w3]), b3 >>= w3, p3 -= w3, x2 -= S2, y2 >= z2) A2 = y2 - z2, y2 - A2 > 0 && 2 > y2 - A2 ? (u3.win[y2++] = u3.win[A2++], u3.win[y2++] = u3.win[A2++], S2 -= 2) : (u3.win.set(u3.win.subarray(A2, A2 + 2), y2), y2 += 2, A2 += 2, S2 -= 2);
                else {
                  A2 = y2 - z2;
                  do {
                    A2 += u3.end;
                  } while (A2 < 0);
                  if (w3 = u3.end - A2, S2 > w3) {
                    if (S2 -= w3, y2 - A2 > 0 && w3 > y2 - A2) do {
                      u3.win[y2++] = u3.win[A2++];
                    } while (0 != --w3);
                    else u3.win.set(u3.win.subarray(A2, A2 + w3), y2), y2 += w3, A2 += w3, w3 = 0;
                    A2 = 0;
                  }
                }
                if (y2 - A2 > 0 && S2 > y2 - A2) do {
                  u3.win[y2++] = u3.win[A2++];
                } while (0 != --S2);
                else u3.win.set(u3.win.subarray(A2, A2 + S2), y2), y2 += S2, A2 += S2, S2 = 0;
                break;
              }
              if (0 != (64 & w3)) return d3.msg = "invalid distance code", S2 = d3.avail_in - g2, S2 = p3 >> 3 < S2 ? p3 >> 3 : S2, g2 += S2, m3 -= S2, p3 -= S2 << 3, u3.bitb = b3, u3.bitk = p3, d3.avail_in = g2, d3.total_in += m3 - d3.next_in_index, d3.next_in_index = m3, u3.write = y2, r;
              f3 += _3[U2 + 2], f3 += b3 & o[w3], U2 = 3 * (h3 + f3), w3 = _3[U2];
            }
            break;
          }
          if (0 != (64 & w3)) return 0 != (32 & w3) ? (S2 = d3.avail_in - g2, S2 = p3 >> 3 < S2 ? p3 >> 3 : S2, g2 += S2, m3 -= S2, p3 -= S2 << 3, u3.bitb = b3, u3.bitk = p3, d3.avail_in = g2, d3.total_in += m3 - d3.next_in_index, d3.next_in_index = m3, u3.write = y2, t) : (d3.msg = "invalid literal/length code", S2 = d3.avail_in - g2, S2 = p3 >> 3 < S2 ? p3 >> 3 : S2, g2 += S2, m3 -= S2, p3 -= S2 << 3, u3.bitb = b3, u3.bitk = p3, d3.avail_in = g2, d3.total_in += m3 - d3.next_in_index, d3.next_in_index = m3, u3.write = y2, r);
          if (f3 += _3[U2 + 2], f3 += b3 & o[w3], U2 = 3 * (h3 + f3), 0 === (w3 = _3[U2])) {
            b3 >>= _3[U2 + 1], p3 -= _3[U2 + 1], u3.win[y2++] = _3[U2 + 2], x2--;
            break;
          }
        }
        else b3 >>= _3[U2 + 1], p3 -= _3[U2 + 1], u3.win[y2++] = _3[U2 + 2], x2--;
      } while (x2 >= 258 && g2 >= 10);
      return S2 = d3.avail_in - g2, S2 = p3 >> 3 < S2 ? p3 >> 3 : S2, g2 += S2, m3 -= S2, p3 -= S2 << 3, u3.bitb = b3, u3.bitk = p3, d3.avail_in = g2, d3.total_in += m3 - d3.next_in_index, d3.next_in_index = m3, u3.write = y2, e;
    }
    n2.init = function(e2, t2, n3, i2, r2, o2) {
      a2 = g, b2 = e2, p2 = t2, l2 = n3, m2 = i2, c2 = r2, E2 = o2, s2 = null;
    }, n2.proc = function(n3, T2, O2) {
      let C2, W2, j2, M2, L2, R2, B2, I2 = 0, N2 = 0, P2 = 0;
      for (P2 = T2.next_in_index, M2 = T2.avail_in, I2 = n3.bitb, N2 = n3.bitk, L2 = n3.write, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2; ; ) switch (a2) {
        case g:
          if (R2 >= 258 && M2 >= 10 && (n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, O2 = F2(b2, p2, l2, m2, c2, E2, n3, T2), P2 = T2.next_in_index, M2 = T2.avail_in, I2 = n3.bitb, N2 = n3.bitk, L2 = n3.write, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2, O2 != e)) {
            a2 = O2 == t ? A : D;
            break;
          }
          f2 = b2, s2 = l2, d2 = m2, a2 = y;
        case y:
          for (C2 = f2; N2 < C2; ) {
            if (0 === M2) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
            O2 = e, M2--, I2 |= (255 & T2.read_byte(P2++)) << N2, N2 += 8;
          }
          if (W2 = 3 * (d2 + (I2 & o[C2])), I2 >>>= s2[W2 + 1], N2 -= s2[W2 + 1], j2 = s2[W2], 0 === j2) {
            _2 = s2[W2 + 2], a2 = z;
            break;
          }
          if (0 != (16 & j2)) {
            h2 = 15 & j2, u2 = s2[W2 + 2], a2 = x;
            break;
          }
          if (0 == (64 & j2)) {
            f2 = j2, d2 = W2 / 3 + s2[W2 + 2];
            break;
          }
          if (0 != (32 & j2)) {
            a2 = A;
            break;
          }
          return a2 = D, T2.msg = "invalid literal/length code", O2 = r, n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
        case x:
          for (C2 = h2; N2 < C2; ) {
            if (0 === M2) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
            O2 = e, M2--, I2 |= (255 & T2.read_byte(P2++)) << N2, N2 += 8;
          }
          u2 += I2 & o[C2], I2 >>= C2, N2 -= C2, f2 = p2, s2 = c2, d2 = E2, a2 = k;
        case k:
          for (C2 = f2; N2 < C2; ) {
            if (0 === M2) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
            O2 = e, M2--, I2 |= (255 & T2.read_byte(P2++)) << N2, N2 += 8;
          }
          if (W2 = 3 * (d2 + (I2 & o[C2])), I2 >>= s2[W2 + 1], N2 -= s2[W2 + 1], j2 = s2[W2], 0 != (16 & j2)) {
            h2 = 15 & j2, w2 = s2[W2 + 2], a2 = v;
            break;
          }
          if (0 == (64 & j2)) {
            f2 = j2, d2 = W2 / 3 + s2[W2 + 2];
            break;
          }
          return a2 = D, T2.msg = "invalid distance code", O2 = r, n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
        case v:
          for (C2 = h2; N2 < C2; ) {
            if (0 === M2) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
            O2 = e, M2--, I2 |= (255 & T2.read_byte(P2++)) << N2, N2 += 8;
          }
          w2 += I2 & o[C2], I2 >>= C2, N2 -= C2, a2 = S;
        case S:
          for (B2 = L2 - w2; B2 < 0; ) B2 += n3.end;
          for (; 0 !== u2; ) {
            if (0 === R2 && (L2 == n3.end && 0 !== n3.read && (L2 = 0, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2), 0 === R2 && (n3.write = L2, O2 = n3.inflate_flush(T2, O2), L2 = n3.write, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2, L2 == n3.end && 0 !== n3.read && (L2 = 0, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2), 0 === R2))) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
            n3.win[L2++] = n3.win[B2++], R2--, B2 == n3.end && (B2 = 0), u2--;
          }
          a2 = g;
          break;
        case z:
          if (0 === R2 && (L2 == n3.end && 0 !== n3.read && (L2 = 0, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2), 0 === R2 && (n3.write = L2, O2 = n3.inflate_flush(T2, O2), L2 = n3.write, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2, L2 == n3.end && 0 !== n3.read && (L2 = 0, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2), 0 === R2))) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
          O2 = e, n3.win[L2++] = _2, R2--, a2 = g;
          break;
        case A:
          if (N2 > 7 && (N2 -= 8, M2++, P2--), n3.write = L2, O2 = n3.inflate_flush(T2, O2), L2 = n3.write, R2 = L2 < n3.read ? n3.read - L2 - 1 : n3.end - L2, n3.read != n3.write) return n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
          a2 = U;
        case U:
          return O2 = t, n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
        case D:
          return O2 = r, n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
        default:
          return O2 = i, n3.bitb = I2, n3.bitk = N2, T2.avail_in = M2, T2.total_in += P2 - T2.next_in_index, T2.next_in_index = P2, n3.write = L2, n3.inflate_flush(T2, O2);
      }
    }, n2.free = function() {
    };
  }
  function N(n2, a2) {
    const c2 = this;
    let u2, d2 = T, f2 = 0, _2 = 0, h2 = 0;
    const w2 = [0], b2 = [0], p2 = new E();
    let g2 = 0, y2 = new Int32Array(3 * l);
    const x2 = new m();
    c2.bitk = 0, c2.bitb = 0, c2.win = new Uint8Array(a2), c2.end = a2, c2.read = 0, c2.write = 0, c2.reset = function(e2, t2) {
      t2 && (t2[0] = 0), d2 == L && p2.free(e2), d2 = T, c2.bitk = 0, c2.bitb = 0, c2.read = c2.write = 0;
    }, c2.reset(n2, null), c2.inflate_flush = function(t2, n3) {
      let i2, r2, a3;
      return r2 = t2.next_out_index, a3 = c2.read, i2 = (a3 <= c2.write ? c2.write : c2.end) - a3, i2 > t2.avail_out && (i2 = t2.avail_out), 0 !== i2 && n3 == s && (n3 = e), t2.avail_out -= i2, t2.total_out += i2, t2.next_out.set(c2.win.subarray(a3, a3 + i2), r2), r2 += i2, a3 += i2, a3 == c2.end && (a3 = 0, c2.write == c2.end && (c2.write = 0), i2 = c2.write - a3, i2 > t2.avail_out && (i2 = t2.avail_out), 0 !== i2 && n3 == s && (n3 = e), t2.avail_out -= i2, t2.total_out += i2, t2.next_out.set(c2.win.subarray(a3, a3 + i2), r2), r2 += i2, a3 += i2), t2.next_out_index = r2, c2.read = a3, n3;
    }, c2.proc = function(n3, a3) {
      let s2, l2, k2, v2, S2, z2, A2, U2;
      for (v2 = n3.next_in_index, S2 = n3.avail_in, l2 = c2.bitb, k2 = c2.bitk, z2 = c2.write, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2; ; ) {
        let D2, E2, N2, P2, V2, q2, H2, K2;
        switch (d2) {
          case T:
            for (; k2 < 3; ) {
              if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
              a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
            }
            switch (s2 = 7 & l2, g2 = 1 & s2, s2 >>> 1) {
              case 0:
                l2 >>>= 3, k2 -= 3, s2 = 7 & k2, l2 >>>= s2, k2 -= s2, d2 = O;
                break;
              case 1:
                D2 = [], E2 = [], N2 = [[]], P2 = [[]], m.inflate_trees_fixed(D2, E2, N2, P2), p2.init(D2[0], E2[0], N2[0], 0, P2[0], 0), l2 >>>= 3, k2 -= 3, d2 = L;
                break;
              case 2:
                l2 >>>= 3, k2 -= 3, d2 = W;
                break;
              case 3:
                return l2 >>>= 3, k2 -= 3, d2 = I, n3.msg = "invalid block type", a3 = r, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            }
            break;
          case O:
            for (; k2 < 32; ) {
              if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
              a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
            }
            if ((~l2 >>> 16 & 65535) != (65535 & l2)) return d2 = I, n3.msg = "invalid stored block lengths", a3 = r, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            f2 = 65535 & l2, l2 = k2 = 0, d2 = 0 !== f2 ? C : 0 !== g2 ? R : T;
            break;
          case C:
            if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            if (0 === A2 && (z2 == c2.end && 0 !== c2.read && (z2 = 0, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2), 0 === A2 && (c2.write = z2, a3 = c2.inflate_flush(n3, a3), z2 = c2.write, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2, z2 == c2.end && 0 !== c2.read && (z2 = 0, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2), 0 === A2))) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            if (a3 = e, s2 = f2, s2 > S2 && (s2 = S2), s2 > A2 && (s2 = A2), c2.win.set(n3.read_buf(v2, s2), z2), v2 += s2, S2 -= s2, z2 += s2, A2 -= s2, 0 != (f2 -= s2)) break;
            d2 = 0 !== g2 ? R : T;
            break;
          case W:
            for (; k2 < 14; ) {
              if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
              a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
            }
            if (_2 = s2 = 16383 & l2, (31 & s2) > 29 || (s2 >> 5 & 31) > 29) return d2 = I, n3.msg = "too many length or distance symbols", a3 = r, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            if (s2 = 258 + (31 & s2) + (s2 >> 5 & 31), !u2 || u2.length < s2) u2 = [];
            else for (U2 = 0; U2 < s2; U2++) u2[U2] = 0;
            l2 >>>= 14, k2 -= 14, h2 = 0, d2 = j;
          case j:
            for (; h2 < 4 + (_2 >>> 10); ) {
              for (; k2 < 3; ) {
                if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
                a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
              }
              u2[F[h2++]] = 7 & l2, l2 >>>= 3, k2 -= 3;
            }
            for (; h2 < 19; ) u2[F[h2++]] = 0;
            if (w2[0] = 7, s2 = x2.inflate_trees_bits(u2, w2, b2, y2, n3), s2 != e) return (a3 = s2) == r && (u2 = null, d2 = I), c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            h2 = 0, d2 = M;
          case M:
            for (; s2 = _2, !(h2 >= 258 + (31 & s2) + (s2 >> 5 & 31)); ) {
              let t2, i2;
              for (s2 = w2[0]; k2 < s2; ) {
                if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
                a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
              }
              if (s2 = y2[3 * (b2[0] + (l2 & o[s2])) + 1], i2 = y2[3 * (b2[0] + (l2 & o[s2])) + 2], i2 < 16) l2 >>>= s2, k2 -= s2, u2[h2++] = i2;
              else {
                for (U2 = 18 == i2 ? 7 : i2 - 14, t2 = 18 == i2 ? 11 : 3; k2 < s2 + U2; ) {
                  if (0 === S2) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
                  a3 = e, S2--, l2 |= (255 & n3.read_byte(v2++)) << k2, k2 += 8;
                }
                if (l2 >>>= s2, k2 -= s2, t2 += l2 & o[U2], l2 >>>= U2, k2 -= U2, U2 = h2, s2 = _2, U2 + t2 > 258 + (31 & s2) + (s2 >> 5 & 31) || 16 == i2 && U2 < 1) return u2 = null, d2 = I, n3.msg = "invalid bit length repeat", a3 = r, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
                i2 = 16 == i2 ? u2[U2 - 1] : 0;
                do {
                  u2[U2++] = i2;
                } while (0 != --t2);
                h2 = U2;
              }
            }
            if (b2[0] = -1, V2 = [], q2 = [], H2 = [], K2 = [], V2[0] = 9, q2[0] = 6, s2 = _2, s2 = x2.inflate_trees_dynamic(257 + (31 & s2), 1 + (s2 >> 5 & 31), u2, V2, q2, H2, K2, y2, n3), s2 != e) return s2 == r && (u2 = null, d2 = I), a3 = s2, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            p2.init(V2[0], q2[0], y2, H2[0], y2, K2[0]), d2 = L;
          case L:
            if (c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, (a3 = p2.proc(c2, n3, a3)) != t) return c2.inflate_flush(n3, a3);
            if (a3 = e, p2.free(n3), v2 = n3.next_in_index, S2 = n3.avail_in, l2 = c2.bitb, k2 = c2.bitk, z2 = c2.write, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2, 0 === g2) {
              d2 = T;
              break;
            }
            d2 = R;
          case R:
            if (c2.write = z2, a3 = c2.inflate_flush(n3, a3), z2 = c2.write, A2 = z2 < c2.read ? c2.read - z2 - 1 : c2.end - z2, c2.read != c2.write) return c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
            d2 = B;
          case B:
            return a3 = t, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
          case I:
            return a3 = r, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
          default:
            return a3 = i, c2.bitb = l2, c2.bitk = k2, n3.avail_in = S2, n3.total_in += v2 - n3.next_in_index, n3.next_in_index = v2, c2.write = z2, c2.inflate_flush(n3, a3);
        }
      }
    }, c2.free = function(e2) {
      c2.reset(e2, null), c2.win = null, y2 = null;
    }, c2.set_dictionary = function(e2, t2, n3) {
      c2.win.set(e2.subarray(t2, t2 + n3), 0), c2.read = c2.write = n3;
    }, c2.sync_point = function() {
      return d2 == O ? 1 : 0;
    };
  }
  function te() {
    const a2 = this;
    function o2(t2) {
      return t2 && t2.istate ? (t2.total_in = t2.total_out = 0, t2.msg = null, t2.istate.mode = X, t2.istate.blocks.reset(t2, null), e) : i;
    }
    a2.mode = 0, a2.method = 0, a2.was = [0], a2.need = 0, a2.marker = 0, a2.wbits = 0, a2.inflateEnd = function(t2) {
      return a2.blocks && a2.blocks.free(t2), a2.blocks = null, e;
    }, a2.inflateInit = function(t2, n2) {
      return t2.msg = null, a2.blocks = null, n2 < 8 || n2 > 15 ? (a2.inflateEnd(t2), i) : (a2.wbits = n2, t2.istate.blocks = new N(t2, 1 << n2), o2(t2), e);
    }, a2.inflate = function(a3, o3) {
      let l2, c2;
      if (!a3 || !a3.istate || !a3.next_in) return i;
      const d2 = a3.istate;
      for (o3 = o3 == u ? s : e, l2 = s; ; ) switch (d2.mode) {
        case q:
          if (0 === a3.avail_in) return l2;
          if (l2 = o3, a3.avail_in--, a3.total_in++, (15 & (d2.method = a3.read_byte(a3.next_in_index++))) != V) {
            d2.mode = $, a3.msg = "unknown compression method", d2.marker = 5;
            break;
          }
          if (8 + (d2.method >> 4) > d2.wbits) {
            d2.mode = $, a3.msg = "invalid win size", d2.marker = 5;
            break;
          }
          d2.mode = H;
        case H:
          if (0 === a3.avail_in) return l2;
          if (l2 = o3, a3.avail_in--, a3.total_in++, c2 = 255 & a3.read_byte(a3.next_in_index++), ((d2.method << 8) + c2) % 31 != 0) {
            d2.mode = $, a3.msg = "incorrect header check", d2.marker = 5;
            break;
          }
          if (0 == (c2 & P)) {
            d2.mode = X;
            break;
          }
          d2.mode = K;
        case K:
          if (0 === a3.avail_in) return l2;
          l2 = o3, a3.avail_in--, a3.total_in++, d2.need = (255 & a3.read_byte(a3.next_in_index++)) << 24 & 4278190080, d2.mode = Z;
        case Z:
          if (0 === a3.avail_in) return l2;
          l2 = o3, a3.avail_in--, a3.total_in++, d2.need += (255 & a3.read_byte(a3.next_in_index++)) << 16 & 16711680, d2.mode = G;
        case G:
          if (0 === a3.avail_in) return l2;
          l2 = o3, a3.avail_in--, a3.total_in++, d2.need += (255 & a3.read_byte(a3.next_in_index++)) << 8 & 65280, d2.mode = J;
        case J:
          return 0 === a3.avail_in ? l2 : (l2 = o3, a3.avail_in--, a3.total_in++, d2.need += 255 & a3.read_byte(a3.next_in_index++), d2.mode = Q, n);
        case Q:
          return d2.mode = $, a3.msg = "need dictionary", d2.marker = 0, i;
        case X:
          if (l2 = d2.blocks.proc(a3, l2), l2 == r) {
            d2.mode = $, d2.marker = 0;
            break;
          }
          if (l2 == e && (l2 = o3), l2 != t) return l2;
          l2 = o3, d2.blocks.reset(a3, d2.was), d2.mode = Y;
        case Y:
          return a3.avail_in = 0, t;
        case $:
          return r;
        default:
          return i;
      }
    }, a2.inflateSetDictionary = function(t2, n2, r2) {
      let a3 = 0, s2 = r2;
      if (!t2 || !t2.istate || t2.istate.mode != Q) return i;
      const o3 = t2.istate;
      return s2 >= 1 << o3.wbits && (s2 = (1 << o3.wbits) - 1, a3 = r2 - s2), o3.blocks.set_dictionary(n2, a3, s2), o3.mode = X, e;
    }, a2.inflateSync = function(t2) {
      let n2, a3, l2, c2, u2;
      if (!t2 || !t2.istate) return i;
      const d2 = t2.istate;
      if (d2.mode != $ && (d2.mode = $, d2.marker = 0), 0 === (n2 = t2.avail_in)) return s;
      for (a3 = t2.next_in_index, l2 = d2.marker; 0 !== n2 && l2 < 4; ) t2.read_byte(a3) == ee[l2] ? l2++ : l2 = 0 !== t2.read_byte(a3) ? 0 : 4 - l2, a3++, n2--;
      return t2.total_in += a3 - t2.next_in_index, t2.next_in_index = a3, t2.avail_in = n2, d2.marker = l2, 4 != l2 ? r : (c2 = t2.total_in, u2 = t2.total_out, o2(t2), t2.total_in = c2, t2.total_out = u2, d2.mode = X, e);
    }, a2.inflateSyncPoint = function(e2) {
      return e2 && e2.istate && e2.istate.blocks ? e2.istate.blocks.sync_point() : i;
    };
  }
  function ne() {
  }
  function Ae(e2) {
    const { baseURL: t2, chunkSize: n2, maxWorkers: i2, terminateWorkerTimeout: r2, useCompressionStream: a2, useWebWorkers: s2, Deflate: o2, Inflate: l2, CompressionStream: c2, DecompressionStream: u2, workerScripts: d2 } = e2;
    if (Ue("baseURL", t2), Ue("chunkSize", n2), Ue("maxWorkers", i2), Ue("terminateWorkerTimeout", r2), Ue("useCompressionStream", a2), Ue("useWebWorkers", s2), o2 && (ze.CompressionStream = new xe(o2)), l2 && (ze.DecompressionStream = new xe(l2)), Ue("CompressionStream", c2), Ue("DecompressionStream", u2), d2 !== me) {
      const { deflate: e3, inflate: t3 } = d2;
      if ((e3 || t3) && (ze.workerScripts || (ze.workerScripts = {})), e3) {
        if (!Array.isArray(e3)) throw new Error("workerScripts.deflate must be an array");
        ze.workerScripts.deflate = e3;
      }
      if (t3) {
        if (!Array.isArray(t3)) throw new Error("workerScripts.inflate must be an array");
        ze.workerScripts.inflate = t3;
      }
    }
  }
  function Ue(e2, t2) {
    t2 !== me && (ze[e2] = t2);
  }
  function Ne(e2) {
    return Re ? crypto.getRandomValues(e2) : je.getRandomValues(e2);
  }
  function dt(e2, t2, n2, i2, r2, a2) {
    const { ctr: s2, hmac: o2, pending: l2 } = e2, c2 = t2.length - r2;
    let u2;
    for (l2.length && (t2 = _t(l2, t2), n2 = (function(e3, t3) {
      if (t3 && t3 > e3.length) {
        const n3 = e3;
        (e3 = new Uint8Array(t3)).set(n3, 0);
      }
      return e3;
    })(n2, c2 - c2 % Pe)), u2 = 0; u2 <= c2 - Pe; u2 += Pe) {
      const e3 = bt(it, ht(t2, u2, u2 + Pe));
      a2 && o2.update(e3);
      const r3 = s2.update(e3);
      a2 || o2.update(r3), n2.set(wt(it, r3), u2 + i2);
    }
    return e2.pending = ht(t2, u2), n2;
  }
  async function ft(e2, t2, n2, i2) {
    e2.password = null;
    const r2 = (function(e3) {
      if ("undefined" == typeof TextEncoder) {
        e3 = unescape(encodeURIComponent(e3));
        const t3 = new Uint8Array(e3.length);
        for (let n3 = 0; n3 < t3.length; n3++) t3[n3] = e3.charCodeAt(n3);
        return t3;
      }
      return new TextEncoder().encode(e3);
    })(n2), a2 = await (async function(e3, t3, n3, i3, r3) {
      if (!ot) return Le.importKey(t3);
      try {
        return await tt.importKey(e3, t3, n3, i3, r3);
      } catch (e4) {
        return ot = false, Le.importKey(t3);
      }
    })(Ve, r2, He, false, Ze), s2 = await (async function(e3, t3, n3) {
      if (!lt) return Le.pbkdf2(t3, e3.salt, Ke.iterations, n3);
      try {
        return await tt.deriveBits(e3, t3, n3);
      } catch (i3) {
        return lt = false, Le.pbkdf2(t3, e3.salt, Ke.iterations, n3);
      }
    })(Object.assign({ salt: i2 }, Ke), a2, 8 * (2 * Je[t2] + 2)), o2 = new Uint8Array(s2), l2 = bt(it, ht(o2, 0, Je[t2])), c2 = bt(it, ht(o2, Je[t2], 2 * Je[t2])), u2 = ht(o2, 2 * Je[t2]);
    return Object.assign(e2, { keys: { key: l2, authentication: c2, passwordVerification: u2 }, ctr: new at(new rt(l2), Array.from(Xe)), hmac: new st(c2) }), u2;
  }
  function _t(e2, t2) {
    let n2 = e2;
    return e2.length + t2.length && (n2 = new Uint8Array(e2.length + t2.length), n2.set(e2, 0), n2.set(t2, e2.length)), n2;
  }
  function ht(e2, t2, n2) {
    return e2.subarray(t2, n2);
  }
  function wt(e2, t2) {
    return e2.fromBits(t2);
  }
  function bt(e2, t2) {
    return e2.toBits(t2);
  }
  function yt(e2, t2) {
    const n2 = new Uint8Array(t2.length);
    for (let i2 = 0; i2 < t2.length; i2++) n2[i2] = St(e2) ^ t2[i2], vt(e2, n2[i2]);
    return n2;
  }
  function xt(e2, t2) {
    const n2 = new Uint8Array(t2.length);
    for (let i2 = 0; i2 < t2.length; i2++) n2[i2] = St(e2) ^ t2[i2], vt(e2, t2[i2]);
    return n2;
  }
  function kt(e2, t2) {
    const n2 = [305419896, 591751049, 878082192];
    Object.assign(e2, { keys: n2, crcKey0: new Ee(n2[0]), crcKey2: new Ee(n2[2]) });
    for (let n3 = 0; n3 < t2.length; n3++) vt(e2, t2.charCodeAt(n3));
  }
  function vt(e2, t2) {
    let [n2, i2, r2] = e2.keys;
    e2.crcKey0.append([t2]), n2 = ~e2.crcKey0.get(), i2 = At(Math.imul(At(i2 + zt(n2)), 134775813) + 1), e2.crcKey2.append([i2 >>> 24]), r2 = ~e2.crcKey2.get(), e2.keys = [n2, i2, r2];
  }
  function St(e2) {
    const t2 = 2 | e2.keys[2];
    return zt(Math.imul(t2, 1 ^ t2) >>> 8);
  }
  function zt(e2) {
    return 255 & e2;
  }
  function At(e2) {
    return 4294967295 & e2;
  }
  function Ft(e2) {
    return Ct(e2, new TransformStream({ transform(e3, t2) {
      e3 && e3.length && t2.enqueue(e3);
    } }));
  }
  function Tt(e2, t2, n2) {
    t2 = Ct(t2, new TransformStream({ flush: n2 })), Object.defineProperty(e2, "readable", { get: () => t2 });
  }
  function Ot(e2, t2, n2, i2, r2) {
    try {
      e2 = Ct(e2, new (t2 && i2 ? i2 : r2)(Ut, n2));
    } catch (i3) {
      if (!t2) throw i3;
      e2 = Ct(e2, new r2(Ut, n2));
    }
    return e2;
  }
  function Ct(e2, t2) {
    return e2.pipeThrough(t2);
  }
  async function Ht(e2, ...t2) {
    try {
      await e2(...t2);
    } catch (e3) {
    }
  }
  function Kt(e2, t2) {
    return { run: () => (async function({ options: e3, readable: t3, writable: n2, onTaskFinished: i2 }, r2) {
      const a2 = new Nt(e3, r2);
      try {
        await t3.pipeThrough(a2).pipeTo(n2, { preventClose: true, preventAbort: true });
        const { signature: e4, size: i3 } = a2;
        return { signature: e4, size: i3 };
      } finally {
        i2();
      }
    })(e2, t2) };
  }
  function Zt(e2, { baseURL: t2, chunkSize: n2 }) {
    return e2.interface || Object.assign(e2, { worker: Qt(e2.scripts[0], t2, e2), interface: { run: () => (async function(e3, t3) {
      let n3, i2;
      const r2 = new Promise(((e4, t4) => {
        n3 = e4, i2 = t4;
      }));
      Object.assign(e3, { reader: null, writer: null, resolveResult: n3, rejectResult: i2, result: r2 });
      const { readable: a2, options: s2, scripts: o2 } = e3, { writable: l2, closed: c2 } = (function(e4) {
        const t4 = e4.getWriter();
        let n4;
        const i3 = new Promise(((e5) => n4 = e5)), r3 = new WritableStream({ async write(e5) {
          await t4.ready, await t4.write(e5);
        }, close() {
          t4.releaseLock(), n4();
        }, abort: (e5) => t4.abort(e5) });
        return { writable: r3, closed: i3 };
      })(e3.writable), u2 = Xt({ type: jt, scripts: o2.slice(1), options: s2, config: t3, readable: a2, writable: l2 }, e3);
      u2 || Object.assign(e3, { reader: a2.getReader(), writer: l2.getWriter() });
      const d2 = await r2;
      try {
        await l2.close();
      } catch (e4) {
      }
      return await c2, d2;
    })(e2, { chunkSize: n2 }) } }), e2.interface;
  }
  function Qt(e2, t2, n2) {
    const i2 = { type: "module" };
    let r2, a2;
    typeof e2 == ye && (e2 = e2());
    try {
      r2 = new URL(e2, t2);
    } catch (t3) {
      r2 = e2;
    }
    if (Gt) try {
      a2 = new Worker(r2);
    } catch (e3) {
      Gt = false, a2 = new Worker(r2, i2);
    }
    else a2 = new Worker(r2, i2);
    return a2.addEventListener(Wt, ((e3) => (async function({ data: e4 }, t3) {
      const { type: n3, value: i3, messageId: r3, result: a3, error: s2 } = e4, { reader: o2, writer: l2, resolveResult: c2, rejectResult: u2, onTaskFinished: d2 } = t3;
      try {
        if (s2) {
          const { message: e5, stack: t4, code: n4, name: i4 } = s2, r4 = new Error(e5);
          Object.assign(r4, { stack: t4, code: n4, name: i4 }), f2(r4);
        } else {
          if (n3 == Mt) {
            const { value: e5, done: n4 } = await o2.read();
            Xt({ type: Lt, value: e5, done: n4, messageId: r3 }, t3);
          }
          n3 == Lt && (await l2.ready, await l2.write(new Uint8Array(i3)), Xt({ type: Rt, messageId: r3 }, t3)), n3 == Bt && f2(null, a3);
        }
      } catch (s3) {
        f2(s3);
      }
      function f2(e5, t4) {
        e5 ? u2(e5) : c2(t4), l2 && l2.releaseLock(), d2();
      }
    })(e3, n2))), a2;
  }
  function Xt(e2, { worker: t2, writer: n2, onTaskFinished: i2, transferStreams: r2 }) {
    try {
      let { value: n3, readable: i3, writable: a2 } = e2;
      const s2 = [];
      if (n3) {
        const { buffer: t3, length: i4 } = n3;
        i4 != t3.byteLength && (n3 = new Uint8Array(n3)), e2.value = n3.buffer, s2.push(e2.value);
      }
      if (r2 && Jt ? (i3 && s2.push(i3), a2 && s2.push(a2)) : e2.readable = e2.writable = null, s2.length) try {
        return t2.postMessage(e2, s2), true;
      } catch (n4) {
        Jt = false, e2.readable = e2.writable = null, t2.postMessage(e2);
      }
      else t2.postMessage(e2);
    } catch (e3) {
      throw n2 && n2.releaseLock(), i2(), e3;
    }
  }
  function tn(e2) {
    const { terminateTimeout: t2 } = e2;
    t2 && (clearTimeout(t2), e2.terminateTimeout = null);
  }
  async function fn(e2, t2) {
    e2.init && !e2.initialized && await e2.init(t2);
  }
  function _n(e2) {
    return Array.isArray(e2) && (e2 = new un(e2)), e2 instanceof ReadableStream && (e2 = { readable: e2 }), e2;
  }
  function hn(e2, t2, n2, i2) {
    return e2.readUint8Array(t2, n2, i2);
  }
  function pn(e2, t2) {
    return t2 && "cp437" == t2.trim().toLowerCase() ? (function(e3) {
      if (bn) {
        let t3 = "";
        for (let n2 = 0; n2 < e3.length; n2++) t3 += wn[e3[n2]];
        return t3;
      }
      return new TextDecoder().decode(e3);
    })(e2) : new TextDecoder(t2).decode(e2);
  }
  function qn(e2, t2, n2) {
    const i2 = e2.rawBitFlag = Xn(t2, n2 + 2), r2 = (i2 & he) == he, a2 = Yn(t2, n2 + 6);
    Object.assign(e2, { encrypted: r2, version: Xn(t2, n2), bitFlag: { level: (i2 & we) >> 1, dataDescriptor: (i2 & be) == be, languageEncodingFlag: (i2 & pe) == pe }, rawLastModDate: a2, lastModDate: Gn(a2), filenameLength: Xn(t2, n2 + 22), extraFieldLength: Xn(t2, n2 + 24) });
  }
  async function Hn(e2, t2, n2, i2) {
    const { rawExtraField: r2 } = t2, a2 = t2.extraField = /* @__PURE__ */ new Map(), s2 = ei(new Uint8Array(r2));
    let o2 = 0;
    try {
      for (; o2 < r2.length; ) {
        const e3 = Xn(s2, o2), t3 = Xn(s2, o2 + 2);
        a2.set(e3, { type: e3, data: r2.slice(o2 + 4, o2 + 4 + t3) }), o2 += 4 + t3;
      }
    } catch (e3) {
    }
    const l2 = Xn(n2, i2 + 4);
    Object.assign(t2, { signature: Yn(n2, i2 + 10), uncompressedSize: Yn(n2, i2 + 18), compressedSize: Yn(n2, i2 + 14) });
    const c2 = a2.get(oe);
    c2 && (!(function(e3, t3) {
      t3.zip64 = true;
      const n3 = ei(e3.data), i3 = In.filter((([e4, n4]) => t3[e4] == n4));
      for (let r3 = 0, a3 = 0; r3 < i3.length; r3++) {
        const [s3, o3] = i3[r3];
        if (t3[s3] == o3) {
          const i4 = Nn[o3];
          t3[s3] = e3[s3] = i4.getValue(n3, a3), a3 += i4.bytes;
        } else if (e3[s3]) throw new Error(jn);
      }
    })(c2, t2), t2.extraFieldZip64 = c2);
    const u2 = a2.get(fe);
    u2 && (await Kn(u2, mn, gn, t2, e2), t2.extraFieldUnicodePath = u2);
    const d2 = a2.get(_e);
    d2 && (await Kn(d2, yn, xn, t2, e2), t2.extraFieldUnicodeComment = d2);
    const f2 = a2.get(le);
    f2 ? (!(function(e3, t3, n3) {
      const i3 = ei(e3.data), r3 = Qn(i3, 4);
      Object.assign(e3, { vendorVersion: Qn(i3, 0), vendorId: Qn(i3, 2), strength: r3, originalCompressionMethod: n3, compressionMethod: Xn(i3, 5) }), t3.compressionMethod = e3.compressionMethod;
    })(f2, t2, l2), t2.extraFieldAES = f2) : t2.compressionMethod = l2;
    const _2 = a2.get(ce);
    _2 && (!(function(e3, t3) {
      const n3 = ei(e3.data);
      let i3, r3 = 4;
      try {
        for (; r3 < e3.data.length && !i3; ) {
          const t4 = Xn(n3, r3), a3 = Xn(n3, r3 + 2);
          t4 == ue && (i3 = e3.data.slice(r3 + 4, r3 + 4 + a3)), r3 += 4 + a3;
        }
      } catch (e4) {
      }
      try {
        if (i3 && 24 == i3.length) {
          const n4 = ei(i3), r4 = n4.getBigUint64(0, true), a3 = n4.getBigUint64(8, true), s3 = n4.getBigUint64(16, true);
          Object.assign(e3, { rawLastModDate: r4, rawLastAccessDate: a3, rawCreationDate: s3 });
          const o3 = Jn(r4), l3 = Jn(a3), c3 = { lastModDate: o3, lastAccessDate: l3, creationDate: Jn(s3) };
          Object.assign(e3, c3), Object.assign(t3, c3);
        }
      } catch (e4) {
      }
    })(_2, t2), t2.extraFieldNTFS = _2);
    const h2 = a2.get(de);
    h2 && (!(function(e3, t3) {
      const n3 = ei(e3.data), i3 = Qn(n3, 0), r3 = [], a3 = [];
      1 == (1 & i3) && (r3.push(An), a3.push(Un));
      2 == (2 & i3) && (r3.push(Dn), a3.push(En));
      4 == (4 & i3) && (r3.push(Fn), a3.push(Tn));
      let s3 = 1;
      r3.forEach(((i4, r4) => {
        if (e3.data.length >= s3 + 4) {
          const o3 = Yn(n3, s3);
          t3[i4] = e3[i4] = new Date(1e3 * o3);
          const l3 = a3[r4];
          e3[l3] = o3;
        }
        s3 += 4;
      }));
    })(h2, t2), t2.extraFieldExtendedTimestamp = h2);
  }
  async function Kn(e2, t2, n2, i2, r2) {
    const a2 = ei(e2.data), s2 = new Ee();
    s2.append(r2[n2]);
    const o2 = ei(new Uint8Array(4));
    o2.setUint32(0, s2.get(), true), Object.assign(e2, { version: Qn(a2, 0), signature: Yn(a2, 1), [t2]: await pn(e2.data.subarray(5)), valid: !r2.bitFlag.languageEncodingFlag && e2.signature == Yn(o2, 0) }), e2.valid && (i2[t2] = e2[t2], i2[t2 + "UTF8"] = true);
  }
  function Zn(e2, t2, n2) {
    return t2[n2] === me ? e2.options[n2] : t2[n2];
  }
  function Gn(e2) {
    const t2 = (4294901760 & e2) >> 16, n2 = 65535 & e2;
    try {
      return new Date(1980 + ((65024 & t2) >> 9), ((480 & t2) >> 5) - 1, 31 & t2, (63488 & n2) >> 11, (2016 & n2) >> 5, 2 * (31 & n2), 0);
    } catch (e3) {
    }
  }
  function Jn(e2) {
    return new Date(Number(e2 / BigInt(1e4) - BigInt(116444736e5)));
  }
  function Qn(e2, t2) {
    return e2.getUint8(t2);
  }
  function Xn(e2, t2) {
    return e2.getUint16(t2, true);
  }
  function Yn(e2, t2) {
    return e2.getUint32(t2, true);
  }
  function $n(e2, t2) {
    return Number(e2.getBigUint64(t2, true));
  }
  function ei(e2) {
    return new DataView(e2.buffer);
  }
  var e, t, n, i, r, a, s, o, l, c, u, d, f, _, h, w, b, p, g, y, x, k, v, S, z, A, U, D, F, T, O, C, W, j, M, L, R, B, I, P, V, q, H, K, Z, G, J, Q, X, Y, $, ee, ie, re, ae, se, oe, le, ce, ue, de, fe, _e, he, we, be, pe, me, ge, ye, xe, ke, ve, Se, ze, De, Ee, Fe, Te, Oe, Ce, We, je, Me, Le, Re, Be, Ie, Pe, Ve, qe, He, Ke, Ze, Ge, Je, Qe, Xe, Ye, $e, et, tt, nt, it, rt, at, st, ot, lt, ct, ut, pt, mt, gt, Ut, Dt, Et, Wt, jt, Mt, Lt, Rt, Bt, It, Nt, Pt, Vt, qt, Gt, Jt, Yt, $t, en, nn, rn, an, sn, on, ln, cn, un, dn, wn, bn, mn, gn, yn, xn, kn, vn, Sn, zn, An, Un, Dn, En, Fn, Tn, On, Cn, Wn, jn, Mn, Ln, Rn, Bn, In, Nn, Pn, Vn;
  var init_zip = __esm({
    "vendor/zip.js"() {
      e = 0;
      t = 1;
      n = 2;
      i = -2;
      r = -3;
      a = -4;
      s = -5;
      o = [0, 1, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535];
      l = 1440;
      c = 0;
      u = 4;
      d = [96, 7, 256, 0, 8, 80, 0, 8, 16, 84, 8, 115, 82, 7, 31, 0, 8, 112, 0, 8, 48, 0, 9, 192, 80, 7, 10, 0, 8, 96, 0, 8, 32, 0, 9, 160, 0, 8, 0, 0, 8, 128, 0, 8, 64, 0, 9, 224, 80, 7, 6, 0, 8, 88, 0, 8, 24, 0, 9, 144, 83, 7, 59, 0, 8, 120, 0, 8, 56, 0, 9, 208, 81, 7, 17, 0, 8, 104, 0, 8, 40, 0, 9, 176, 0, 8, 8, 0, 8, 136, 0, 8, 72, 0, 9, 240, 80, 7, 4, 0, 8, 84, 0, 8, 20, 85, 8, 227, 83, 7, 43, 0, 8, 116, 0, 8, 52, 0, 9, 200, 81, 7, 13, 0, 8, 100, 0, 8, 36, 0, 9, 168, 0, 8, 4, 0, 8, 132, 0, 8, 68, 0, 9, 232, 80, 7, 8, 0, 8, 92, 0, 8, 28, 0, 9, 152, 84, 7, 83, 0, 8, 124, 0, 8, 60, 0, 9, 216, 82, 7, 23, 0, 8, 108, 0, 8, 44, 0, 9, 184, 0, 8, 12, 0, 8, 140, 0, 8, 76, 0, 9, 248, 80, 7, 3, 0, 8, 82, 0, 8, 18, 85, 8, 163, 83, 7, 35, 0, 8, 114, 0, 8, 50, 0, 9, 196, 81, 7, 11, 0, 8, 98, 0, 8, 34, 0, 9, 164, 0, 8, 2, 0, 8, 130, 0, 8, 66, 0, 9, 228, 80, 7, 7, 0, 8, 90, 0, 8, 26, 0, 9, 148, 84, 7, 67, 0, 8, 122, 0, 8, 58, 0, 9, 212, 82, 7, 19, 0, 8, 106, 0, 8, 42, 0, 9, 180, 0, 8, 10, 0, 8, 138, 0, 8, 74, 0, 9, 244, 80, 7, 5, 0, 8, 86, 0, 8, 22, 192, 8, 0, 83, 7, 51, 0, 8, 118, 0, 8, 54, 0, 9, 204, 81, 7, 15, 0, 8, 102, 0, 8, 38, 0, 9, 172, 0, 8, 6, 0, 8, 134, 0, 8, 70, 0, 9, 236, 80, 7, 9, 0, 8, 94, 0, 8, 30, 0, 9, 156, 84, 7, 99, 0, 8, 126, 0, 8, 62, 0, 9, 220, 82, 7, 27, 0, 8, 110, 0, 8, 46, 0, 9, 188, 0, 8, 14, 0, 8, 142, 0, 8, 78, 0, 9, 252, 96, 7, 256, 0, 8, 81, 0, 8, 17, 85, 8, 131, 82, 7, 31, 0, 8, 113, 0, 8, 49, 0, 9, 194, 80, 7, 10, 0, 8, 97, 0, 8, 33, 0, 9, 162, 0, 8, 1, 0, 8, 129, 0, 8, 65, 0, 9, 226, 80, 7, 6, 0, 8, 89, 0, 8, 25, 0, 9, 146, 83, 7, 59, 0, 8, 121, 0, 8, 57, 0, 9, 210, 81, 7, 17, 0, 8, 105, 0, 8, 41, 0, 9, 178, 0, 8, 9, 0, 8, 137, 0, 8, 73, 0, 9, 242, 80, 7, 4, 0, 8, 85, 0, 8, 21, 80, 8, 258, 83, 7, 43, 0, 8, 117, 0, 8, 53, 0, 9, 202, 81, 7, 13, 0, 8, 101, 0, 8, 37, 0, 9, 170, 0, 8, 5, 0, 8, 133, 0, 8, 69, 0, 9, 234, 80, 7, 8, 0, 8, 93, 0, 8, 29, 0, 9, 154, 84, 7, 83, 0, 8, 125, 0, 8, 61, 0, 9, 218, 82, 7, 23, 0, 8, 109, 0, 8, 45, 0, 9, 186, 0, 8, 13, 0, 8, 141, 0, 8, 77, 0, 9, 250, 80, 7, 3, 0, 8, 83, 0, 8, 19, 85, 8, 195, 83, 7, 35, 0, 8, 115, 0, 8, 51, 0, 9, 198, 81, 7, 11, 0, 8, 99, 0, 8, 35, 0, 9, 166, 0, 8, 3, 0, 8, 131, 0, 8, 67, 0, 9, 230, 80, 7, 7, 0, 8, 91, 0, 8, 27, 0, 9, 150, 84, 7, 67, 0, 8, 123, 0, 8, 59, 0, 9, 214, 82, 7, 19, 0, 8, 107, 0, 8, 43, 0, 9, 182, 0, 8, 11, 0, 8, 139, 0, 8, 75, 0, 9, 246, 80, 7, 5, 0, 8, 87, 0, 8, 23, 192, 8, 0, 83, 7, 51, 0, 8, 119, 0, 8, 55, 0, 9, 206, 81, 7, 15, 0, 8, 103, 0, 8, 39, 0, 9, 174, 0, 8, 7, 0, 8, 135, 0, 8, 71, 0, 9, 238, 80, 7, 9, 0, 8, 95, 0, 8, 31, 0, 9, 158, 84, 7, 99, 0, 8, 127, 0, 8, 63, 0, 9, 222, 82, 7, 27, 0, 8, 111, 0, 8, 47, 0, 9, 190, 0, 8, 15, 0, 8, 143, 0, 8, 79, 0, 9, 254, 96, 7, 256, 0, 8, 80, 0, 8, 16, 84, 8, 115, 82, 7, 31, 0, 8, 112, 0, 8, 48, 0, 9, 193, 80, 7, 10, 0, 8, 96, 0, 8, 32, 0, 9, 161, 0, 8, 0, 0, 8, 128, 0, 8, 64, 0, 9, 225, 80, 7, 6, 0, 8, 88, 0, 8, 24, 0, 9, 145, 83, 7, 59, 0, 8, 120, 0, 8, 56, 0, 9, 209, 81, 7, 17, 0, 8, 104, 0, 8, 40, 0, 9, 177, 0, 8, 8, 0, 8, 136, 0, 8, 72, 0, 9, 241, 80, 7, 4, 0, 8, 84, 0, 8, 20, 85, 8, 227, 83, 7, 43, 0, 8, 116, 0, 8, 52, 0, 9, 201, 81, 7, 13, 0, 8, 100, 0, 8, 36, 0, 9, 169, 0, 8, 4, 0, 8, 132, 0, 8, 68, 0, 9, 233, 80, 7, 8, 0, 8, 92, 0, 8, 28, 0, 9, 153, 84, 7, 83, 0, 8, 124, 0, 8, 60, 0, 9, 217, 82, 7, 23, 0, 8, 108, 0, 8, 44, 0, 9, 185, 0, 8, 12, 0, 8, 140, 0, 8, 76, 0, 9, 249, 80, 7, 3, 0, 8, 82, 0, 8, 18, 85, 8, 163, 83, 7, 35, 0, 8, 114, 0, 8, 50, 0, 9, 197, 81, 7, 11, 0, 8, 98, 0, 8, 34, 0, 9, 165, 0, 8, 2, 0, 8, 130, 0, 8, 66, 0, 9, 229, 80, 7, 7, 0, 8, 90, 0, 8, 26, 0, 9, 149, 84, 7, 67, 0, 8, 122, 0, 8, 58, 0, 9, 213, 82, 7, 19, 0, 8, 106, 0, 8, 42, 0, 9, 181, 0, 8, 10, 0, 8, 138, 0, 8, 74, 0, 9, 245, 80, 7, 5, 0, 8, 86, 0, 8, 22, 192, 8, 0, 83, 7, 51, 0, 8, 118, 0, 8, 54, 0, 9, 205, 81, 7, 15, 0, 8, 102, 0, 8, 38, 0, 9, 173, 0, 8, 6, 0, 8, 134, 0, 8, 70, 0, 9, 237, 80, 7, 9, 0, 8, 94, 0, 8, 30, 0, 9, 157, 84, 7, 99, 0, 8, 126, 0, 8, 62, 0, 9, 221, 82, 7, 27, 0, 8, 110, 0, 8, 46, 0, 9, 189, 0, 8, 14, 0, 8, 142, 0, 8, 78, 0, 9, 253, 96, 7, 256, 0, 8, 81, 0, 8, 17, 85, 8, 131, 82, 7, 31, 0, 8, 113, 0, 8, 49, 0, 9, 195, 80, 7, 10, 0, 8, 97, 0, 8, 33, 0, 9, 163, 0, 8, 1, 0, 8, 129, 0, 8, 65, 0, 9, 227, 80, 7, 6, 0, 8, 89, 0, 8, 25, 0, 9, 147, 83, 7, 59, 0, 8, 121, 0, 8, 57, 0, 9, 211, 81, 7, 17, 0, 8, 105, 0, 8, 41, 0, 9, 179, 0, 8, 9, 0, 8, 137, 0, 8, 73, 0, 9, 243, 80, 7, 4, 0, 8, 85, 0, 8, 21, 80, 8, 258, 83, 7, 43, 0, 8, 117, 0, 8, 53, 0, 9, 203, 81, 7, 13, 0, 8, 101, 0, 8, 37, 0, 9, 171, 0, 8, 5, 0, 8, 133, 0, 8, 69, 0, 9, 235, 80, 7, 8, 0, 8, 93, 0, 8, 29, 0, 9, 155, 84, 7, 83, 0, 8, 125, 0, 8, 61, 0, 9, 219, 82, 7, 23, 0, 8, 109, 0, 8, 45, 0, 9, 187, 0, 8, 13, 0, 8, 141, 0, 8, 77, 0, 9, 251, 80, 7, 3, 0, 8, 83, 0, 8, 19, 85, 8, 195, 83, 7, 35, 0, 8, 115, 0, 8, 51, 0, 9, 199, 81, 7, 11, 0, 8, 99, 0, 8, 35, 0, 9, 167, 0, 8, 3, 0, 8, 131, 0, 8, 67, 0, 9, 231, 80, 7, 7, 0, 8, 91, 0, 8, 27, 0, 9, 151, 84, 7, 67, 0, 8, 123, 0, 8, 59, 0, 9, 215, 82, 7, 19, 0, 8, 107, 0, 8, 43, 0, 9, 183, 0, 8, 11, 0, 8, 139, 0, 8, 75, 0, 9, 247, 80, 7, 5, 0, 8, 87, 0, 8, 23, 192, 8, 0, 83, 7, 51, 0, 8, 119, 0, 8, 55, 0, 9, 207, 81, 7, 15, 0, 8, 103, 0, 8, 39, 0, 9, 175, 0, 8, 7, 0, 8, 135, 0, 8, 71, 0, 9, 239, 80, 7, 9, 0, 8, 95, 0, 8, 31, 0, 9, 159, 84, 7, 99, 0, 8, 127, 0, 8, 63, 0, 9, 223, 82, 7, 27, 0, 8, 111, 0, 8, 47, 0, 9, 191, 0, 8, 15, 0, 8, 143, 0, 8, 79, 0, 9, 255];
      f = [80, 5, 1, 87, 5, 257, 83, 5, 17, 91, 5, 4097, 81, 5, 5, 89, 5, 1025, 85, 5, 65, 93, 5, 16385, 80, 5, 3, 88, 5, 513, 84, 5, 33, 92, 5, 8193, 82, 5, 9, 90, 5, 2049, 86, 5, 129, 192, 5, 24577, 80, 5, 2, 87, 5, 385, 83, 5, 25, 91, 5, 6145, 81, 5, 7, 89, 5, 1537, 85, 5, 97, 93, 5, 24577, 80, 5, 4, 88, 5, 769, 84, 5, 49, 92, 5, 12289, 82, 5, 13, 90, 5, 3073, 86, 5, 193, 192, 5, 24577];
      _ = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0];
      h = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 112, 112];
      w = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
      b = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
      p = 15;
      m.inflate_trees_fixed = function(t2, n2, i2, r2) {
        return t2[0] = 9, n2[0] = 5, i2[0] = d, r2[0] = f, e;
      };
      g = 0;
      y = 1;
      x = 2;
      k = 3;
      v = 4;
      S = 5;
      z = 6;
      A = 7;
      U = 8;
      D = 9;
      F = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
      T = 0;
      O = 1;
      C = 2;
      W = 3;
      j = 4;
      M = 5;
      L = 6;
      R = 7;
      B = 8;
      I = 9;
      P = 32;
      V = 8;
      q = 0;
      H = 1;
      K = 2;
      Z = 3;
      G = 4;
      J = 5;
      Q = 6;
      X = 7;
      Y = 12;
      $ = 13;
      ee = [0, 0, 255, 255];
      ne.prototype = { inflateInit(e2) {
        const t2 = this;
        return t2.istate = new te(), e2 || (e2 = 15), t2.istate.inflateInit(t2, e2);
      }, inflate(e2) {
        const t2 = this;
        return t2.istate ? t2.istate.inflate(t2, e2) : i;
      }, inflateEnd() {
        const e2 = this;
        if (!e2.istate) return i;
        const t2 = e2.istate.inflateEnd(e2);
        return e2.istate = null, t2;
      }, inflateSync() {
        const e2 = this;
        return e2.istate ? e2.istate.inflateSync(e2) : i;
      }, inflateSetDictionary(e2, t2) {
        const n2 = this;
        return n2.istate ? n2.istate.inflateSetDictionary(n2, e2, t2) : i;
      }, read_byte(e2) {
        return this.next_in[e2];
      }, read_buf(e2, t2) {
        return this.next_in.subarray(e2, e2 + t2);
      } };
      ie = 4294967295;
      re = 65535;
      ae = 33639248;
      se = 101075792;
      oe = 1;
      le = 39169;
      ce = 10;
      ue = 1;
      de = 21589;
      fe = 28789;
      _e = 25461;
      he = 1;
      we = 6;
      be = 8;
      pe = 2048;
      me = void 0;
      ge = "undefined";
      ye = "function";
      xe = class {
        constructor(e2) {
          return class extends TransformStream {
            constructor(t2, n2) {
              const i2 = new e2(n2);
              super({ transform(e3, t3) {
                t3.enqueue(i2.append(e3));
              }, flush(e3) {
                const t3 = i2.flush();
                t3 && e3.enqueue(t3);
              } });
            }
          };
        }
      };
      ke = 64;
      ve = 2;
      try {
        typeof navigator != ge && navigator.hardwareConcurrency && (ve = navigator.hardwareConcurrency);
      } catch (e2) {
      }
      Se = { chunkSize: 524288, maxWorkers: ve, terminateWorkerTimeout: 5e3, useWebWorkers: true, useCompressionStream: true, workerScripts: me, CompressionStreamNative: typeof CompressionStream != ge && CompressionStream, DecompressionStreamNative: typeof DecompressionStream != ge && DecompressionStream };
      ze = Object.assign({}, Se);
      De = [];
      for (let e2 = 0; e2 < 256; e2++) {
        let t2 = e2;
        for (let e3 = 0; e3 < 8; e3++) 1 & t2 ? t2 = t2 >>> 1 ^ 3988292384 : t2 >>>= 1;
        De[e2] = t2;
      }
      Ee = class {
        constructor(e2) {
          this.crc = e2 || -1;
        }
        append(e2) {
          let t2 = 0 | this.crc;
          for (let n2 = 0, i2 = 0 | e2.length; n2 < i2; n2++) t2 = t2 >>> 8 ^ De[255 & (t2 ^ e2[n2])];
          this.crc = t2;
        }
        get() {
          return ~this.crc;
        }
      };
      Fe = class extends TransformStream {
        constructor() {
          const e2 = new Ee();
          super({ transform(t2) {
            e2.append(t2);
          }, flush(t2) {
            const n2 = new Uint8Array(4);
            new DataView(n2.buffer).setUint32(0, e2.get()), t2.enqueue(n2);
          } });
        }
      };
      Te = { concat(e2, t2) {
        if (0 === e2.length || 0 === t2.length) return e2.concat(t2);
        const n2 = e2[e2.length - 1], i2 = Te.getPartial(n2);
        return 32 === i2 ? e2.concat(t2) : Te._shiftRight(t2, i2, 0 | n2, e2.slice(0, e2.length - 1));
      }, bitLength(e2) {
        const t2 = e2.length;
        if (0 === t2) return 0;
        const n2 = e2[t2 - 1];
        return 32 * (t2 - 1) + Te.getPartial(n2);
      }, clamp(e2, t2) {
        if (32 * e2.length < t2) return e2;
        const n2 = (e2 = e2.slice(0, Math.ceil(t2 / 32))).length;
        return t2 &= 31, n2 > 0 && t2 && (e2[n2 - 1] = Te.partial(t2, e2[n2 - 1] & 2147483648 >> t2 - 1, 1)), e2;
      }, partial: (e2, t2, n2) => 32 === e2 ? t2 : (n2 ? 0 | t2 : t2 << 32 - e2) + 1099511627776 * e2, getPartial: (e2) => Math.round(e2 / 1099511627776) || 32, _shiftRight(e2, t2, n2, i2) {
        for (void 0 === i2 && (i2 = []); t2 >= 32; t2 -= 32) i2.push(n2), n2 = 0;
        if (0 === t2) return i2.concat(e2);
        for (let r3 = 0; r3 < e2.length; r3++) i2.push(n2 | e2[r3] >>> t2), n2 = e2[r3] << 32 - t2;
        const r2 = e2.length ? e2[e2.length - 1] : 0, a2 = Te.getPartial(r2);
        return i2.push(Te.partial(t2 + a2 & 31, t2 + a2 > 32 ? n2 : i2.pop(), 1)), i2;
      } };
      Oe = { bytes: { fromBits(e2) {
        const t2 = Te.bitLength(e2) / 8, n2 = new Uint8Array(t2);
        let i2;
        for (let r2 = 0; r2 < t2; r2++) 0 == (3 & r2) && (i2 = e2[r2 / 4]), n2[r2] = i2 >>> 24, i2 <<= 8;
        return n2;
      }, toBits(e2) {
        const t2 = [];
        let n2, i2 = 0;
        for (n2 = 0; n2 < e2.length; n2++) i2 = i2 << 8 | e2[n2], 3 == (3 & n2) && (t2.push(i2), i2 = 0);
        return 3 & n2 && t2.push(Te.partial(8 * (3 & n2), i2)), t2;
      } } };
      Ce = { sha1: class {
        constructor(e2) {
          const t2 = this;
          t2.blockSize = 512, t2._init = [1732584193, 4023233417, 2562383102, 271733878, 3285377520], t2._key = [1518500249, 1859775393, 2400959708, 3395469782], e2 ? (t2._h = e2._h.slice(0), t2._buffer = e2._buffer.slice(0), t2._length = e2._length) : t2.reset();
        }
        reset() {
          const e2 = this;
          return e2._h = e2._init.slice(0), e2._buffer = [], e2._length = 0, e2;
        }
        update(e2) {
          const t2 = this;
          "string" == typeof e2 && (e2 = Oe.utf8String.toBits(e2));
          const n2 = t2._buffer = Te.concat(t2._buffer, e2), i2 = t2._length, r2 = t2._length = i2 + Te.bitLength(e2);
          if (r2 > 9007199254740991) throw new Error("Cannot hash more than 2^53 - 1 bits");
          const a2 = new Uint32Array(n2);
          let s2 = 0;
          for (let e3 = t2.blockSize + i2 - (t2.blockSize + i2 & t2.blockSize - 1); e3 <= r2; e3 += t2.blockSize) t2._block(a2.subarray(16 * s2, 16 * (s2 + 1))), s2 += 1;
          return n2.splice(0, 16 * s2), t2;
        }
        finalize() {
          const e2 = this;
          let t2 = e2._buffer;
          const n2 = e2._h;
          t2 = Te.concat(t2, [Te.partial(1, 1)]);
          for (let e3 = t2.length + 2; 15 & e3; e3++) t2.push(0);
          for (t2.push(Math.floor(e2._length / 4294967296)), t2.push(0 | e2._length); t2.length; ) e2._block(t2.splice(0, 16));
          return e2.reset(), n2;
        }
        _f(e2, t2, n2, i2) {
          return e2 <= 19 ? t2 & n2 | ~t2 & i2 : e2 <= 39 ? t2 ^ n2 ^ i2 : e2 <= 59 ? t2 & n2 | t2 & i2 | n2 & i2 : e2 <= 79 ? t2 ^ n2 ^ i2 : void 0;
        }
        _S(e2, t2) {
          return t2 << e2 | t2 >>> 32 - e2;
        }
        _block(e2) {
          const t2 = this, n2 = t2._h, i2 = Array(80);
          for (let t3 = 0; t3 < 16; t3++) i2[t3] = e2[t3];
          let r2 = n2[0], a2 = n2[1], s2 = n2[2], o2 = n2[3], l2 = n2[4];
          for (let e3 = 0; e3 <= 79; e3++) {
            e3 >= 16 && (i2[e3] = t2._S(1, i2[e3 - 3] ^ i2[e3 - 8] ^ i2[e3 - 14] ^ i2[e3 - 16]));
            const n3 = t2._S(5, r2) + t2._f(e3, a2, s2, o2) + l2 + i2[e3] + t2._key[Math.floor(e3 / 20)] | 0;
            l2 = o2, o2 = s2, s2 = t2._S(30, a2), a2 = r2, r2 = n3;
          }
          n2[0] = n2[0] + r2 | 0, n2[1] = n2[1] + a2 | 0, n2[2] = n2[2] + s2 | 0, n2[3] = n2[3] + o2 | 0, n2[4] = n2[4] + l2 | 0;
        }
      } };
      We = { aes: class {
        constructor(e2) {
          const t2 = this;
          t2._tables = [[[], [], [], [], []], [[], [], [], [], []]], t2._tables[0][0][0] || t2._precompute();
          const n2 = t2._tables[0][4], i2 = t2._tables[1], r2 = e2.length;
          let a2, s2, o2, l2 = 1;
          if (4 !== r2 && 6 !== r2 && 8 !== r2) throw new Error("invalid aes key size");
          for (t2._key = [s2 = e2.slice(0), o2 = []], a2 = r2; a2 < 4 * r2 + 28; a2++) {
            let e3 = s2[a2 - 1];
            (a2 % r2 == 0 || 8 === r2 && a2 % r2 == 4) && (e3 = n2[e3 >>> 24] << 24 ^ n2[e3 >> 16 & 255] << 16 ^ n2[e3 >> 8 & 255] << 8 ^ n2[255 & e3], a2 % r2 == 0 && (e3 = e3 << 8 ^ e3 >>> 24 ^ l2 << 24, l2 = l2 << 1 ^ 283 * (l2 >> 7))), s2[a2] = s2[a2 - r2] ^ e3;
          }
          for (let e3 = 0; a2; e3++, a2--) {
            const t3 = s2[3 & e3 ? a2 : a2 - 4];
            o2[e3] = a2 <= 4 || e3 < 4 ? t3 : i2[0][n2[t3 >>> 24]] ^ i2[1][n2[t3 >> 16 & 255]] ^ i2[2][n2[t3 >> 8 & 255]] ^ i2[3][n2[255 & t3]];
          }
        }
        encrypt(e2) {
          return this._crypt(e2, 0);
        }
        decrypt(e2) {
          return this._crypt(e2, 1);
        }
        _precompute() {
          const e2 = this._tables[0], t2 = this._tables[1], n2 = e2[4], i2 = t2[4], r2 = [], a2 = [];
          let s2, o2, l2, c2;
          for (let e3 = 0; e3 < 256; e3++) a2[(r2[e3] = e3 << 1 ^ 283 * (e3 >> 7)) ^ e3] = e3;
          for (let u2 = s2 = 0; !n2[u2]; u2 ^= o2 || 1, s2 = a2[s2] || 1) {
            let a3 = s2 ^ s2 << 1 ^ s2 << 2 ^ s2 << 3 ^ s2 << 4;
            a3 = a3 >> 8 ^ 255 & a3 ^ 99, n2[u2] = a3, i2[a3] = u2, c2 = r2[l2 = r2[o2 = r2[u2]]];
            let d2 = 16843009 * c2 ^ 65537 * l2 ^ 257 * o2 ^ 16843008 * u2, f2 = 257 * r2[a3] ^ 16843008 * a3;
            for (let n3 = 0; n3 < 4; n3++) e2[n3][u2] = f2 = f2 << 24 ^ f2 >>> 8, t2[n3][a3] = d2 = d2 << 24 ^ d2 >>> 8;
          }
          for (let n3 = 0; n3 < 5; n3++) e2[n3] = e2[n3].slice(0), t2[n3] = t2[n3].slice(0);
        }
        _crypt(e2, t2) {
          if (4 !== e2.length) throw new Error("invalid aes block size");
          const n2 = this._key[t2], i2 = n2.length / 4 - 2, r2 = [0, 0, 0, 0], a2 = this._tables[t2], s2 = a2[0], o2 = a2[1], l2 = a2[2], c2 = a2[3], u2 = a2[4];
          let d2, f2, _2, h2 = e2[0] ^ n2[0], w2 = e2[t2 ? 3 : 1] ^ n2[1], b2 = e2[2] ^ n2[2], p2 = e2[t2 ? 1 : 3] ^ n2[3], m2 = 4;
          for (let e3 = 0; e3 < i2; e3++) d2 = s2[h2 >>> 24] ^ o2[w2 >> 16 & 255] ^ l2[b2 >> 8 & 255] ^ c2[255 & p2] ^ n2[m2], f2 = s2[w2 >>> 24] ^ o2[b2 >> 16 & 255] ^ l2[p2 >> 8 & 255] ^ c2[255 & h2] ^ n2[m2 + 1], _2 = s2[b2 >>> 24] ^ o2[p2 >> 16 & 255] ^ l2[h2 >> 8 & 255] ^ c2[255 & w2] ^ n2[m2 + 2], p2 = s2[p2 >>> 24] ^ o2[h2 >> 16 & 255] ^ l2[w2 >> 8 & 255] ^ c2[255 & b2] ^ n2[m2 + 3], m2 += 4, h2 = d2, w2 = f2, b2 = _2;
          for (let e3 = 0; e3 < 4; e3++) r2[t2 ? 3 & -e3 : e3] = u2[h2 >>> 24] << 24 ^ u2[w2 >> 16 & 255] << 16 ^ u2[b2 >> 8 & 255] << 8 ^ u2[255 & p2] ^ n2[m2++], d2 = h2, h2 = w2, w2 = b2, b2 = p2, p2 = d2;
          return r2;
        }
      } };
      je = { getRandomValues(e2) {
        const t2 = new Uint32Array(e2.buffer), n2 = (e3) => {
          let t3 = 987654321;
          const n3 = 4294967295;
          return function() {
            t3 = 36969 * (65535 & t3) + (t3 >> 16) & n3;
            return (((t3 << 16) + (e3 = 18e3 * (65535 & e3) + (e3 >> 16) & n3) & n3) / 4294967296 + 0.5) * (Math.random() > 0.5 ? 1 : -1);
          };
        };
        for (let i2, r2 = 0; r2 < e2.length; r2 += 4) {
          const e3 = n2(4294967296 * (i2 || Math.random()));
          i2 = 987654071 * e3(), t2[r2 / 4] = 4294967296 * e3() | 0;
        }
        return e2;
      } };
      Me = { ctrGladman: class {
        constructor(e2, t2) {
          this._prf = e2, this._initIv = t2, this._iv = t2;
        }
        reset() {
          this._iv = this._initIv;
        }
        update(e2) {
          return this.calculate(this._prf, e2, this._iv);
        }
        incWord(e2) {
          if (255 == (e2 >> 24 & 255)) {
            let t2 = e2 >> 16 & 255, n2 = e2 >> 8 & 255, i2 = 255 & e2;
            255 === t2 ? (t2 = 0, 255 === n2 ? (n2 = 0, 255 === i2 ? i2 = 0 : ++i2) : ++n2) : ++t2, e2 = 0, e2 += t2 << 16, e2 += n2 << 8, e2 += i2;
          } else e2 += 1 << 24;
          return e2;
        }
        incCounter(e2) {
          0 === (e2[0] = this.incWord(e2[0])) && (e2[1] = this.incWord(e2[1]));
        }
        calculate(e2, t2, n2) {
          let i2;
          if (!(i2 = t2.length)) return [];
          const r2 = Te.bitLength(t2);
          for (let r3 = 0; r3 < i2; r3 += 4) {
            this.incCounter(n2);
            const i3 = e2.encrypt(n2);
            t2[r3] ^= i3[0], t2[r3 + 1] ^= i3[1], t2[r3 + 2] ^= i3[2], t2[r3 + 3] ^= i3[3];
          }
          return Te.clamp(t2, r2);
        }
      } };
      Le = { importKey: (e2) => new Le.hmacSha1(Oe.bytes.toBits(e2)), pbkdf2(e2, t2, n2, i2) {
        if (n2 = n2 || 1e4, i2 < 0 || n2 < 0) throw new Error("invalid params to pbkdf2");
        const r2 = 1 + (i2 >> 5) << 2;
        let a2, s2, o2, l2, c2;
        const u2 = new ArrayBuffer(r2), d2 = new DataView(u2);
        let f2 = 0;
        const _2 = Te;
        for (t2 = Oe.bytes.toBits(t2), c2 = 1; f2 < (r2 || 1); c2++) {
          for (a2 = s2 = e2.encrypt(_2.concat(t2, [c2])), o2 = 1; o2 < n2; o2++) for (s2 = e2.encrypt(s2), l2 = 0; l2 < s2.length; l2++) a2[l2] ^= s2[l2];
          for (o2 = 0; f2 < (r2 || 1) && o2 < a2.length; o2++) d2.setInt32(f2, a2[o2]), f2 += 4;
        }
        return u2.slice(0, i2 / 8);
      }, hmacSha1: class {
        constructor(e2) {
          const t2 = this, n2 = t2._hash = Ce.sha1, i2 = [[], []];
          t2._baseHash = [new n2(), new n2()];
          const r2 = t2._baseHash[0].blockSize / 32;
          e2.length > r2 && (e2 = new n2().update(e2).finalize());
          for (let t3 = 0; t3 < r2; t3++) i2[0][t3] = 909522486 ^ e2[t3], i2[1][t3] = 1549556828 ^ e2[t3];
          t2._baseHash[0].update(i2[0]), t2._baseHash[1].update(i2[1]), t2._resultHash = new n2(t2._baseHash[0]);
        }
        reset() {
          const e2 = this;
          e2._resultHash = new e2._hash(e2._baseHash[0]), e2._updated = false;
        }
        update(e2) {
          this._updated = true, this._resultHash.update(e2);
        }
        digest() {
          const e2 = this, t2 = e2._resultHash.finalize(), n2 = new e2._hash(e2._baseHash[1]).update(t2).finalize();
          return e2.reset(), n2;
        }
        encrypt(e2) {
          if (this._updated) throw new Error("encrypt on already updated hmac called!");
          return this.update(e2), this.digest(e2);
        }
      } };
      Re = "undefined" != typeof crypto && "function" == typeof crypto.getRandomValues;
      Be = "Invalid password";
      Ie = "Invalid signature";
      Pe = 16;
      Ve = "raw";
      qe = { name: "PBKDF2" };
      He = Object.assign({ hash: { name: "HMAC" } }, qe);
      Ke = Object.assign({ iterations: 1e3, hash: { name: "SHA-1" } }, qe);
      Ze = ["deriveBits"];
      Ge = [8, 12, 16];
      Je = [16, 24, 32];
      Qe = 10;
      Xe = [0, 0, 0, 0];
      Ye = "undefined";
      $e = "function";
      et = typeof crypto != Ye;
      tt = et && crypto.subtle;
      nt = et && typeof tt != Ye;
      it = Oe.bytes;
      rt = We.aes;
      at = Me.ctrGladman;
      st = Le.hmacSha1;
      ot = et && nt && typeof tt.importKey == $e;
      lt = et && nt && typeof tt.deriveBits == $e;
      ct = class extends TransformStream {
        constructor({ password: e2, signed: t2, encryptionStrength: n2 }) {
          super({ start() {
            Object.assign(this, { ready: new Promise(((e3) => this.resolveReady = e3)), password: e2, signed: t2, strength: n2 - 1, pending: new Uint8Array() });
          }, async transform(e3, t3) {
            const n3 = this, { password: i2, strength: r2, resolveReady: a2, ready: s2 } = n3;
            i2 ? (await (async function(e4, t4, n4, i3) {
              const r3 = await ft(e4, t4, n4, ht(i3, 0, Ge[t4])), a3 = ht(i3, Ge[t4]);
              if (r3[0] != a3[0] || r3[1] != a3[1]) throw new Error(Be);
            })(n3, r2, i2, ht(e3, 0, Ge[r2] + 2)), e3 = ht(e3, Ge[r2] + 2), a2()) : await s2;
            const o2 = new Uint8Array(e3.length - Qe - (e3.length - Qe) % Pe);
            t3.enqueue(dt(n3, e3, o2, 0, Qe, true));
          }, async flush(e3) {
            const { signed: t3, ctr: n3, hmac: i2, pending: r2, ready: a2 } = this;
            await a2;
            const s2 = ht(r2, 0, r2.length - Qe), o2 = ht(r2, r2.length - Qe);
            let l2 = new Uint8Array();
            if (s2.length) {
              const e4 = bt(it, s2);
              i2.update(e4);
              const t4 = n3.update(e4);
              l2 = wt(it, t4);
            }
            if (t3) {
              const e4 = ht(wt(it, i2.digest()), 0, Qe);
              for (let t4 = 0; t4 < Qe; t4++) if (e4[t4] != o2[t4]) throw new Error(Ie);
            }
            e3.enqueue(l2);
          } });
        }
      };
      ut = class extends TransformStream {
        constructor({ password: e2, encryptionStrength: t2 }) {
          let n2;
          super({ start() {
            Object.assign(this, { ready: new Promise(((e3) => this.resolveReady = e3)), password: e2, strength: t2 - 1, pending: new Uint8Array() });
          }, async transform(e3, t3) {
            const n3 = this, { password: i2, strength: r2, resolveReady: a2, ready: s2 } = n3;
            let o2 = new Uint8Array();
            i2 ? (o2 = await (async function(e4, t4, n4) {
              const i3 = Ne(new Uint8Array(Ge[t4])), r3 = await ft(e4, t4, n4, i3);
              return _t(i3, r3);
            })(n3, r2, i2), a2()) : await s2;
            const l2 = new Uint8Array(o2.length + e3.length - e3.length % Pe);
            l2.set(o2, 0), t3.enqueue(dt(n3, e3, l2, o2.length, 0));
          }, async flush(e3) {
            const { ctr: t3, hmac: i2, pending: r2, ready: a2 } = this;
            await a2;
            let s2 = new Uint8Array();
            if (r2.length) {
              const e4 = t3.update(bt(it, r2));
              i2.update(e4), s2 = wt(it, e4);
            }
            n2.signature = wt(it, i2.digest()).slice(0, Qe), e3.enqueue(_t(s2, n2.signature));
          } }), n2 = this;
        }
      };
      pt = 12;
      mt = class extends TransformStream {
        constructor({ password: e2, passwordVerification: t2 }) {
          super({ start() {
            Object.assign(this, { password: e2, passwordVerification: t2 }), kt(this, e2);
          }, transform(e3, t3) {
            const n2 = this;
            if (n2.password) {
              const t4 = yt(n2, e3.subarray(0, pt));
              if (n2.password = null, t4[11] != n2.passwordVerification) throw new Error(Be);
              e3 = e3.subarray(pt);
            }
            t3.enqueue(yt(n2, e3));
          } });
        }
      };
      gt = class extends TransformStream {
        constructor({ password: e2, passwordVerification: t2 }) {
          super({ start() {
            Object.assign(this, { password: e2, passwordVerification: t2 }), kt(this, e2);
          }, transform(e3, t3) {
            const n2 = this;
            let i2, r2;
            if (n2.password) {
              n2.password = null;
              const t4 = Ne(new Uint8Array(pt));
              t4[11] = n2.passwordVerification, i2 = new Uint8Array(e3.length + t4.length), i2.set(xt(n2, t4), 0), r2 = pt;
            } else i2 = new Uint8Array(e3.length), r2 = 0;
            i2.set(xt(n2, e3), r2), t3.enqueue(i2);
          } });
        }
      };
      Ut = "deflate-raw";
      Dt = class extends TransformStream {
        constructor(e2, { chunkSize: t2, CompressionStream: n2, CompressionStreamNative: i2 }) {
          super({});
          const { compressed: r2, encrypted: a2, useCompressionStream: s2, zipCrypto: o2, signed: l2, level: c2 } = e2, u2 = this;
          let d2, f2, _2 = Ft(super.readable);
          a2 && !o2 || !l2 || ([_2, d2] = _2.tee(), d2 = Ct(d2, new Fe())), r2 && (_2 = Ot(_2, s2, { level: c2, chunkSize: t2 }, i2, n2)), a2 && (o2 ? _2 = Ct(_2, new gt(e2)) : (f2 = new ut(e2), _2 = Ct(_2, f2))), Tt(u2, _2, (async () => {
            let e3;
            a2 && !o2 && (e3 = f2.signature), a2 && !o2 || !l2 || (e3 = await d2.getReader().read(), e3 = new DataView(e3.value.buffer).getUint32(0)), u2.signature = e3;
          }));
        }
      };
      Et = class extends TransformStream {
        constructor(e2, { chunkSize: t2, DecompressionStream: n2, DecompressionStreamNative: i2 }) {
          super({});
          const { zipCrypto: r2, encrypted: a2, signed: s2, signature: o2, compressed: l2, useCompressionStream: c2 } = e2;
          let u2, d2, f2 = Ft(super.readable);
          a2 && (r2 ? f2 = Ct(f2, new mt(e2)) : (d2 = new ct(e2), f2 = Ct(f2, d2))), l2 && (f2 = Ot(f2, c2, { chunkSize: t2 }, i2, n2)), a2 && !r2 || !s2 || ([f2, u2] = f2.tee(), u2 = Ct(u2, new Fe())), Tt(this, f2, (async () => {
            if ((!a2 || r2) && s2) {
              const e3 = await u2.getReader().read(), t3 = new DataView(e3.value.buffer);
              if (o2 != t3.getUint32(0, false)) throw new Error(Ie);
            }
          }));
        }
      };
      Wt = "message";
      jt = "start";
      Mt = "pull";
      Lt = "data";
      Rt = "ack";
      Bt = "close";
      It = "inflate";
      Nt = class extends TransformStream {
        constructor(e2, t2) {
          super({});
          const n2 = this, { codecType: i2 } = e2;
          let r2;
          i2.startsWith("deflate") ? r2 = Dt : i2.startsWith(It) && (r2 = Et);
          let a2 = 0;
          const s2 = new r2(e2, t2), o2 = super.readable, l2 = new TransformStream({ transform(e3, t3) {
            e3 && e3.length && (a2 += e3.length, t3.enqueue(e3));
          }, flush() {
            const { signature: e3 } = s2;
            Object.assign(n2, { signature: e3, size: a2 });
          } });
          Object.defineProperty(n2, "readable", { get: () => o2.pipeThrough(s2).pipeThrough(l2) });
        }
      };
      Pt = typeof Worker != ge;
      Vt = class {
        constructor(e2, { readable: t2, writable: n2 }, { options: i2, config: r2, streamOptions: a2, useWebWorkers: s2, transferStreams: o2, scripts: l2 }, c2) {
          const { signal: u2 } = a2;
          return Object.assign(e2, { busy: true, readable: t2.pipeThrough(new qt(t2, a2, r2), { signal: u2 }), writable: n2, options: Object.assign({}, i2), scripts: l2, transferStreams: o2, terminate() {
            const { worker: t3, busy: n3 } = e2;
            t3 && !n3 && (t3.terminate(), e2.interface = null);
          }, onTaskFinished() {
            e2.busy = false, c2(e2);
          } }), (s2 && Pt ? Zt : Kt)(e2, r2);
        }
      };
      qt = class extends TransformStream {
        constructor(e2, { onstart: t2, onprogress: n2, size: i2, onend: r2 }, { chunkSize: a2 }) {
          let s2 = 0;
          super({ start() {
            t2 && Ht(t2, i2);
          }, async transform(e3, t3) {
            s2 += e3.length, n2 && await Ht(n2, s2, i2), t3.enqueue(e3);
          }, flush() {
            e2.size = s2, r2 && Ht(r2, s2);
          } }, { highWaterMark: 1, size: () => a2 });
        }
      };
      Gt = true;
      Jt = true;
      Yt = [];
      $t = [];
      en = 0;
      nn = 65536;
      rn = "writable";
      an = class {
        constructor() {
          this.size = 0;
        }
        init() {
          this.initialized = true;
        }
      };
      sn = class extends an {
        get readable() {
          const e2 = this, { chunkSize: t2 = nn } = e2, n2 = new ReadableStream({ start() {
            this.chunkOffset = 0;
          }, async pull(i2) {
            const { offset: r2 = 0, size: a2, diskNumberStart: s2 } = n2, { chunkOffset: o2 } = this;
            i2.enqueue(await hn(e2, r2 + o2, Math.min(t2, a2 - o2), s2)), o2 + t2 > a2 ? i2.close() : this.chunkOffset += t2;
          } });
          return n2;
        }
      };
      on = class extends sn {
        constructor(e2) {
          super(), Object.assign(this, { blob: e2, size: e2.size });
        }
        async readUint8Array(e2, t2) {
          const n2 = this, i2 = e2 + t2, r2 = e2 || i2 < n2.size ? n2.blob.slice(e2, i2) : n2.blob;
          return new Uint8Array(await r2.arrayBuffer());
        }
      };
      ln = class extends an {
        constructor(e2) {
          super();
          const t2 = new TransformStream(), n2 = [];
          e2 && n2.push(["Content-Type", e2]), Object.defineProperty(this, rn, { get: () => t2.writable }), this.blob = new Response(t2.readable, { headers: n2 }).blob();
        }
        getData() {
          return this.blob;
        }
      };
      cn = class extends ln {
        constructor(e2) {
          super(e2), Object.assign(this, { encoding: e2, utf8: !e2 || "utf-8" == e2.toLowerCase() });
        }
        async getData() {
          const { encoding: e2, utf8: t2 } = this, n2 = await super.getData();
          if (n2.text && t2) return n2.text();
          {
            const t3 = new FileReader();
            return new Promise(((i2, r2) => {
              Object.assign(t3, { onload: ({ target: e3 }) => i2(e3.result), onerror: () => r2(t3.error) }), t3.readAsText(n2, e2);
            }));
          }
        }
      };
      un = class extends sn {
        constructor(e2) {
          super(), this.readers = e2;
        }
        async init() {
          const e2 = this, { readers: t2 } = e2;
          e2.lastDiskNumber = 0, await Promise.all(t2.map((async (t3) => {
            await t3.init(), e2.size += t3.size;
          }))), super.init();
        }
        async readUint8Array(e2, t2, n2 = 0) {
          const i2 = this, { readers: r2 } = this;
          let a2, s2 = n2;
          -1 == s2 && (s2 = r2.length - 1);
          let o2 = e2;
          for (; o2 >= r2[s2].size; ) o2 -= r2[s2].size, s2++;
          const l2 = r2[s2], c2 = l2.size;
          if (o2 + t2 <= c2) a2 = await hn(l2, o2, t2);
          else {
            const r3 = c2 - o2;
            a2 = new Uint8Array(t2), a2.set(await hn(l2, o2, r3)), a2.set(await i2.readUint8Array(e2 + r3, t2 - r3, n2), r3);
          }
          return i2.lastDiskNumber = Math.max(s2, i2.lastDiskNumber), a2;
        }
      };
      dn = class extends an {
        constructor(e2, t2 = 4294967295) {
          super();
          const n2 = this;
          let i2, r2, a2;
          Object.assign(n2, { diskNumber: 0, diskOffset: 0, size: 0, maxSize: t2, availableSize: t2 });
          const s2 = new WritableStream({ async write(t3) {
            const { availableSize: s3 } = n2;
            if (a2) t3.length >= s3 ? (await o2(t3.slice(0, s3)), await l2(), n2.diskOffset += i2.size, n2.diskNumber++, a2 = null, await this.write(t3.slice(s3))) : await o2(t3);
            else {
              const { value: s4, done: o3 } = await e2.next();
              if (o3 && !s4) throw new Error("Writer iterator completed too soon");
              i2 = s4, i2.size = 0, i2.maxSize && (n2.maxSize = i2.maxSize), n2.availableSize = n2.maxSize, await fn(i2), r2 = s4.writable, a2 = r2.getWriter(), await this.write(t3);
            }
          }, async close() {
            await a2.ready, await l2();
          } });
          async function o2(e3) {
            const t3 = e3.length;
            t3 && (await a2.ready, await a2.write(e3), i2.size += t3, n2.size += t3, n2.availableSize -= t3);
          }
          async function l2() {
            r2.size = i2.size, await a2.close();
          }
          Object.defineProperty(n2, rn, { get: () => s2 });
        }
      };
      wn = "\0\u263A\u263B\u2665\u2666\u2663\u2660\u2022\u25D8\u25CB\u25D9\u2642\u2640\u266A\u266B\u263C\u25BA\u25C4\u2195\u203C\xB6\xA7\u25AC\u21A8\u2191\u2193\u2192\u2190\u221F\u2194\u25B2\u25BC !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\u2302\xC7\xFC\xE9\xE2\xE4\xE0\xE5\xE7\xEA\xEB\xE8\xEF\xEE\xEC\xC4\xC5\xC9\xE6\xC6\xF4\xF6\xF2\xFB\xF9\xFF\xD6\xDC\xA2\xA3\xA5\u20A7\u0192\xE1\xED\xF3\xFA\xF1\xD1\xAA\xBA\xBF\u2310\xAC\xBD\xBC\xA1\xAB\xBB\u2591\u2592\u2593\u2502\u2524\u2561\u2562\u2556\u2555\u2563\u2551\u2557\u255D\u255C\u255B\u2510\u2514\u2534\u252C\u251C\u2500\u253C\u255E\u255F\u255A\u2554\u2569\u2566\u2560\u2550\u256C\u2567\u2568\u2564\u2565\u2559\u2558\u2552\u2553\u256B\u256A\u2518\u250C\u2588\u2584\u258C\u2590\u2580\u03B1\xDF\u0393\u03C0\u03A3\u03C3\xB5\u03C4\u03A6\u0398\u03A9\u03B4\u221E\u03C6\u03B5\u2229\u2261\xB1\u2265\u2264\u2320\u2321\xF7\u2248\xB0\u2219\xB7\u221A\u207F\xB2\u25A0 ".split("");
      bn = 256 == wn.length;
      mn = "filename";
      gn = "rawFilename";
      yn = "comment";
      xn = "rawComment";
      kn = "uncompressedSize";
      vn = "compressedSize";
      Sn = "offset";
      zn = "diskNumberStart";
      An = "lastModDate";
      Un = "rawLastModDate";
      Dn = "lastAccessDate";
      En = "rawLastAccessDate";
      Fn = "creationDate";
      Tn = "rawCreationDate";
      On = [mn, gn, vn, kn, An, Un, yn, xn, Dn, Fn, Sn, zn, zn, "internalFileAttribute", "externalFileAttribute", "msDosCompatible", "zip64", "directory", "bitFlag", "encrypted", "signature", "filenameUTF8", "commentUTF8", "compressionMethod", "version", "versionMadeBy", "extraField", "rawExtraField", "extraFieldZip64", "extraFieldUnicodePath", "extraFieldUnicodeComment", "extraFieldAES", "extraFieldNTFS", "extraFieldExtendedTimestamp"];
      Cn = class {
        constructor(e2) {
          On.forEach(((t2) => this[t2] = e2[t2]));
        }
      };
      Wn = "File format is not recognized";
      jn = "Zip64 extra field not found";
      Mn = "Compression method not supported";
      Ln = "Split zip file";
      Rn = "utf-8";
      Bn = "cp437";
      In = [[kn, ie], [vn, ie], [Sn, ie], [zn, re]];
      Nn = { [re]: { getValue: Yn, bytes: 4 }, [ie]: { getValue: $n, bytes: 8 } };
      Pn = class {
        constructor(e2, t2 = {}) {
          Object.assign(this, { reader: _n(e2), options: t2, config: ze });
        }
        async *getEntriesGenerator(e2 = {}) {
          const t2 = this;
          let { reader: n2 } = t2;
          const { config: i2 } = t2;
          if (await fn(n2), n2.size !== me && n2.readUint8Array || (n2 = new on(await new Response(n2.readable).blob()), await fn(n2)), n2.size < 22) throw new Error(Wn);
          n2.chunkSize = (function(e3) {
            return Math.max(e3.chunkSize, ke);
          })(i2);
          const r2 = await (async function(e3, t3, n3, i3, r3) {
            const a3 = new Uint8Array(4);
            !(function(e4, t4, n4) {
              e4.setUint32(t4, n4, true);
            })(ei(a3), 0, t3);
            const s3 = i3 + r3;
            return await o3(i3) || await o3(Math.min(s3, n3));
            async function o3(t4) {
              const r4 = n3 - t4, s4 = await hn(e3, r4, t4);
              for (let e4 = s4.length - i3; e4 >= 0; e4--) if (s4[e4] == a3[0] && s4[e4 + 1] == a3[1] && s4[e4 + 2] == a3[2] && s4[e4 + 3] == a3[3]) return { offset: r4 + e4, buffer: s4.slice(e4, e4 + i3).buffer };
            }
          })(n2, 101010256, n2.size, 22, 1048560);
          if (!r2) {
            throw 134695760 == Yn(ei(await hn(n2, 0, 4))) ? new Error(Ln) : new Error("End of central directory not found");
          }
          const a2 = ei(r2);
          let s2 = Yn(a2, 12), o2 = Yn(a2, 16);
          const l2 = r2.offset, c2 = Xn(a2, 20), u2 = l2 + 22 + c2;
          let d2 = Xn(a2, 4);
          const f2 = n2.lastDiskNumber || 0;
          let _2 = Xn(a2, 6), h2 = Xn(a2, 8), w2 = 0, b2 = 0;
          if (o2 == ie || s2 == ie || h2 == re || _2 == re) {
            const e3 = ei(await hn(n2, r2.offset - 20, 20));
            if (117853008 != Yn(e3, 0)) throw new Error("End of Zip64 central directory not found");
            o2 = $n(e3, 8);
            let t3 = await hn(n2, o2, 56, -1), i3 = ei(t3);
            const a3 = r2.offset - 20 - 56;
            if (Yn(i3, 0) != se && o2 != a3) {
              const e4 = o2;
              o2 = a3, w2 = o2 - e4, t3 = await hn(n2, o2, 56, -1), i3 = ei(t3);
            }
            if (Yn(i3, 0) != se) throw new Error("End of Zip64 central directory locator not found");
            d2 == re && (d2 = Yn(i3, 16)), _2 == re && (_2 = Yn(i3, 20)), h2 == re && (h2 = $n(i3, 32)), s2 == ie && (s2 = $n(i3, 40)), o2 -= s2;
          }
          if (f2 != d2) throw new Error(Ln);
          if (o2 < 0 || o2 >= n2.size) throw new Error(Wn);
          let p2 = 0, m2 = await hn(n2, o2, s2, _2), g2 = ei(m2);
          if (s2) {
            const e3 = r2.offset - s2;
            if (Yn(g2, p2) != ae && o2 != e3) {
              const t3 = o2;
              o2 = e3, w2 = o2 - t3, m2 = await hn(n2, o2, s2, _2), g2 = ei(m2);
            }
          }
          if (o2 < 0 || o2 >= n2.size) throw new Error(Wn);
          const y2 = Zn(t2, e2, "filenameEncoding"), x2 = Zn(t2, e2, "commentEncoding");
          for (let r3 = 0; r3 < h2; r3++) {
            const a3 = new Vn(n2, i2, t2.options);
            if (Yn(g2, p2) != ae) throw new Error("Central directory header not found");
            qn(a3, g2, p2 + 6);
            const s3 = Boolean(a3.bitFlag.languageEncodingFlag), o3 = p2 + 46, l3 = o3 + a3.filenameLength, c3 = l3 + a3.extraFieldLength, u3 = Xn(g2, p2 + 4), d3 = 0 == (0 & u3), f3 = m2.subarray(o3, l3), _3 = Xn(g2, p2 + 32), k3 = c3 + _3, v3 = m2.subarray(c3, k3), S2 = s3, z2 = s3, A2 = d3 && 16 == (16 & Qn(g2, p2 + 38)), U2 = Yn(g2, p2 + 42) + w2;
            Object.assign(a3, { versionMadeBy: u3, msDosCompatible: d3, compressedSize: 0, uncompressedSize: 0, commentLength: _3, directory: A2, offset: U2, diskNumberStart: Xn(g2, p2 + 34), internalFileAttribute: Xn(g2, p2 + 36), externalFileAttribute: Yn(g2, p2 + 38), rawFilename: f3, filenameUTF8: S2, commentUTF8: z2, rawExtraField: m2.subarray(l3, c3) });
            const [D2, E2] = await Promise.all([pn(f3, S2 ? Rn : y2 || Bn), pn(v3, z2 ? Rn : x2 || Bn)]);
            Object.assign(a3, { rawComment: v3, filename: D2, comment: E2, directory: A2 || D2.endsWith("/") }), b2 = Math.max(U2, b2), await Hn(a3, a3, g2, p2 + 6);
            const F2 = new Cn(a3);
            F2.getData = (e3, t3) => a3.getData(e3, F2, t3), p2 = k3;
            const { onprogress: T2 } = e2;
            if (T2) try {
              await T2(r3 + 1, h2, new Cn(a3));
            } catch (e3) {
            }
            yield F2;
          }
          const k2 = Zn(t2, e2, "extractPrependedData"), v2 = Zn(t2, e2, "extractAppendedData");
          return k2 && (t2.prependedData = b2 > 0 ? await hn(n2, 0, b2) : new Uint8Array()), t2.comment = c2 ? await hn(n2, l2 + 22, c2) : new Uint8Array(), v2 && (t2.appendedData = u2 < n2.size ? await hn(n2, u2, n2.size - u2) : new Uint8Array()), true;
        }
        async getEntries(e2 = {}) {
          const t2 = [];
          for await (const n2 of this.getEntriesGenerator(e2)) t2.push(n2);
          return t2;
        }
        async close() {
        }
      };
      Vn = class {
        constructor(e2, t2, n2) {
          Object.assign(this, { reader: e2, config: t2, options: n2 });
        }
        async getData(e2, t2, n2 = {}) {
          const i2 = this, { reader: r2, offset: a2, diskNumberStart: s2, extraFieldAES: o2, compressionMethod: l2, config: c2, bitFlag: u2, signature: d2, rawLastModDate: f2, uncompressedSize: _2, compressedSize: h2 } = i2, w2 = i2.localDirectory = {}, b2 = ei(await hn(r2, a2, 30, s2));
          let p2 = Zn(i2, n2, "password");
          if (p2 = p2 && p2.length && p2, o2 && 99 != o2.originalCompressionMethod) throw new Error(Mn);
          if (0 != l2 && 8 != l2) throw new Error(Mn);
          if (67324752 != Yn(b2, 0)) throw new Error("Local file header not found");
          qn(w2, b2, 4), w2.rawExtraField = w2.extraFieldLength ? await hn(r2, a2 + 30 + w2.filenameLength, w2.extraFieldLength, s2) : new Uint8Array(), await Hn(i2, w2, b2, 4), Object.assign(t2, { lastAccessDate: w2.lastAccessDate, creationDate: w2.creationDate });
          const m2 = i2.encrypted && w2.encrypted, g2 = m2 && !o2;
          if (m2) {
            if (!g2 && o2.strength === me) throw new Error("Encryption method not supported");
            if (!p2) throw new Error("File contains encrypted entry");
          }
          const y2 = a2 + 30 + w2.filenameLength + w2.extraFieldLength, x2 = r2.readable;
          x2.diskNumberStart = s2, x2.offset = y2;
          const k2 = x2.size = h2, v2 = Zn(i2, n2, "signal");
          e2 = (function(e3) {
            e3.writable === me && typeof e3.next == ye && (e3 = new dn(e3)), e3 instanceof WritableStream && (e3 = { writable: e3 });
            const { writable: t3 } = e3;
            return t3.size === me && (t3.size = 0), e3 instanceof dn || Object.assign(e3, { diskNumber: 0, diskOffset: 0, availableSize: 1 / 0, maxSize: 1 / 0 }), e3;
          })(e2), await fn(e2, _2);
          const { writable: S2 } = e2, { onstart: z2, onprogress: A2, onend: U2 } = n2, D2 = { options: { codecType: It, password: p2, zipCrypto: g2, encryptionStrength: o2 && o2.strength, signed: Zn(i2, n2, "checkSignature"), passwordVerification: g2 && (u2.dataDescriptor ? f2 >>> 8 & 255 : d2 >>> 24 & 255), signature: d2, compressed: 0 != l2, encrypted: m2, useWebWorkers: Zn(i2, n2, "useWebWorkers"), useCompressionStream: Zn(i2, n2, "useCompressionStream"), transferStreams: Zn(i2, n2, "transferStreams") }, config: c2, streamOptions: { signal: v2, size: k2, onstart: z2, onprogress: A2, onend: U2 } };
          S2.size += (await (async function(e3, t3) {
            const { options: n3, config: i3 } = t3, { transferStreams: r3, useWebWorkers: a3, useCompressionStream: s3, codecType: o3, compressed: l3, signed: c3, encrypted: u3 } = n3, { workerScripts: d3, maxWorkers: f3, terminateWorkerTimeout: _3 } = i3;
            t3.transferStreams = r3 || r3 === me;
            const h3 = !(l3 || c3 || u3 || t3.transferStreams);
            let w3;
            t3.useWebWorkers = !h3 && (a3 || a3 === me && i3.useWebWorkers), t3.scripts = t3.useWebWorkers && d3 ? d3[o3] : [], n3.useCompressionStream = s3 || s3 === me && i3.useCompressionStream;
            const b3 = Yt.find(((e4) => !e4.busy));
            if (b3) tn(b3), w3 = new Vt(b3, e3, t3, p3);
            else if (Yt.length < f3) {
              const n4 = { indexWorker: en };
              en++, Yt.push(n4), w3 = new Vt(n4, e3, t3, p3);
            } else w3 = await new Promise(((n4) => $t.push({ resolve: n4, stream: e3, workerOptions: t3 })));
            return w3.run();
            function p3(e4) {
              if ($t.length) {
                const [{ resolve: t4, stream: n4, workerOptions: i4 }] = $t.splice(0, 1);
                t4(new Vt(e4, n4, i4, p3));
              } else e4.worker ? (tn(e4), Number.isFinite(_3) && _3 >= 0 && (e4.terminateTimeout = setTimeout((() => {
                Yt = Yt.filter(((t4) => t4 != e4)), e4.terminate();
              }), _3))) : Yt = Yt.filter(((t4) => t4 != e4));
            }
          })({ readable: x2, writable: S2 }, D2)).size;
          return Zn(i2, n2, "preventClose") || await S2.close(), e2.getData ? e2.getData() : S2;
        }
      };
      Ae({ Inflate: function(n2) {
        const i2 = new ne(), r2 = n2 && n2.chunkSize ? Math.floor(2 * n2.chunkSize) : 131072, a2 = c, o2 = new Uint8Array(r2);
        let l2 = false;
        i2.inflateInit(), i2.next_out = o2, this.append = function(n3, c2) {
          const u2 = [];
          let d2, f2, _2 = 0, h2 = 0, w2 = 0;
          if (0 !== n3.length) {
            i2.next_in_index = 0, i2.next_in = n3, i2.avail_in = n3.length;
            do {
              if (i2.next_out_index = 0, i2.avail_out = r2, 0 !== i2.avail_in || l2 || (i2.next_in_index = 0, l2 = true), d2 = i2.inflate(a2), l2 && d2 === s) {
                if (0 !== i2.avail_in) throw new Error("inflating: bad input");
              } else if (d2 !== e && d2 !== t) throw new Error("inflating: " + i2.msg);
              if ((l2 || d2 === t) && i2.avail_in === n3.length) throw new Error("inflating: bad input");
              i2.next_out_index && (i2.next_out_index === r2 ? u2.push(new Uint8Array(o2)) : u2.push(o2.slice(0, i2.next_out_index))), w2 += i2.next_out_index, c2 && i2.next_in_index > 0 && i2.next_in_index != _2 && (c2(i2.next_in_index), _2 = i2.next_in_index);
            } while (i2.avail_in > 0 || 0 === i2.avail_out);
            return u2.length > 1 ? (f2 = new Uint8Array(w2), u2.forEach((function(e2) {
              f2.set(e2, h2), h2 += e2.length;
            }))) : f2 = u2[0] || new Uint8Array(), f2;
          }
        }, this.flush = function() {
          i2.inflateEnd();
        };
      } });
    }
  });

  // epub.js
  var epub_exports = {};
  __export(epub_exports, {
    EPUB: () => EPUB
  });
  var NS, MIME, camel, normalizeWhitespace2, filterAttribute, getAttributes, getElementText, childGetter, resolveURL, isExternal, pathRelative, pathDirname, replaceSeries, logEBookHTMLDiagnostic, parseParserErrorLocation, countTag, logParserErrorExcerpt, regexEscape, LANGS, ALTS, CONTRIB, METADATA, getMetadata, parseNav, parseNCX, parseClock, parseSMIL, isUUID, getUUID, getIdentifier, deobfuscate, WebCryptoSHA1, deobfuscators, Encryption, Resources, Loader, getHTMLFragment, getPageSpread, EPUB;
  var init_epub = __esm({
    "epub.js"() {
      init_epubcfi();
      NS = {
        CONTAINER: "urn:oasis:names:tc:opendocument:xmlns:container",
        XHTML: "http://www.w3.org/1999/xhtml",
        OPF: "http://www.idpf.org/2007/opf",
        EPUB: "http://www.idpf.org/2007/ops",
        DC: "http://purl.org/dc/elements/1.1/",
        DCTERMS: "http://purl.org/dc/terms/",
        ENC: "http://www.w3.org/2001/04/xmlenc#",
        NCX: "http://www.daisy.org/z3986/2005/ncx/",
        XLINK: "http://www.w3.org/1999/xlink",
        SMIL: "http://www.w3.org/ns/SMIL"
      };
      MIME = {
        XML: "application/xml",
        NCX: "application/x-dtbncx+xml",
        XHTML: "application/xhtml+xml",
        HTML: "text/html",
        CSS: "text/css",
        SVG: "image/svg+xml",
        JS: /\/(x-)?(javascript|ecmascript)/
      };
      camel = (x2) => x2.toLowerCase().replace(/[-:](.)/g, (_2, g2) => g2.toUpperCase());
      normalizeWhitespace2 = (str) => str ? str.replace(/[\t\n\f\r ]+/g, " ").replace(/^[\t\n\f\r ]+/, "").replace(/[\t\n\f\r ]+$/, "") : "";
      filterAttribute = (attr, value, isList) => isList ? (el) => el.getAttribute(attr)?.split(/\s/)?.includes(value) : typeof value === "function" ? (el) => value(el.getAttribute(attr)) : (el) => el.getAttribute(attr) === value;
      getAttributes = (...xs) => (el) => el ? Object.fromEntries(xs.map((x2) => [camel(x2), el.getAttribute(x2)])) : null;
      getElementText = (el) => normalizeWhitespace2(el?.textContent);
      childGetter = (doc, ns) => {
        const useNS = doc.lookupNamespaceURI(null) === ns || doc.lookupPrefix(ns);
        const f2 = useNS ? (el, name) => (el2) => el2.namespaceURI === ns && el2.localName === name : (el, name) => (el2) => el2.localName === name;
        return {
          $: (el, name) => [...el.children].find(f2(el, name)),
          $$: (el, name) => [...el.children].filter(f2(el, name)),
          $$$: useNS ? (el, name) => [...el.getElementsByTagNameNS(ns, name)] : (el, name) => [...el.getElementsByTagName(name)]
        };
      };
      resolveURL = (url, relativeTo) => {
        try {
          if (relativeTo.includes(":")) return new URL(url, relativeTo);
          const root = "https://invalid.invalid/";
          const obj = new URL(url, root + relativeTo);
          obj.search = "";
          return decodeURI(obj.href.replace(root, ""));
        } catch (e2) {
          console.warn(e2);
          return url;
        }
      };
      isExternal = (uri) => /^(?!blob)\w+:/i.test(uri);
      pathRelative = (from, to) => {
        if (!from) return to;
        const as = from.replace(/\/$/, "").split("/");
        const bs = to.replace(/\/$/, "").split("/");
        const i2 = (as.length > bs.length ? as : bs).findIndex((_2, i3) => as[i3] !== bs[i3]);
        return i2 < 0 ? "" : Array(as.length - i2).fill("..").concat(bs.slice(i2)).join("/");
      };
      pathDirname = (str) => str.slice(0, str.lastIndexOf("/") + 1);
      replaceSeries = async (str, regex, f2) => {
        const matches = [];
        str.replace(regex, (...args) => (matches.push(args), null));
        const results = [];
        for (const args of matches) results.push(await f2(...args));
        return str.replace(regex, () => results.shift());
      };
      logEBookHTMLDiagnostic = (detail = {}) => {
        const line = `# EBOOKHTML ${JSON.stringify(detail)}`;
        try {
          window.webkit?.messageHandlers?.print?.postMessage?.(line);
        } catch (_error) {
          try {
            console.log(line);
          } catch (_2) {
          }
        }
      };
      parseParserErrorLocation = (message = "") => {
        const lineMatch = message.match(/line\s+(\d+)/i);
        const columnMatch = message.match(/column\s+(\d+)/i);
        return {
          line: lineMatch ? Number.parseInt(lineMatch[1], 10) : null,
          column: columnMatch ? Number.parseInt(columnMatch[1], 10) : null
        };
      };
      countTag = (html, tagName) => {
        const escaped = tagName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const open = html.match(new RegExp(`<${escaped}(\\s|>|/)`, "gi"))?.length ?? 0;
        const close = html.match(new RegExp(`</${escaped}>`, "gi"))?.length ?? 0;
        return { open, close };
      };
      logParserErrorExcerpt = ({ href, mediaType, html, message, radius = 8 }) => {
        const { line, column } = parseParserErrorLocation(message);
        if (!line || !Number.isFinite(line)) {
          logEBookHTMLDiagnostic({
            stage: "js.epub.loadReplaced.parserError.noLineInfo",
            href,
            mediaType,
            message,
            length: html.length
          });
          return;
        }
        const lines = html.split(/\r?\n/);
        const lineCount = lines.length;
        const lineIndex = Math.max(0, Math.min(lineCount - 1, line - 1));
        const start = Math.max(0, lineIndex - radius);
        const end = Math.min(lineCount, lineIndex + radius + 1);
        const styleCount = countTag(html, "style");
        const numberCount = countTag(html, "number");
        logEBookHTMLDiagnostic({
          stage: "js.epub.loadReplaced.parserError.contextMeta",
          href,
          mediaType,
          message,
          errorLine: line,
          errorColumn: column,
          lineCount,
          excerptStartLine: start + 1,
          excerptEndLine: end,
          styleOpen: styleCount.open,
          styleClose: styleCount.close,
          numberOpen: numberCount.open,
          numberClose: numberCount.close
        });
        for (let idx = start; idx < end; idx += 1) {
          const rawLine = lines[idx] ?? "";
          const clipped = rawLine.length > 500 ? `${rawLine.slice(0, 500)}\u2026` : rawLine;
          logEBookHTMLDiagnostic({
            stage: "js.epub.loadReplaced.parserError.contextLine",
            href,
            mediaType,
            line: idx + 1,
            isErrorLine: idx === lineIndex,
            text: clipped
          });
        }
      };
      regexEscape = (str) => str.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&");
      LANGS = {
        attrs: ["dir", "xml:lang"]
      };
      ALTS = {
        name: "alternate-script",
        many: true,
        ...LANGS,
        props: ["file-as"]
      };
      CONTRIB = {
        many: true,
        ...LANGS,
        props: [{
          name: "role",
          many: true,
          attrs: ["scheme"]
        }, "file-as", ALTS]
      };
      METADATA = [
        {
          name: "title",
          many: true,
          ...LANGS,
          props: ["title-type", "display-seq", "file-as", ALTS]
        },
        {
          name: "identifier",
          many: true,
          props: [{
            name: "identifier-type",
            attrs: ["scheme"]
          }]
        },
        {
          name: "language",
          many: true
        },
        {
          name: "creator",
          ...CONTRIB
        },
        {
          name: "contributor",
          ...CONTRIB
        },
        {
          name: "publisher",
          ...LANGS,
          props: ["file-as", ALTS]
        },
        {
          name: "description",
          ...LANGS,
          props: [ALTS]
        },
        {
          name: "rights",
          ...LANGS,
          props: [ALTS]
        },
        {
          name: "date"
        },
        {
          name: "dcterms:modified",
          type: "meta"
        },
        {
          name: "subject",
          many: true,
          ...LANGS,
          props: ["term", "authority", ALTS]
        },
        {
          name: "belongs-to-collection",
          type: "meta",
          many: true,
          ...LANGS,
          props: [
            "collection-type",
            "group-position",
            "dcterms:identifier",
            "file-as",
            ALTS,
            {
              name: "belongs-to-collection",
              recursive: true
            }
          ]
        }
      ];
      getMetadata = (opf) => {
        const {
          $: $3,
          $$
        } = childGetter(opf, NS.OPF);
        const $metadata = $3(opf.documentElement, "metadata");
        const els = Array.from($metadata.children);
        const getValue = (obj, el) => {
          if (!el) return null;
          const {
            props = [],
            attrs = []
          } = obj;
          const value = getElementText(el);
          if (!props.length && !attrs.length) return value;
          const id = el.getAttribute("id");
          const refines = id ? els.filter(filterAttribute("refines", "#" + id)) : [];
          return Object.fromEntries([
            ["value", value]
          ].concat(props.map((prop) => {
            const {
              many,
              recursive
            } = prop;
            const name = typeof prop === "string" ? prop : prop.name;
            const filter = filterAttribute("property", name);
            const subobj = recursive ? obj : prop;
            return [
              camel(name),
              many ? refines.filter(filter).map((el2) => getValue(subobj, el2)) : getValue(subobj, refines.find(filter))
            ];
          })).concat(attrs.map((attr) => [camel(attr), el.getAttribute(attr)])));
        };
        const arr = els.filter(filterAttribute("refines", null));
        const metadata = Object.fromEntries(METADATA.map((obj) => {
          const {
            type,
            name,
            many
          } = obj;
          const filter = type === "meta" ? (el) => el.namespaceURI === NS.OPF && el.getAttribute("property") === name : (el) => el.namespaceURI === NS.DC && el.localName === name;
          return [
            camel(name),
            many ? arr.filter(filter).map((el) => getValue(obj, el)) : getValue(obj, arr.find(filter))
          ];
        }));
        const getProperties = (prefix) => Object.fromEntries($$($metadata, "meta").filter(filterAttribute("property", (x2) => x2?.startsWith(prefix))).map((el) => [
          el.getAttribute("property").replace(prefix, ""),
          getElementText(el)
        ]));
        const rendition = getProperties("rendition:");
        const media = getProperties("media:");
        return {
          metadata,
          rendition,
          media
        };
      };
      parseNav = (doc, resolve = (f2) => f2) => {
        const {
          $: $3,
          $$,
          $$$
        } = childGetter(doc, NS.XHTML);
        const resolveHref = (href) => href ? decodeURI(resolve(href)) : null;
        const parseLI = (getType) => ($li) => {
          const $a = $3($li, "a") ?? $3($li, "span");
          const $ol = $3($li, "ol");
          const href = resolveHref($a?.getAttribute("href"));
          const label = getElementText($a) || $a?.getAttribute("title");
          const result = {
            label,
            href,
            subitems: parseOL($ol)
          };
          if (getType) result.type = $a?.getAttributeNS(NS.EPUB, "type")?.split(/\s/);
          return result;
        };
        const parseOL = ($ol, getType) => $ol ? $$($ol, "li").map(parseLI(getType)) : null;
        const parseNav2 = ($nav, getType) => parseOL($3($nav, "ol"), getType);
        const $$nav = $$$(doc, "nav");
        let toc = null, pageList = null, landmarks = null, others = [];
        for (const $nav of $$nav) {
          const type = $nav.getAttributeNS(NS.EPUB, "type")?.split(/\s/) ?? [];
          if (type.includes("toc")) toc ??= parseNav2($nav);
          else if (type.includes("page-list")) pageList ??= parseNav2($nav);
          else if (type.includes("landmarks")) landmarks ??= parseNav2($nav, true);
          else others.push({
            label: getElementText($nav.firstElementChild),
            type,
            list: parseNav2($nav)
          });
        }
        return {
          toc,
          pageList,
          landmarks,
          others
        };
      };
      parseNCX = (doc, resolve = (f2) => f2) => {
        const {
          $: $3,
          $$
        } = childGetter(doc, NS.NCX);
        const resolveHref = (href) => href ? decodeURI(resolve(href)) : null;
        const parseItem = (el) => {
          const $label = $3(el, "navLabel");
          const $content = $3(el, "content");
          const label = getElementText($label);
          const href = resolveHref($content.getAttribute("src"));
          if (el.localName === "navPoint") {
            const els = $$(el, "navPoint");
            return {
              label,
              href,
              subitems: els.length ? els.map(parseItem) : null
            };
          }
          return {
            label,
            href
          };
        };
        const parseList = (el, itemName) => $$(el, itemName).map(parseItem);
        const getSingle = (container, itemName) => {
          const $container = $3(doc.documentElement, container);
          return $container ? parseList($container, itemName) : null;
        };
        return {
          toc: getSingle("navMap", "navPoint"),
          pageList: getSingle("pageList", "pageTarget"),
          others: $$(doc.documentElement, "navList").map((el) => ({
            label: getElementText($3(el, "navLabel")),
            list: parseList(el, "navTarget")
          }))
        };
      };
      parseClock = (str) => {
        if (!str) return;
        const parts = str.split(":").map((x3) => parseFloat(x3));
        if (parts.length === 3) {
          const [h2, m2, s2] = parts;
          return h2 * 60 * 60 + m2 * 60 + s2;
        }
        if (parts.length === 2) {
          const [m2, s2] = parts;
          return m2 * 60 + s2;
        }
        const [x2, unit] = str.split(/(?=[^\d.])/);
        const n2 = parseFloat(x2);
        const f2 = unit === "h" ? 60 * 60 : unit === "min" ? 60 : unit === "ms" ? 1e-3 : 1;
        return n2 * f2;
      };
      parseSMIL = (doc, resolve = (f2) => f2) => {
        const {
          $: $3,
          $$$
        } = childGetter(doc, NS.SMIL);
        const resolveHref = (href) => href ? decodeURI(resolve(href)) : null;
        return $$$(doc, "par").map(($par) => {
          const id = $3($par, "text")?.getAttribute("src")?.split("#")?.[1];
          const $audio = $3($par, "audio");
          return $audio ? {
            id,
            audio: {
              src: resolveHref($audio.getAttribute("src")),
              clipBegin: parseClock($audio.getAttribute("clipBegin")),
              clipEnd: parseClock($audio.getAttribute("clipEnd"))
            }
          } : {
            id
          };
        });
      };
      isUUID = /([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})/;
      getUUID = (opf) => {
        for (const el of opf.getElementsByTagNameNS(NS.DC, "identifier")) {
          const [id] = getElementText(el).split(":").slice(-1);
          if (isUUID.test(id)) return id;
        }
        return "";
      };
      getIdentifier = (opf) => getElementText(
        opf.getElementById(opf.documentElement.getAttribute("unique-identifier")) ?? opf.getElementsByTagNameNS(NS.DC, "identifier")[0]
      );
      deobfuscate = async (key, length, blob) => {
        const array = new Uint8Array(await blob.slice(0, length).arrayBuffer());
        length = Math.min(length, array.length);
        for (var i2 = 0; i2 < length; i2++) array[i2] = array[i2] ^ key[i2 % key.length];
        return new Blob([array, blob.slice(length)], {
          type: blob.type
        });
      };
      WebCryptoSHA1 = async (str) => {
        const data = new TextEncoder().encode(str);
        const buffer = await globalThis.crypto.subtle.digest("SHA-1", data);
        return new Uint8Array(buffer);
      };
      deobfuscators = (sha1 = WebCryptoSHA1) => ({
        "http://www.idpf.org/2008/embedding": {
          key: (opf) => sha1(getIdentifier(opf).replaceAll(/[\u0020\u0009\u000d\u000a]/g, "")),
          decode: (key, blob) => deobfuscate(key, 1040, blob)
        },
        "http://ns.adobe.com/pdf/enc#RC": {
          key: (opf) => {
            const uuid = getUUID(opf).replaceAll("-", "");
            return Uint8Array.from({
              length: 16
            }, (_2, i2) => parseInt(uuid.slice(i2 * 2, i2 * 2 + 2), 16));
          },
          decode: (key, blob) => deobfuscate(key, 1024, blob)
        }
      });
      Encryption = class {
        #uris = /* @__PURE__ */ new Map();
        #decoders = /* @__PURE__ */ new Map();
        #algorithms;
        constructor(algorithms) {
          this.#algorithms = algorithms;
        }
        async init(encryption, opf) {
          if (!encryption) return;
          const data = Array.from(
            encryption.getElementsByTagNameNS(NS.ENC, "EncryptedData"),
            (el) => ({
              algorithm: el.getElementsByTagNameNS(NS.ENC, "EncryptionMethod")[0]?.getAttribute("Algorithm"),
              uri: el.getElementsByTagNameNS(NS.ENC, "CipherReference")[0]?.getAttribute("URI")
            })
          );
          for (const {
            algorithm,
            uri
          } of data) {
            if (!this.#decoders.has(algorithm)) {
              const algo = this.#algorithms[algorithm];
              if (!algo) {
                console.warn("Unknown encryption algorithm");
                continue;
              }
              const key = await algo.key(opf);
              this.#decoders.set(algorithm, (blob) => algo.decode(key, blob));
            }
            this.#uris.set(uri, algorithm);
          }
        }
        getDecoder(uri) {
          return this.#decoders.get(this.#uris.get(uri)) ?? ((x2) => x2);
        }
      };
      Resources = class {
        constructor({
          opf,
          resolveHref
        }) {
          this.opf = opf;
          const {
            $: $3,
            $$,
            $$$
          } = childGetter(opf, NS.OPF);
          const $manifest = $3(opf.documentElement, "manifest");
          const $spine = $3(opf.documentElement, "spine");
          const $$itemref = $$($spine, "itemref");
          this.manifest = $$($manifest, "item").map(getAttributes("href", "id", "media-type", "properties", "media-overlay")).map((item) => {
            item.href = resolveHref(item.href);
            item.properties = item.properties?.split(/\s/);
            return item;
          });
          this.spine = $$itemref.map(getAttributes("idref", "id", "linear", "properties")).map((item) => (item.properties = item.properties?.split(/\s/), item));
          this.pageProgressionDirection = $spine.getAttribute("page-progression-direction");
          this.navPath = this.getItemByProperty("nav")?.href;
          this.ncxPath = (this.getItemByID($spine.getAttribute("toc")) ?? this.manifest.find((item) => item.mediaType === MIME.NCX))?.href;
          const $guide = $3(opf.documentElement, "guide");
          if ($guide) this.guide = $$($guide, "reference").map(getAttributes("type", "title", "href")).map(({
            type,
            title,
            href
          }) => ({
            label: title,
            type: type.split(/\s/),
            href: resolveHref(href)
          }));
          this.cover = this.getItemByProperty("cover-image") ?? this.getItemByID($$$(opf, "meta").find(filterAttribute("name", "cover"))?.getAttribute("content")) ?? this.getItemByHref(this.guide?.find((ref) => ref.type.includes("cover"))?.href);
          this.cfis = fromElements($$itemref);
        }
        getItemByID(id) {
          return this.manifest.find((item) => item.id === id);
        }
        getItemByHref(href) {
          return this.manifest.find((item) => item.href === href);
        }
        getItemByProperty(prop) {
          return this.manifest.find((item) => item.properties?.includes(prop));
        }
        resolveCFI(cfi) {
          const parts = parse(cfi);
          const top = (parts.parent ?? parts).shift();
          let $itemref = toElement(this.opf, top);
          if ($itemref && $itemref.nodeName !== "idref") {
            top.at(-1).id = null;
            $itemref = toElement(this.opf, top);
          }
          const idref = $itemref?.getAttribute("idref");
          const index = this.spine.findIndex((item) => item.idref === idref);
          const anchor = (doc) => toRange(doc, parts);
          return {
            index,
            anchor
          };
        }
      };
      Loader = class {
        #cache = /* @__PURE__ */ new Map();
        #children = /* @__PURE__ */ new Map();
        #refCount = /* @__PURE__ */ new Map();
        allowScript = false;
        constructor({
          loadText,
          loadBlob,
          resources,
          replaceText
        }) {
          this.loadText = loadText;
          this.loadBlob = loadBlob;
          this.manifest = resources.manifest;
          this.assets = resources.manifest;
          this.replaceText = replaceText;
        }
        createURL(href, data, type, parent) {
          if (!data) return "";
          const url = URL.createObjectURL(new Blob([data], {
            type
          }));
          this.#cache.set(href, url);
          this.#refCount.set(href, 1);
          if (parent) {
            const childList = this.#children.get(parent);
            if (childList) childList.push(href);
            else this.#children.set(parent, [href]);
          }
          return url;
        }
        ref(href, parent) {
          const childList = this.#children.get(parent);
          if (!childList?.includes(href)) {
            this.#refCount.set(href, this.#refCount.get(href) + 1);
            if (childList) childList.push(href);
            else this.#children.set(parent, [href]);
          }
          return this.#cache.get(href);
        }
        unref(href) {
          if (!this.#refCount.has(href)) return;
          const count = this.#refCount.get(href) - 1;
          if (count < 1) {
            URL.revokeObjectURL(this.#cache.get(href));
            this.#cache.delete(href);
            this.#refCount.delete(href);
            const childList = this.#children.get(href);
            if (childList)
              while (childList.length) this.unref(childList.pop());
            this.#children.delete(href);
          } else this.#refCount.set(href, count);
        }
        // load manifest item, recursively loading all resources as needed
        async loadItem(item, parents = []) {
          if (!item) return null;
          const {
            href,
            mediaType
          } = item;
          const isScript = MIME.JS.test(item.mediaType);
          if (isScript && !this.allowScript) return null;
          const parent = parents.at(-1);
          if (this.#cache.has(href)) return this.ref(href, parent);
          const shouldReplace = (isScript || [MIME.XHTML, MIME.HTML, MIME.CSS, MIME.SVG].includes(mediaType)) && parents.every((p2) => p2 !== href);
          if (shouldReplace) return this.loadReplaced(item, parents);
          return this.createURL(href, await this.loadBlob(href), mediaType, parent);
        }
        async loadHref(href, base, parents = []) {
          if (isExternal(href)) return href;
          const path = resolveURL(href, base);
          const item = this.manifest.find((item2) => item2.href === path);
          if (!item) return href;
          return this.loadItem(item, parents.concat(base));
        }
        async loadReplaced(item, parents = []) {
          const {
            href,
            mediaType
          } = item;
          const parent = parents.at(-1);
          globalThis.manabiLoadEBookLastState = `epub-loadreplaced-awaiting-text:${href}`;
          const str = await this.loadText(href);
          globalThis.manabiLoadEBookLastState = `epub-loadreplaced-text-ready:${href}`;
          if (!str) return null;
          let replacedStr = str;
          if (this.replaceText) {
            globalThis.manabiLoadEBookLastState = `epub-loadreplaced-awaiting-replace:${href}`;
            replacedStr = await this.replaceText(href, str, mediaType);
            globalThis.manabiLoadEBookLastState = `epub-loadreplaced-replace-ready:${href}`;
          }
          if (!replacedStr) {
            return null;
          }
          const shouldForceHTMLLogging = globalThis.manabiMaybeLogEBookHTML?.(
            "js.epub.loadReplaced.beforeDOMParser",
            {
              href,
              mediaType,
              html: replacedStr
            }
          ) === true;
          if (shouldForceHTMLLogging) {
            logEBookHTMLDiagnostic({
              stage: "js.epub.loadReplaced.segmentCount.raw",
              href,
              mediaType,
              segmentCount: (replacedStr.match(/<manabi-segment(\s|>)/g) || []).length,
              hasTrackingEnabledFlag: replacedStr.includes("data-manabi-tracking-enabled")
            });
          }
          if ([MIME.XHTML, MIME.HTML, MIME.SVG].includes(mediaType)) {
            globalThis.manabiLoadEBookLastState = `epub-loadreplaced-parsing-dom:${href}`;
            let doc = new DOMParser().parseFromString(replacedStr, mediaType);
            globalThis.manabiLoadEBookLastState = `epub-loadreplaced-dom-ready:${href}`;
            if (shouldForceHTMLLogging) {
              logEBookHTMLDiagnostic({
                stage: "js.epub.loadReplaced.segmentCount.parsed",
                href,
                mediaType,
                segmentCount: doc.querySelectorAll("manabi-segment").length,
                trackingEnabled: doc.body?.getAttribute?.("data-manabi-tracking-enabled") ?? null,
                bodyClass: doc.body?.getAttribute?.("class") ?? null
              });
            }
            const parserErrorNode = doc.querySelector("parsererror");
            if (mediaType === MIME.XHTML && parserErrorNode) {
              const parserErrorMessage = parserErrorNode.innerText;
              logEBookHTMLDiagnostic({
                stage: "js.epub.loadReplaced.parserError",
                href,
                mediaType,
                message: parserErrorMessage
              });
              logParserErrorExcerpt({
                href,
                mediaType,
                html: replacedStr,
                message: parserErrorMessage
              });
              globalThis.manabiMaybeLogEBookHTML?.(
                "js.epub.loadReplaced.parserErrorInput",
                {
                  href,
                  mediaType,
                  html: replacedStr,
                  force: true
                }
              );
              console.warn(parserErrorMessage);
              item.mediaType = MIME.HTML;
              doc = new DOMParser().parseFromString(replacedStr, item.mediaType);
            }
            if ([MIME.XHTML, MIME.SVG].includes(item.mediaType)) {
              let child = doc.firstChild;
              while (child instanceof ProcessingInstruction) {
                if (child.data) {
                  const replacedData = await replaceSeries(
                    child.data,
                    /(?:^|\s*)(href\s*=\s*['"])([^'"]*)(['"])/i,
                    (_2, p1, p2, p3) => this.loadHref(p2, href, parents).then((p22) => `${p1}${p22}${p3}`)
                  );
                  child.replaceWith(doc.createProcessingInstruction(
                    child.target,
                    replacedData
                  ));
                }
                child = child.nextSibling;
              }
            }
            const replace = async (el, attr) => el.setAttribute(
              attr,
              await this.loadHref(el.getAttribute(attr), href, parents)
            );
            for (const el of doc.querySelectorAll("link[href]")) await replace(el, "href");
            for (const el of doc.querySelectorAll("[src]")) await replace(el, "src");
            for (const el of doc.querySelectorAll("[poster]")) await replace(el, "poster");
            for (const el of doc.querySelectorAll("object[data]")) await replace(el, "data");
            for (const el of doc.querySelectorAll("[*|href]:not([href])")) {
              el.setAttributeNS(NS.XLINK, "href", await this.loadHref(el.getAttributeNS(NS.XLINK, "href"), href, parents));
            }
            for (const el of doc.querySelectorAll("[srcset]")) {
              el.setAttribute("srcset", await replaceSeries(
                el.getAttribute("srcset"),
                /(\s*)(.+?)\s*((?:\s[\d.]+[wx])+\s*(?:,|$)|,\s+|$)/g,
                (_2, p1, p2, p3) => this.loadHref(p2, href, parents).then((p22) => `${p1}${p22}${p3}`)
              ));
            }
            for (const el of doc.getElementsByTagName("style"))
              if (el.textContent) el.textContent = await this.replaceCSS(el.textContent, href, parents);
            for (const el of doc.querySelectorAll("[style]"))
              el.setAttribute(
                "style",
                await this.replaceCSS(el.getAttribute("style"), href, parents)
              );
            const textResult = new XMLSerializer().serializeToString(doc);
            if (shouldForceHTMLLogging) {
              logEBookHTMLDiagnostic({
                stage: "js.epub.loadReplaced.segmentCount.serialized",
                href,
                mediaType: item.mediaType,
                segmentCount: (textResult.match(/<manabi-segment(\s|>)/g) || []).length,
                hasTrackingEnabledFlag: textResult.includes("data-manabi-tracking-enabled")
              });
            }
            globalThis.manabiMaybeLogEBookHTML?.("js.epub.loadReplaced.afterSerialize", {
              href,
              mediaType: item.mediaType,
              html: textResult,
              force: shouldForceHTMLLogging
            });
            return this.createURL(href, textResult, item.mediaType, parent);
          }
          const result = mediaType === MIME.CSS ? await this.replaceCSS(replacedStr, href, parents) : await this.replaceString(replacedStr, href, parents);
          return this.createURL(href, result, mediaType, parent);
        }
        async replaceCSS(str, href, parents = []) {
          const replacedUrls = await replaceSeries(
            str,
            /url\(\s*["']?([^'"\n]*?)\s*["']?\s*\)/gi,
            (_2, url) => this.loadHref(url, href, parents).then((url2) => `url("${url2}")`)
          );
          const replacedImports = await replaceSeries(
            replacedUrls,
            /@import\s*["']([^"'\n]*?)["']/gi,
            (_2, url) => this.loadHref(url, href, parents).then((url2) => `@import "${url2}"`)
          );
          const w2 = window?.innerWidth ?? 800;
          const h2 = window?.innerHeight ?? 600;
          return replacedImports.replace(/-epub-/gi, "").replace(/(\d*\.?\d+)vw/gi, (_2, d2) => parseFloat(d2) * w2 / 100 + "px").replace(/(\d*\.?\d+)vh/gi, (_2, d2) => parseFloat(d2) * h2 / 100 + "px").replace(/page-break-(after|before|inside)/gi, (_2, x2) => `-webkit-column-break-${x2}`);
        }
        // find & replace all possible relative paths for all assets without parsing
        replaceString(str, href, parents = []) {
          const assetMap = /* @__PURE__ */ new Map();
          const urls = this.assets.map((asset) => {
            if (asset.href === href) return;
            const relative = pathRelative(pathDirname(href), asset.href);
            const relativeEnc = encodeURI(relative);
            const rootRelative = "/" + asset.href;
            const rootRelativeEnc = encodeURI(rootRelative);
            const set = /* @__PURE__ */ new Set([relative, relativeEnc, rootRelative, rootRelativeEnc]);
            for (const url of set) assetMap.set(url, asset);
            return Array.from(set);
          }).flat().filter((x2) => x2);
          if (!urls.length) return str;
          const regex = new RegExp(urls.map(regexEscape).join("|"), "g");
          return replaceSeries(str, regex, async (match) => this.loadItem(
            assetMap.get(match.replace(/^\//, "")),
            parents.concat(href)
          ));
        }
        unloadItem(item) {
          this.unref(item?.href);
        }
        destroy() {
          for (const url of this.#cache.values()) URL.revokeObjectURL(url);
        }
      };
      getHTMLFragment = (doc, id) => doc.getElementById(id) ?? doc.querySelector(`[name="${CSS.escape(id)}"]`);
      getPageSpread = (properties) => {
        for (const p2 of properties) {
          if (p2 === "page-spread-left" || p2 === "rendition:page-spread-left")
            return "left";
          if (p2 === "page-spread-right" || p2 === "rendition:page-spread-right")
            return "right";
          if (p2 === "rendition:page-spread-center") return "center";
        }
      };
      EPUB = class {
        parser = new DOMParser();
        #loader;
        #encryption;
        constructor({
          loadText,
          loadBlob,
          getSize,
          replaceText,
          sha1
        }) {
          this.loadText = loadText;
          this.loadBlob = loadBlob;
          this.getSize = getSize;
          this.replaceText = replaceText;
          this.#encryption = new Encryption(deobfuscators(sha1));
        }
        async #loadXML(uri) {
          globalThis.manabiLoadEBookLastState = `epub-loadxml-awaiting:${uri}`;
          const str = await this.loadText(uri);
          if (!str) return null;
          globalThis.manabiLoadEBookLastState = `epub-loadxml-parsing:${uri}`;
          const doc = this.parser.parseFromString(str, MIME.XML);
          if (doc.querySelector("parsererror"))
            throw new Error(`XML parsing error: ${uri}
${doc.querySelector("parsererror").innerText}`);
          globalThis.manabiLoadEBookLastState = `epub-loadxml-ready:${uri}`;
          return doc;
        }
        async init() {
          globalThis.manabiLoadEBookLastState = "epub-init-awaiting-container";
          const $container = await this.#loadXML("META-INF/container.xml");
          if (!$container) throw new Error("Failed to load container file");
          globalThis.manabiLoadEBookLastState = "epub-init-container-ready";
          const opfs = Array.from(
            $container.getElementsByTagNameNS(NS.CONTAINER, "rootfile"),
            getAttributes("full-path", "media-type")
          ).filter((file) => file.mediaType === "application/oebps-package+xml");
          if (!opfs.length) throw new Error("No package document defined in container");
          const opfPath = opfs[0].fullPath;
          globalThis.manabiLoadEBookLastState = "epub-init-awaiting-opf";
          const opf = await this.#loadXML(opfPath);
          if (!opf) throw new Error("Failed to load package document");
          globalThis.manabiLoadEBookLastState = "epub-init-opf-ready";
          globalThis.manabiLoadEBookLastState = "epub-init-awaiting-encryption";
          const $encryption = await this.#loadXML("META-INF/encryption.xml");
          await this.#encryption.init($encryption, opf);
          globalThis.manabiLoadEBookLastState = "epub-init-encryption-ready";
          this.resources = new Resources({
            opf,
            resolveHref: (url) => resolveURL(url, opfPath)
          });
          globalThis.manabiLoadEBookLastState = "epub-init-resources-ready";
          this.#loader = new Loader({
            loadText: this.loadText,
            loadBlob: (uri) => Promise.resolve(this.loadBlob(uri)).then(this.#encryption.getDecoder(uri)),
            resources: this.resources,
            replaceText: this.replaceText
          });
          globalThis.manabiLoadEBookLastState = "epub-init-loader-ready";
          this.sections = this.resources.spine.map((spineItem, index) => {
            const {
              idref,
              linear,
              properties = []
            } = spineItem;
            const item = this.resources.getItemByID(idref);
            if (!item) {
              console.warn(`Could not find item with ID "${idref}" in manifest`);
              return null;
            }
            return {
              id: this.resources.getItemByID(idref)?.href,
              load: () => this.#loader.loadItem(item),
              unload: () => this.#loader.unloadItem(item),
              createDocument: () => this.loadDocument(item),
              size: this.getSize(item.href),
              cfi: this.resources.cfis[index],
              linear,
              pageSpread: getPageSpread(properties),
              resolveHref: (href) => resolveURL(href, item.href),
              loadMediaOverlay: () => this.loadMediaOverlay(item)
            };
          }).filter((s2) => s2);
          globalThis.manabiLoadEBookLastState = "epub-init-sections-ready";
          const {
            navPath,
            ncxPath
          } = this.resources;
          if (navPath) try {
            globalThis.manabiLoadEBookLastState = "epub-init-awaiting-nav";
            const resolve = (url) => resolveURL(url, navPath);
            const nav = parseNav(await this.#loadXML(navPath), resolve);
            this.toc = nav.toc;
            this.pageList = nav.pageList;
            this.landmarks = nav.landmarks;
            globalThis.manabiLoadEBookLastState = "epub-init-nav-ready";
          } catch (e2) {
            console.warn(e2);
          }
          if (!this.toc && ncxPath) try {
            globalThis.manabiLoadEBookLastState = "epub-init-awaiting-ncx";
            const resolve = (url) => resolveURL(url, ncxPath);
            const ncx = parseNCX(await this.#loadXML(ncxPath), resolve);
            this.toc = ncx.toc;
            this.pageList = ncx.pageList;
            globalThis.manabiLoadEBookLastState = "epub-init-ncx-ready";
          } catch (e2) {
            console.warn(e2);
          }
          this.landmarks ??= this.resources.guide;
          globalThis.manabiLoadEBookLastState = "epub-init-awaiting-metadata";
          const {
            metadata,
            rendition,
            media
          } = getMetadata(opf);
          this.rendition = rendition;
          this.media = media;
          media.duration = parseClock(media.duration);
          this.dir = this.resources.pageProgressionDirection;
          this.rawMetadata = metadata;
          const title = metadata?.title?.[0];
          this.metadata = {
            title: title?.value,
            subtitle: metadata?.title?.find((x2) => x2.titleType === "subtitle")?.value,
            sortAs: title?.fileAs,
            language: metadata?.language,
            identifier: getIdentifier(opf),
            description: metadata?.description?.value,
            publisher: metadata?.publisher?.value,
            published: metadata?.date,
            modified: metadata?.dctermsModified,
            subject: metadata?.subject?.filter(({
              value,
              code
            }) => value || code)?.map(({
              value,
              code,
              scheme
            }) => ({
              name: value,
              code,
              scheme
            })),
            rights: metadata?.rights?.value
          };
          const relators = {
            art: "artist",
            aut: "author",
            bkp: "producer",
            clr: "colorist",
            edt: "editor",
            ill: "illustrator",
            trl: "translator",
            pbl: "publisher"
          };
          const mapContributor = (defaultKey) => (obj) => {
            const keys = [...new Set(obj.role?.map(({
              value: value2,
              scheme
            }) => (!scheme || scheme === "marc:relators" ? relators[value2] : null) ?? defaultKey))];
            const value = {
              name: obj.value,
              sortAs: obj.fileAs
            };
            return [keys?.length ? keys : [defaultKey], value];
          };
          metadata?.creator?.map(mapContributor("author"))?.concat(metadata?.contributor?.map?.(mapContributor("contributor")))?.forEach(([keys, value]) => keys.forEach((key) => {
            if (this.metadata[key]) this.metadata[key].push(value);
            else this.metadata[key] = [value];
          }));
          globalThis.manabiLoadEBookLastState = "epub-init-complete";
          return this;
        }
        async loadDocument(item) {
          const str = await this.loadText(item.href);
          return this.parser.parseFromString(str, item.mediaType);
        }
        async loadMediaOverlay(item) {
          const id = item.mediaOverlay;
          if (!id) return null;
          const media = this.resources.getItemByID(id);
          const doc = await this.#loadXML(media.href);
          const parsed = parseSMIL(doc, (url) => resolveURL(url, media.href));
          return parsed;
        }
        resolveCFI(cfi) {
          return this.resources.resolveCFI(cfi);
        }
        resolveHref(href) {
          const [path, hash] = href.split("#");
          const item = this.resources.getItemByHref(decodeURI(path));
          if (!item) return null;
          const index = this.resources.spine.findIndex(({
            idref
          }) => idref === item.id);
          const anchor = hash ? (doc) => getHTMLFragment(doc, hash) : () => 0;
          return {
            index,
            anchor
          };
        }
        splitTOCHref(href) {
          return href?.split("#") ?? [];
        }
        getTOCFragment(doc, id) {
          return doc.getElementById(id) ?? doc.querySelector(`[name="${CSS.escape(id)}"]`);
        }
        isExternal(uri) {
          return isExternal(uri);
        }
        async getCover() {
          const cover = this.resources?.cover;
          return cover?.href ? new Blob([await this.loadBlob(cover.href)], {
            type: cover.mediaType
          }) : null;
        }
        async getCalibreBookmarks() {
          const txt = await this.loadText("META-INF/calibre_bookmarks.txt");
          const magic = "encoding=json+base64:";
          if (txt?.startsWith(magic)) {
            const json = atob(txt.slice(magic.length));
            return JSON.parse(json);
          }
        }
        destroy() {
          this.#loader?.destroy();
        }
      };
    }
  });

  // view.js
  init_epubcfi();

  // fixed-layout.js
  var parseViewport = (str) => str?.split(/[,;\s]/)?.filter((x2) => x2)?.map((x2) => x2.split("=").map((x3) => x3.trim()));
  var getViewport = (doc, viewport) => {
    if (doc.documentElement.nodeName === "svg") {
      const [, , width, height] = doc.documentElement.getAttribute("viewBox")?.split(/\s/) ?? [];
      return { width, height };
    }
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')?.getAttribute("content"));
    if (meta) return Object.fromEntries(meta);
    if (typeof viewport === "string") return parseViewport(viewport);
    if (viewport) return viewport;
    const img = doc.querySelector("img");
    if (img) return { width: img.naturalWidth, height: img.naturalHeight };
    console.warn(new Error("Missing viewport properties"));
    return { width: 1e3, height: 2e3 };
  };
  var FixedLayout = class extends HTMLElement {
    #root = this.attachShadow({ mode: "closed" });
    #wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    #resizeObserver = new ResizeObserver(() => this.#render());
    //    #mutationObserver = new MutationObserver(async () => {
    //        console.log("befre...")
    //        await this.#wait(100)
    //        requestAnimationFrame(() => {
    //        console.log("in...")
    //            this.render()
    //        })
    ////        await this.#wait(100)
    ////        this.#render()
    //    })
    #spreads;
    #index = -1;
    defaultViewport;
    spread;
    #portrait = false;
    #left;
    #right;
    #center;
    #side;
    constructor() {
      super();
      const sheet = new CSSStyleSheet();
      this.#root.adoptedStyleSheets = [sheet];
      sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }`);
      this.#resizeObserver.observe(this);
    }
    async #createFrame({ index, src }) {
      const element = document.createElement("div");
      const iframe = document.createElement("iframe");
      element.append(iframe);
      Object.assign(iframe.style, {
        border: "0",
        display: "none",
        overflow: "hidden"
      });
      iframe.setAttribute("sandbox", "allow-same-origin allow-scripts");
      iframe.setAttribute("scrolling", "no");
      iframe.setAttribute("part", "filter");
      this.#root.append(element);
      if (!src) return { blank: true, element, iframe };
      return new Promise((resolve) => {
        const onload = () => {
          iframe.removeEventListener("load", onload);
          const doc = iframe.contentDocument;
          this.dispatchEvent(new CustomEvent("load", { detail: { doc, index } }));
          const { width, height } = getViewport(doc, this.defaultViewport);
          resolve({
            element,
            iframe,
            width: parseFloat(width),
            height: parseFloat(height)
          });
        };
        iframe.addEventListener("load", onload);
        iframe.src = src;
      });
    }
    #render(side = this.#side) {
      if (!side) return;
      const left = this.#left ?? {};
      const right = this.#center ?? this.#right;
      const target = side === "left" ? left : right;
      const { width, height } = this.getBoundingClientRect();
      const portrait = this.spread !== "both" && this.spread !== "portrait" && height > width;
      this.#portrait = portrait;
      const blankWidth = left.width ?? right.width;
      const blankHeight = left.height ?? right.height;
      const scale = portrait ? Math.min(
        width / (target.width ?? blankWidth),
        height / (target.height ?? blankHeight)
      ) : Math.min(
        width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
        height / Math.max(
          left.height ?? blankHeight,
          right.height ?? blankHeight
        )
      );
      const transform = (frame) => {
        const { element, iframe, width: width2, height: height2 } = frame;
        Object.assign(iframe.style, {
          width: `${width2}px`,
          height: `${height2}px`,
          transform: `scale(${scale})`,
          transformOrigin: "top left",
          display: "block"
        });
        Object.assign(element.style, {
          width: `${(width2 ?? blankWidth) * scale}px`,
          height: `${(height2 ?? blankHeight) * scale}px`,
          overflow: "hidden",
          display: "block"
        });
        if (portrait && frame !== target) {
          element.style.display = "none";
        }
      };
      if (this.#center) {
        transform(this.#center);
      } else {
        transform(left);
        transform(right);
      }
    }
    async #showSpread({ left, right, center, side }) {
      this.#root.replaceChildren();
      this.#left = null;
      this.#right = null;
      this.#center = null;
      if (center) {
        this.#center = await this.#createFrame(center);
        this.#side = "center";
        this.#render();
      } else {
        this.#left = await this.#createFrame(left);
        this.#right = await this.#createFrame(right);
        this.#side = side;
        this.#render();
      }
    }
    #goLeft() {
      if (this.#center) return;
      if (this.#left?.blank) return true;
      if (this.#portrait && this.#left?.element?.style?.display === "none") {
        this.#right.element.style.display = "none";
        this.#left.element.style.display = "block";
        this.#side = "left";
        return true;
      }
    }
    #goRight() {
      if (this.#center) return;
      if (this.#right?.blank) return true;
      if (this.#portrait && this.#right?.element?.style?.display === "none") {
        this.#left.element.style.display = "none";
        this.#right.element.style.display = "block";
        this.#side = "right";
        return true;
      }
    }
    open(book) {
      this.book = book;
      const { rendition } = book;
      this.spread = rendition?.spread;
      this.defaultViewport = rendition?.viewport;
      const rtl = book.dir === "rtl";
      const ltr = !rtl;
      this.rtl = rtl;
      if (rendition?.spread === "none")
        this.#spreads = book.sections.map((section) => ({ center: section }));
      else this.#spreads = book.sections.reduce((arr, section) => {
        const last = arr[arr.length - 1];
        const { linear, pageSpread } = section;
        if (linear === "no") return arr;
        const newSpread = () => {
          const spread = {};
          arr.push(spread);
          return spread;
        };
        if (pageSpread === "center") newSpread().center = section;
        else if (pageSpread === "left") {
          const spread = last.center || last.left || ltr ? newSpread() : last;
          spread.left = section;
        } else if (pageSpread === "right") {
          const spread = last.center || last.right || rtl ? newSpread() : last;
          spread.right = section;
        } else if (ltr) {
          if (last.center || last.right) newSpread().left = section;
          else if (last.left) last.right = section;
          else last.left = section;
        } else {
          if (last.center || last.left) newSpread().right = section;
          else if (last.right) last.left = section;
          else last.right = section;
        }
        return arr;
      }, [{}]);
    }
    get index() {
      const spread = this.#spreads[this.#index];
      const section = spread?.center ?? (this.side === "left" ? spread.left ?? spread.right : spread.right ?? spread.left);
      return this.book.sections.indexOf(section);
    }
    #reportLocation(reason) {
      this.dispatchEvent(new CustomEvent("relocate", { detail: { reason, range: null, index: this.index, fraction: 0, size: 1 } }));
    }
    getSpreadOf(section) {
      const spreads = this.#spreads;
      for (let index = 0; index < spreads.length; index++) {
        const { left, right, center } = spreads[index];
        if (left === section) return { index, side: "left" };
        if (right === section) return { index, side: "right" };
        if (center === section) return { index, side: "center" };
      }
    }
    async goToSpread(index, side, reason) {
      if (index < 0 || index > this.#spreads.length - 1) return;
      if (index === this.#index) {
        this.#render(side);
        return;
      }
      this.#index = index;
      const spread = this.#spreads[index];
      if (spread.center) {
        const index2 = this.book.sections.indexOf(spread.center);
        const src = await spread.center?.load?.();
        await this.#showSpread({ center: { index: index2, src } });
      } else {
        const indexL = this.book.sections.indexOf(spread.left);
        const indexR = this.book.sections.indexOf(spread.right);
        const srcL = await spread.left?.load?.();
        const srcR = await spread.right?.load?.();
        const left = { index: indexL, src: srcL };
        const right = { index: indexR, src: srcR };
        await this.#showSpread({ left, right, side });
      }
      this.#reportLocation(reason);
    }
    async select(target) {
      await this.goTo(target);
    }
    async goTo(target) {
      const { book } = this;
      const resolved = await target;
      const section = book.sections[resolved.index];
      if (!section) return;
      const { index, side } = this.getSpreadOf(section);
      await this.goToSpread(index, side);
    }
    async next() {
      const s2 = this.rtl ? this.#goLeft() : this.#goRight();
      if (s2) this.#reportLocation("page");
      else return this.goToSpread(this.#index + 1, this.rtl ? "right" : "left", "page");
    }
    async prev() {
      const s2 = this.rtl ? this.#goRight() : this.#goLeft();
      if (s2) this.#reportLocation("page");
      else return this.goToSpread(this.#index - 1, this.rtl ? "left" : "right", "page");
    }
    getContents() {
      return Array.from(this.#root.querySelectorAll("iframe"), (frame) => ({
        doc: frame.contentDocument
        // TODO: index, overlayer
      }));
    }
    destroy() {
      this.#resizeObserver.unobserve(this);
    }
  };
  customElements.define("foliate-fxl", FixedLayout);

  // ebook-section-layout.js
  var CHUNK_ATOMIC_TAG_NAMES = /* @__PURE__ */ new Set([
    "manabi-segment",
    "img",
    "picture",
    "video",
    "audio",
    "canvas",
    "svg",
    "iframe",
    "br",
    "hr",
    "input",
    "textarea",
    "select"
  ]);
  var WARMUP_DELAY_MS = 16;
  var WARMUP_PAGE_BATCH = 2;
  var STAGING_ROOT_ID_SUFFIX = "-ebook-layout-staging";
  var PRESERVED_SOURCE_SNAPSHOT_KEY = "__manabiEbookPreservedSourceSnapshot";
  var MIN_CHUNK_UNITS_BEFORE_OVERFLOW_BOUNDARY = 12;
  var MIN_CHUNK_TEXT_LENGTH_BEFORE_OVERFLOW_BOUNDARY = 20;
  var logReaderPerf = (event, detail = {}) => {
    try {
      const line = `# READERPERF ${JSON.stringify({ event, ...detail })}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_error) {
    }
  };
  var perfNow = () => globalThis.performance?.now?.() ?? Date.now();
  var copyAttributes = (from, to) => {
    if (!(from instanceof Element) || !(to instanceof Element)) return;
    for (const { name, value } of Array.from(from.attributes)) {
      to.setAttribute(name, value);
    }
  };
  var snapshotAttributes = (element) => {
    if (!(element instanceof Element)) return [];
    return Array.from(element.attributes).map(({ name, value }) => ({ name, value }));
  };
  var applyStoredAttributes = (element, attributes) => {
    if (!(element instanceof Element) || !Array.isArray(attributes)) return;
    for (const entry of attributes) {
      if (!entry?.name) continue;
      try {
        element.setAttribute(entry.name, entry.value ?? "");
      } catch (_error) {
      }
    }
  };
  var resolveSectionRoot = (doc) => {
    const readerContent = doc?.getElementById?.("reader-content");
    if (!(readerContent instanceof HTMLElement)) return null;
    const pageNode = readerContent.querySelector(":scope > .page") || readerContent;
    return pageNode.querySelector("article") || pageNode;
  };
  var rootLooksPaginated = (root) => {
    if (!(root instanceof HTMLElement)) return false;
    return root.classList.contains("manabi-page-root") || root.querySelector?.(".manabi-page-column-chunk") != null || root.querySelector?.(".manabi-page") != null;
  };
  var capturePreservedSourceSnapshot = ({ doc, root }) => {
    if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null;
    return {
      bodyHTML: doc.body?.innerHTML ?? "",
      bodyClassName: doc.body?.className ?? "",
      bodyAttributes: snapshotAttributes(doc.body),
      documentElementAttributes: snapshotAttributes(doc.documentElement),
      rootInnerHTML: root.innerHTML ?? "",
      contentURL: doc.defaultView?.manabiCurrentContentURL ?? doc.URL ?? null,
      capturedAt: Date.now()
    };
  };
  var preservedSourceSnapshotForRuntime = (runtime) => {
    const snapshot = runtime?.[PRESERVED_SOURCE_SNAPSHOT_KEY];
    return snapshot && typeof snapshot === "object" ? snapshot : null;
  };
  var storePreservedSourceSnapshot = (runtime, snapshot) => {
    if (!runtime || !snapshot) return;
    runtime[PRESERVED_SOURCE_SNAPSHOT_KEY] = snapshot;
  };
  var createStagingRootForLiveRoot = (liveRoot) => {
    if (!(liveRoot instanceof HTMLElement)) return null;
    const doc = liveRoot.ownerDocument;
    const stagingRoot = doc.createElement(liveRoot.tagName.toLowerCase());
    const liveRect = liveRoot.getBoundingClientRect?.() || { width: 0, height: 0 };
    const viewportWidth = doc.defaultView?.innerWidth ?? 0;
    const viewportHeight = doc.defaultView?.innerHeight ?? 0;
    const width = Math.max(1, Math.round(liveRect.width || viewportWidth || 1));
    const height = Math.max(1, Math.round(liveRect.height || viewportHeight || 1));
    copyAttributes(liveRoot, stagingRoot);
    stagingRoot.id = `${liveRoot.id || "reader-content"}${STAGING_ROOT_ID_SUFFIX}`;
    stagingRoot.setAttribute("aria-hidden", "true");
    stagingRoot.dataset.manabiLayoutStaging = "true";
    stagingRoot.style.position = "fixed";
    stagingRoot.style.left = "-200vw";
    stagingRoot.style.top = "0";
    stagingRoot.style.inlineSize = `${width}px`;
    stagingRoot.style.blockSize = `${height}px`;
    stagingRoot.style.visibility = "hidden";
    stagingRoot.style.pointerEvents = "none";
    stagingRoot.style.overflow = "hidden";
    liveRoot.parentNode?.insertBefore?.(stagingRoot, liveRoot.nextSibling);
    return stagingRoot;
  };
  var isRangeLike = (value) => {
    if (!value || typeof value !== "object") return false;
    return value.startContainer != null && value.endContainer != null && typeof value.collapsed === "boolean";
  };
  var shouldSkipChunkSourceNode = (node) => {
    if (!(node instanceof Element)) return false;
    return node.matches?.(
      ".manabi-tracking-container,.manabi-tracking-button,.manabi-tracking-status-unlock-button-container,.manabi-tracking-status-tip,#manabi-tracking-section-subscription-preview-inline-notice,#manabi-tracking-footer,.manabi-article-marked-as-finished"
    ) === true;
  };
  var shouldKeepChunkTextNode = (textNode) => {
    if (textNode?.nodeType !== Node.TEXT_NODE) return false;
    const value = textNode.nodeValue || "";
    if (value.length === 0) return false;
    if (value.trim() !== "") return true;
    const parentElement = textNode.parentElement;
    if (!(parentElement instanceof HTMLElement)) return false;
    const display = parentElement.ownerDocument?.defaultView?.getComputedStyle?.(parentElement)?.display || "";
    if (display.startsWith("inline")) return true;
    return parentElement.matches?.(
      "span, ruby, rb, rt, rp, em, strong, b, i, small, sub, sup, mark, code, a, manabi-sentence"
    ) === true;
  };
  var chunkAncestorChainForNode = (node, rootNode) => {
    const chain = [];
    let current = node;
    while (current && current !== rootNode) {
      if (current.nodeType === Node.ELEMENT_NODE && !shouldSkipChunkSourceNode(current)) {
        chain.unshift(current);
      }
      current = current.parentNode;
    }
    return chain;
  };
  var cloneChunkShell = (sourceElement) => {
    const clone = sourceElement.cloneNode(false);
    if (clone instanceof Element) {
      clone.removeAttribute("id");
      clone.removeAttribute("data-manabi-tracking-section-read");
      if (clone.classList.contains("manabi-tracking-section") && clone.dataset.manabiTrackingSectionKind !== "title") {
        clone.classList.remove("manabi-tracking-section");
        clone.classList.add("manabi-semantic-section");
      }
      const tagName = clone.tagName?.toLowerCase?.() || "";
      if (clone instanceof HTMLElement && (tagName === "section" || tagName === "article" || tagName === "div")) {
        clone.style.display = "block";
        clone.style.inlineSize = "100%";
        clone.style.maxInlineSize = "100%";
        clone.style.minInlineSize = "0";
        clone.style.margin = "0";
        clone.style.boxSizing = "border-box";
      }
    }
    return clone;
  };
  var cloneChunkUnitNode = (unit, targetDocument) => {
    if (unit.type === "text") {
      return targetDocument.createTextNode(unit.textContent ?? unit.sourceNode.nodeValue ?? "");
    }
    const clone = unit.sourceNode.cloneNode(true);
    if (clone instanceof Element && unit.kind !== "segment") {
      clone.removeAttribute("id");
    }
    return clone;
  };
  var collectEbookChunkUnits = (rootNode) => {
    const units = [];
    const visit = (node) => {
      if (!node) return;
      if (node.nodeType === Node.TEXT_NODE) {
        if (shouldKeepChunkTextNode(node)) {
          const textContent = node.nodeValue || "";
          units.push({
            type: "text",
            kind: "text",
            sourceNode: node,
            ancestors: chunkAncestorChainForNode(node.parentNode, rootNode),
            textContent,
            sourceStartOffset: 0,
            sourceEndOffset: textContent.length
          });
        }
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (shouldSkipChunkSourceNode(node)) return;
      const tagName = node.tagName?.toLowerCase?.() || "";
      if (CHUNK_ATOMIC_TAG_NAMES.has(tagName) || node.dataset?.manabiChunkAtomic === "true") {
        units.push({
          type: "element",
          kind: tagName === "manabi-segment" ? "segment" : "atomic",
          sourceNode: node,
          ancestors: chunkAncestorChainForNode(node.parentNode, rootNode)
        });
        return;
      }
      if (!node.firstChild) {
        units.push({
          type: "element",
          kind: "leaf",
          sourceNode: node,
          ancestors: chunkAncestorChainForNode(node.parentNode, rootNode)
        });
        return;
      }
      for (const childNode of Array.from(node.childNodes)) {
        visit(childNode);
      }
    };
    for (const childNode of Array.from(rootNode.childNodes)) {
      visit(childNode);
    }
    return units;
  };
  var createChunkAppendState = () => ({
    sourceAncestors: [],
    destinationAncestors: [],
    unitCount: 0
  });
  var resolveChunkTextSplitIndex = (textContent) => {
    const scalars = Array.from(textContent || "");
    if (scalars.length < 2) return 0;
    const midpoint = Math.floor(scalars.length / 2);
    for (let offset = 0; offset < scalars.length; offset += 1) {
      const forwardIndex = midpoint + offset;
      if (forwardIndex > 0 && forwardIndex < scalars.length && /\s/.test(scalars[forwardIndex])) {
        return forwardIndex;
      }
      const backwardIndex = midpoint - offset;
      if (backwardIndex > 0 && backwardIndex < scalars.length && /\s/.test(scalars[backwardIndex])) {
        return backwardIndex;
      }
    }
    return midpoint;
  };
  var splitChunkUnitForFit = (unit) => {
    if (!unit || unit.type !== "text") return null;
    const textContent = unit.textContent ?? unit.sourceNode?.nodeValue ?? "";
    if (textContent.length < 2) return null;
    const scalars = Array.from(textContent);
    const splitIndex = resolveChunkTextSplitIndex(textContent);
    if (splitIndex <= 0 || splitIndex >= scalars.length) return null;
    const leftText = scalars.slice(0, splitIndex).join("");
    const rightText = scalars.slice(splitIndex).join("");
    if (!leftText.length || !rightText.length) return null;
    const leftLength = leftText.length;
    return [
      {
        ...unit,
        textContent: leftText,
        sourceStartOffset: unit.sourceStartOffset,
        sourceEndOffset: unit.sourceStartOffset + leftLength
      },
      {
        ...unit,
        textContent: rightText,
        sourceStartOffset: unit.sourceStartOffset + leftLength,
        sourceEndOffset: unit.sourceEndOffset
      }
    ];
  };
  var appendChunkUnit = (chunkBody, appendState, unit) => {
    const ancestors = Array.isArray(unit.ancestors) ? unit.ancestors : [];
    let commonPrefixLength = 0;
    while (commonPrefixLength < appendState.sourceAncestors.length && commonPrefixLength < ancestors.length && appendState.sourceAncestors[commonPrefixLength] === ancestors[commonPrefixLength]) {
      commonPrefixLength += 1;
    }
    appendState.sourceAncestors.length = commonPrefixLength;
    appendState.destinationAncestors.length = commonPrefixLength;
    let parent = commonPrefixLength > 0 ? appendState.destinationAncestors[commonPrefixLength - 1] : chunkBody;
    for (let index = commonPrefixLength; index < ancestors.length; index += 1) {
      const shellClone = cloneChunkShell(ancestors[index]);
      parent.appendChild(shellClone);
      appendState.sourceAncestors.push(ancestors[index]);
      appendState.destinationAncestors.push(shellClone);
      parent = shellClone;
    }
    const leafParent = appendState.destinationAncestors.length > 0 ? appendState.destinationAncestors[appendState.destinationAncestors.length - 1] : chunkBody;
    const leafNode = cloneChunkUnitNode(unit, chunkBody.ownerDocument);
    leafParent.appendChild(leafNode);
    appendState.unitCount += 1;
    return {
      commonPrefixLength,
      leafNode
    };
  };
  var revertChunkUnit = (appendState, appendRecord) => {
    appendRecord?.leafNode?.remove?.();
    appendState.unitCount = Math.max(0, appendState.unitCount - 1);
    while (appendState.destinationAncestors.length > appendRecord.commonPrefixLength) {
      const shellClone = appendState.destinationAncestors.pop();
      appendState.sourceAncestors.pop();
      if (shellClone?.childNodes?.length === 0) {
        shellClone.remove();
      }
    }
  };
  var chunkBodyHasOverflow = (chunkBody, vertical) => {
    if (!(chunkBody instanceof HTMLElement)) return false;
    const slack = 1;
    return vertical ? chunkBody.scrollWidth > chunkBody.clientWidth + slack : chunkBody.scrollHeight > chunkBody.clientHeight + slack;
  };
  var normalizedChunkBodyTextLength = (chunkBody) => {
    if (!(chunkBody instanceof HTMLElement)) return 0;
    return (chunkBody.textContent || "").replace(/\s+/g, "").length;
  };
  var shouldDelayChunkOverflowBoundary = (chunkBody, appendState, unit) => {
    const unitCount = appendState?.unitCount ?? 0;
    if (unitCount >= MIN_CHUNK_UNITS_BEFORE_OVERFLOW_BOUNDARY) return false;
    if (normalizedChunkBodyTextLength(chunkBody) >= MIN_CHUNK_TEXT_LENGTH_BEFORE_OVERFLOW_BOUNDARY) return false;
    return unit?.kind === "segment" || unit?.type === "text";
  };
  var allowOversizeChunkOverflow = (chunkNode, chunkBody) => {
    if (!(chunkNode instanceof HTMLElement) || !(chunkBody instanceof HTMLElement)) return;
    chunkNode.classList.add("manabi-page-column-chunk-oversize");
    chunkNode.dataset.manabiChunkOversize = "true";
    chunkBody.style.overflow = "visible";
    chunkNode.style.overflow = "visible";
  };
  var applyPageRootLayoutStyles = (root) => {
    if (!(root instanceof HTMLElement)) return;
    root.style.position = "relative";
    root.style.left = "0px";
    root.style.top = "0px";
    root.style.display = "block";
    root.style.visibility = "visible";
    root.style.pointerEvents = "auto";
    root.style.transform = "none";
    root.style.transition = "none";
    root.style.direction = "ltr";
    root.style.inlineSize = "100%";
    root.style.minInlineSize = "100%";
    root.style.maxInlineSize = "none";
    root.style.blockSize = "100%";
    root.style.boxSizing = "border-box";
    root.style.overflow = "visible";
  };
  var updatePageRootLayoutExtent = (root, { inlineSize = null, pageCount = 1 } = {}) => {
    if (!(root instanceof HTMLElement)) return;
    if (Number.isFinite(inlineSize) && inlineSize > 0) {
      const totalInlineSize = Math.max(1, pageCount) * inlineSize;
      const totalInlineSizeCSS = `${totalInlineSize}px`;
      root.style.inlineSize = totalInlineSizeCSS;
      root.style.minInlineSize = totalInlineSizeCSS;
    } else {
      root.style.inlineSize = "100%";
      root.style.minInlineSize = "100%";
    }
  };
  var resolvePageViewportSize = (root) => {
    if (!(root instanceof HTMLElement)) {
      return { inlineSize: null, blockSize: null };
    }
    const rect = root.getBoundingClientRect?.() ?? null;
    const inlineSize = Math.max(
      1,
      Math.round(rect?.width || root.clientWidth || root.offsetWidth || 0)
    );
    const blockSize = Math.max(
      1,
      Math.round(rect?.height || root.clientHeight || root.offsetHeight || 0)
    );
    return {
      inlineSize: Number.isFinite(inlineSize) ? inlineSize : null,
      blockSize: Number.isFinite(blockSize) ? blockSize : null
    };
  };
  var applyPageLayoutStyles = (pageNode, { inlineSize = null, blockSize = null, pageIndex = 0 } = {}) => {
    if (!(pageNode instanceof HTMLElement)) return;
    pageNode.style.position = "absolute";
    pageNode.style.left = Number.isFinite(inlineSize) && inlineSize > 0 ? `${Math.max(0, pageIndex) * inlineSize}px` : "0px";
    pageNode.style.top = "0px";
    pageNode.style.display = "flex";
    pageNode.style.flexDirection = "row";
    pageNode.style.flex = "0 0 auto";
    if (Number.isFinite(inlineSize) && inlineSize > 0) {
      const inlineSizeCSS = `${inlineSize}px`;
      pageNode.style.inlineSize = inlineSizeCSS;
      pageNode.style.minInlineSize = inlineSizeCSS;
      pageNode.style.maxInlineSize = inlineSizeCSS;
    } else {
      pageNode.style.inlineSize = "100%";
      pageNode.style.minInlineSize = "100%";
      pageNode.style.maxInlineSize = "100%";
    }
    if (Number.isFinite(blockSize) && blockSize > 0) {
      const blockSizeCSS = `${blockSize}px`;
      pageNode.style.blockSize = blockSizeCSS;
      pageNode.style.minBlockSize = blockSizeCSS;
    } else {
      pageNode.style.blockSize = "100%";
      pageNode.style.minBlockSize = "100%";
    }
    pageNode.style.boxSizing = "border-box";
    pageNode.style.gap = "0px";
    pageNode.style.padding = "0 18px 24px 18px";
    pageNode.style.overflow = "hidden";
  };
  var applyChunkLayoutStyles = (chunkNode, chunkBody) => {
    if (chunkNode instanceof HTMLElement) {
      chunkNode.style.display = "flex";
      chunkNode.style.flexDirection = "column";
      chunkNode.style.flex = "1 1 0";
      chunkNode.style.minInlineSize = "0";
      chunkNode.style.minBlockSize = "0";
      chunkNode.style.inlineSize = "100%";
      chunkNode.style.blockSize = "100%";
      chunkNode.style.boxSizing = "border-box";
      chunkNode.style.overflow = "hidden";
    }
    if (chunkBody instanceof HTMLElement) {
      chunkBody.style.display = "block";
      chunkBody.style.flex = "1 1 auto";
      chunkBody.style.minInlineSize = "0";
      chunkBody.style.minBlockSize = "0";
      chunkBody.style.inlineSize = "100%";
      chunkBody.style.blockSize = "100%";
      chunkBody.style.boxSizing = "border-box";
      chunkBody.style.overflow = "hidden";
    }
  };
  var createChunkSection = ({ doc, pageNode, pageIndex, columnIndex, layoutVersion, runtime }) => {
    const chunkNode = doc.createElement("section");
    chunkNode.className = "manabi-semantic-section manabi-page-column-chunk";
    chunkNode.dataset.manabiTrackingOrigin = "js";
    chunkNode.dataset.manabiTrackingSectionKind = "chunk";
    chunkNode.dataset.manabiPageIndex = String(pageIndex);
    chunkNode.dataset.manabiColumnIndex = String(columnIndex);
    chunkNode.dataset.manabiChunkId = `chunk-v${layoutVersion}-p${pageIndex}-c${columnIndex}`;
    chunkNode.dataset.manabiTrackingSectionId = chunkNode.dataset.manabiChunkId;
    const chunkBody = doc.createElement("div");
    chunkBody.className = "manabi-page-column-body";
    applyChunkLayoutStyles(chunkNode, chunkBody);
    chunkNode.appendChild(chunkBody);
    pageNode.appendChild(chunkNode);
    return { chunkNode, chunkBody };
  };
  var EbookSectionLayout = class {
    #doc = null;
    #root = null;
    #stagingRoot = null;
    #normalizedRootHTML = null;
    #sourceDoc = null;
    #sourceRoot = null;
    #layoutVersion = 0;
    #pageRecords = [];
    #unitRecords = [];
    #unitIndicesBySourceNode = /* @__PURE__ */ new Map();
    #controller = null;
    #currentSourceAnchor = null;
    #buildState = null;
    #warmupTimer = null;
    #warmupToken = 0;
    #sourceContentURL = null;
    attach(doc) {
      if (this.#doc === doc) return;
      this.destroy();
      this.#doc = doc;
      this.#root = resolveSectionRoot(doc);
      if (doc?.defaultView) {
        this.#controller = {
          ensureSourceDocument: () => {
            try {
              return this.ensureSourceDocument();
            } catch (error) {
              console.error(error);
              return null;
            }
          },
          pageCount: () => this.pageCount(),
          hasPendingWarmup: () => this.hasPendingWarmup(),
          layoutDiagnostics: () => this.layoutDiagnostics(),
          ensurePageBuilt: (pageIndex, options) => this.ensurePageBuilt(pageIndex, options),
          visibleSourceRange: (pageIndex) => this.visibleSourceRange(pageIndex),
          captureLocationForPage: (pageIndex) => this.captureLocationForPage(pageIndex),
          pageIndexForLocation: (location) => this.pageIndexForLocation(location),
          sourceRangeForLocation: (location) => this.sourceRangeForLocation(location),
          requestRebuild: ({ reason, anchor } = {}) => {
            try {
              return this.buildFromAnchor(anchor ?? this.#currentSourceAnchor ?? 0, {
                reason: reason ?? "requestRebuild"
              });
            } catch (error) {
              console.error(error);
              return null;
            }
          },
          rebuildFromCurrentLocation: ({ reason } = {}) => {
            try {
              return this.rebuildFromCurrentLocation({
                reason: reason ?? "rebuildFromCurrentLocation"
              });
            } catch (error) {
              console.error(error);
              return null;
            }
          }
        };
        doc.defaultView.manabiEbookSectionLayoutController = this.#controller;
      }
    }
    destroy() {
      this.#cancelWarmup();
      this.#removeStagingRoot();
      if (this.#doc?.defaultView?.manabiEbookSectionLayoutController === this.#controller) {
        delete this.#doc.defaultView.manabiEbookSectionLayoutController;
      }
      this.#doc = null;
      this.#root = null;
      this.#stagingRoot = null;
      this.#normalizedRootHTML = null;
      this.#sourceDoc = null;
      this.#sourceRoot = null;
      this.#layoutVersion = 0;
      this.#pageRecords = [];
      this.#unitRecords = [];
      this.#unitIndicesBySourceNode = /* @__PURE__ */ new Map();
      this.#controller = null;
      this.#currentSourceAnchor = null;
      this.#buildState = null;
      this.#sourceContentURL = null;
    }
    getSourceDocument() {
      return this.#sourceDoc;
    }
    ensureSourceDocument() {
      const doc = this.#doc;
      const runtime = doc?.defaultView;
      const root = this.#root;
      if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null;
      if (doc.body?.dataset?.isEbook !== "true") return null;
      return this.#runWithSuppressedMutations(() => {
        this.#prepareSourceSnapshot({ doc, runtime, root });
        return this.#sourceDoc;
      });
    }
    setCurrentSourceAnchor(anchor) {
      if (!anchor) return null;
      this.#currentSourceAnchor = anchor;
      return anchor;
    }
    getCurrentSourceAnchor() {
      return this.#currentSourceAnchor;
    }
    invalidate({ reason = "unknown" } = {}) {
      return this.rebuildFromCurrentLocation({ reason });
    }
    build({ reason = "unknown", anchor = this.#currentSourceAnchor ?? 0, anchorResolver = null, location = null } = {}) {
      return this.buildFromAnchor(anchor, { reason, anchorResolver, location });
    }
    buildFromAnchor(anchor, { reason = "unknown", anchorResolver = null, location = null } = {}) {
      const doc = this.#doc;
      const runtime = doc?.defaultView;
      const liveRoot = this.#root;
      if (!(doc instanceof Document) || !(liveRoot instanceof HTMLElement)) return null;
      if (doc.body?.dataset?.isEbook !== "true") return null;
      const buildStart = perfNow();
      let result = null;
      this.#runWithSuppressedMutations(() => {
        this.#cancelWarmup();
        doc.documentElement.dataset.manabiLayoutComplete = "false";
        const snapshotStart = perfNow();
        const units = this.#prepareSourceSnapshot({ doc, runtime, root: liveRoot });
        const snapshotDurationMs = Math.round((perfNow() - snapshotStart) * 100) / 100;
        if (!units?.length) {
          liveRoot.innerHTML = "";
          liveRoot.classList.add("manabi-page-root");
          applyPageRootLayoutStyles(liveRoot);
          this.#pageRecords = [];
          this.#buildState = null;
          this.#refreshLiveRoot({ runtime, root: liveRoot, complete: true });
          logReaderPerf("ebook-layout-build-finished", {
            reason,
            snapshotDurationMs,
            buildDurationMs: 0,
            commitDurationMs: 0,
            totalDurationMs: Math.round((perfNow() - buildStart) * 100) / 100,
            pageCount: 0,
            layoutComplete: true
          });
          result = {
            pageCount: 0,
            reason,
            layoutComplete: true
          };
          return;
        }
        const metrics = runtime?.manabiGetChunkLayoutMetrics?.({ isEbook: true }) || {
          vertical: doc.body?.classList?.contains?.("reader-vertical-writing") === true,
          columnCount: 1
        };
        const columnCount = Math.max(1, Number.parseInt(String(metrics.columnCount || 1), 10) || 1);
        this.#layoutVersion += 1;
        doc.documentElement.dataset.manabiLayoutVersion = String(this.#layoutVersion);
        const resolvedAnchor = typeof anchorResolver === "function" ? anchorResolver(this.#sourceDoc || doc) ?? anchorResolver(doc) : anchor;
        const targetUnitIndex = this.#resolveTargetUnitIndexFromLocationOrAnchor(location, resolvedAnchor);
        const targetSentenceIdentifier = this.#sentenceIdentifierForAnchor(resolvedAnchor) || location?.anchorSentenceIdentifier || this.#sentenceIdentifierForUnitIndex(targetUnitIndex);
        const targetSourceLocation = this.#sourceLocationForAnchor(resolvedAnchor) || this.#sourceLocationForSentenceIdentifier(targetSentenceIdentifier) || location?.anchorSourceLocation || this.#sourceLocationForUnitIndex(targetUnitIndex, "start");
        logReaderPerf("ebook-layout-build-target", {
          reason,
          targetUnitIndex,
          anchorSentenceIdentifier: this.#sentenceIdentifierForAnchor(resolvedAnchor),
          targetSentenceIdentifier: this.#sentenceIdentifierForUnitIndex(targetUnitIndex),
          locationAnchorUnitIndex: location?.anchorUnitIndex ?? null,
          locationAnchorSentenceIdentifier: location?.anchorSentenceIdentifier ?? null
        });
        const buildLayoutStart = perfNow();
        this.#buildState = this.#createBuildState({
          doc,
          runtime,
          liveRoot,
          metrics,
          columnCount,
          units,
          layoutVersion: this.#layoutVersion,
          targetUnitIndex,
          targetSourceLocation
        });
        this.#continueBuilding();
        const buildDurationMs = Math.round((perfNow() - buildLayoutStart) * 100) / 100;
        const fallbackPageIndex = Math.max(0, this.#unitRecords[targetUnitIndex]?.pageIndex ?? 0);
        this.#currentSourceAnchor = this.#sourceAnchorForLocation(targetSourceLocation) || this.#sourceAnchorForSentenceIdentifier(targetSentenceIdentifier) || this.#sourceAnchorForUnitIndex(targetUnitIndex) || this.#normalizeSourceAnchor(resolvedAnchor, fallbackPageIndex);
        logReaderPerf("ebook-layout-current-anchor", {
          reason,
          fallbackPageIndex,
          currentSentenceIdentifier: this.#sentenceIdentifierForAnchor(this.#currentSourceAnchor)
        });
        const commitStart = perfNow();
        this.#commitStagingRootToLiveRoot({
          liveRoot,
          stagingRoot: this.#buildState?.root ?? this.#stagingRoot
        });
        this.#refreshLiveRoot({
          runtime,
          root: liveRoot,
          complete: this.isLayoutComplete()
        });
        const commitDurationMs = Math.round((perfNow() - commitStart) * 100) / 100;
        if (!this.isLayoutComplete()) {
          this.#scheduleWarmup();
        } else {
          this.#removeStagingRoot();
        }
        logReaderPerf("ebook-layout-build-finished", {
          reason,
          snapshotDurationMs,
          buildDurationMs,
          commitDurationMs,
          totalDurationMs: Math.round((perfNow() - buildStart) * 100) / 100,
          pageCount: this.pageCount(),
          layoutComplete: this.isLayoutComplete()
        });
        result = {
          pageCount: this.pageCount(),
          reason,
          layoutComplete: this.isLayoutComplete()
        };
      });
      return result;
    }
    rebuildFromCurrentLocation({ reason = "unknown" } = {}) {
      const currentPageIndex = this.pageIndexForAnchor(this.#currentSourceAnchor);
      const location = currentPageIndex != null ? this.captureLocationForPage(currentPageIndex) : null;
      return this.build({
        reason,
        anchor: this.#currentSourceAnchor ?? 0,
        location
      });
    }
    pageCount() {
      return this.#effectivePageCount();
    }
    isLayoutComplete() {
      return this.#buildState == null;
    }
    hasPendingWarmup() {
      return !this.isLayoutComplete();
    }
    layoutDiagnostics() {
      const resolvedCurrentPageIndex = this.pageIndexForAnchor(this.#currentSourceAnchor) ?? 0;
      const currentPageRecord = this.#pageRecords[resolvedCurrentPageIndex] ?? null;
      const activeBuildPageRecord = this.#buildState?.pageRecord ?? null;
      const liveRoot = this.#root ?? null;
      const liveCurrentPageNode = liveRoot?.querySelector?.(`:scope > .manabi-page[data-manabi-page-index="${resolvedCurrentPageIndex}"]`) ?? null ?? liveRoot?.querySelector?.(`.manabi-page[data-manabi-page-index="${resolvedCurrentPageIndex}"]`) ?? null ?? liveRoot?.querySelector?.(".manabi-page") ?? null;
      const liveCurrentChunkNode = liveCurrentPageNode?.querySelector?.(`:scope > .manabi-page-column-chunk[data-manabi-column-index="0"]`) ?? null ?? liveCurrentPageNode?.querySelector?.(":scope > .manabi-page-column-chunk") ?? liveCurrentPageNode?.querySelector?.(".manabi-page-column-chunk") ?? null;
      const currentChunkBody = liveCurrentChunkNode?.querySelector?.(".manabi-page-column-body") ?? null;
      const liveRootRect = liveRoot?.getBoundingClientRect?.() ?? null;
      const liveCurrentPageRect = liveCurrentPageNode?.getBoundingClientRect?.() ?? null;
      const liveCurrentChunkRect = liveCurrentChunkNode?.getBoundingClientRect?.() ?? null;
      const liveCurrentChunkStyle = liveCurrentChunkNode instanceof Element ? liveCurrentChunkNode.ownerDocument?.defaultView?.getComputedStyle?.(liveCurrentChunkNode) : null;
      const currentChunkBodyStyle = currentChunkBody instanceof Element ? currentChunkBody.ownerDocument?.defaultView?.getComputedStyle?.(currentChunkBody) : null;
      const currentChunkCount = currentPageRecord?.chunkRecords?.length ?? 0;
      const activeBuildChunkCount = activeBuildPageRecord?.chunkRecords?.length ?? 0;
      const maxPageChunkCount = this.#pageRecords.reduce(
        (max, pageRecord) => Math.max(max, pageRecord?.chunkRecords?.length ?? 0),
        0
      );
      const buildMetrics = this.#buildState?.metrics ?? {
        vertical: this.#doc?.body?.classList?.contains?.("reader-vertical-writing") === true,
        verticalRTL: true
      };
      const spreadCandidateDetected = maxPageChunkCount > 1;
      const resolvedColumnCount = Math.max(1, Number.parseInt(String(this.#buildState?.columnCount ?? currentChunkCount ?? 1), 10) || 1);
      const multiUnitActive = spreadCandidateDetected === true && resolvedColumnCount > 1;
      const visibleUnitKind = multiUnitActive ? buildMetrics?.vertical === true ? "paginatedRowSet" : "pageSpread" : "singlePage";
      const visibleUnitAxis = buildMetrics?.vertical === true ? "vertical" : "horizontal";
      const visiblePageCount = multiUnitActive ? resolvedColumnCount : 1;
      const currentUnitIndex = Number.isFinite(resolvedCurrentPageIndex) ? Math.floor(resolvedCurrentPageIndex / visiblePageCount) : null;
      const leadingPageIndex = Number.isFinite(resolvedCurrentPageIndex) ? resolvedCurrentPageIndex - resolvedCurrentPageIndex % visiblePageCount : null;
      const trailingPageIndex = leadingPageIndex != null ? leadingPageIndex + Math.max(0, visiblePageCount - 1) : null;
      const resolvedPageCount = Math.max(0, Number.parseInt(String(this.pageCount()), 10) || 0);
      const hasLeadingSingleton = multiUnitActive && leadingPageIndex === 0 && resolvedCurrentPageIndex === 0;
      const hasTrailingSingleton = multiUnitActive && leadingPageIndex != null && leadingPageIndex > 0 && resolvedPageCount - leadingPageIndex === 1;
      return {
        pageCount: this.pageCount(),
        pageRecordCount: this.#pageRecords.length,
        liveRootExists: !!liveRoot,
        liveRootClassName: liveRoot?.className ?? null,
        liveRootChildCount: liveRoot?.childElementCount ?? null,
        liveRootRectWidth: liveRootRect ? Math.round(liveRootRect.width) : null,
        liveRootRectHeight: liveRootRect ? Math.round(liveRootRect.height) : null,
        liveCurrentPageExists: !!liveCurrentPageNode,
        liveCurrentPageClassName: liveCurrentPageNode?.className ?? null,
        liveCurrentPageRectWidth: liveCurrentPageRect ? Math.round(liveCurrentPageRect.width) : null,
        liveCurrentPageRectHeight: liveCurrentPageRect ? Math.round(liveCurrentPageRect.height) : null,
        liveCurrentPageContainsChunkBody: liveCurrentPageNode instanceof Element ? !!liveCurrentPageNode.querySelector(".manabi-page-column-body") : null,
        liveCurrentChunkExists: !!liveCurrentChunkNode,
        liveCurrentChunkTagName: liveCurrentChunkNode?.tagName?.toLowerCase?.() ?? null,
        liveCurrentChunkClassName: liveCurrentChunkNode?.className ?? null,
        liveCurrentChunkDisplay: liveCurrentChunkStyle?.display ?? null,
        liveCurrentChunkPosition: liveCurrentChunkStyle?.position ?? null,
        liveCurrentChunkFlex: liveCurrentChunkStyle?.flex ?? null,
        liveCurrentChunkRectWidth: liveCurrentChunkRect ? Math.round(liveCurrentChunkRect.width) : null,
        liveCurrentChunkRectHeight: liveCurrentChunkRect ? Math.round(liveCurrentChunkRect.height) : null,
        liveCurrentChunkInnerHTMLLength: liveCurrentChunkNode?.innerHTML?.length ?? null,
        liveCurrentChunkContainsChunkBody: liveCurrentChunkNode instanceof Element ? !!liveCurrentChunkNode.querySelector(".manabi-page-column-body") : null,
        liveCurrentChunkChildCount: liveCurrentChunkNode?.childElementCount ?? null,
        liveCurrentChunkTextLength: liveCurrentChunkNode?.textContent?.length ?? null,
        currentChunkBodyChildCount: currentChunkBody?.childElementCount ?? null,
        currentChunkBodyTextLength: currentChunkBody?.textContent?.length ?? null,
        currentChunkBodyDisplay: currentChunkBodyStyle?.display ?? null,
        currentChunkBodyPosition: currentChunkBodyStyle?.position ?? null,
        currentChunkBodyFlex: currentChunkBodyStyle?.flex ?? null,
        currentPageIndex: resolvedCurrentPageIndex,
        currentPageChunkCount: currentChunkCount,
        maxPageChunkCount,
        activeBuildPageIndex: this.#buildState?.pageIndex ?? null,
        activeBuildChunkCount,
        columnCount: resolvedColumnCount,
        unitCount: this.#unitRecords.length,
        currentChunkClientWidth: currentChunkBody?.clientWidth ?? null,
        currentChunkClientHeight: currentChunkBody?.clientHeight ?? null,
        currentChunkScrollWidth: currentChunkBody?.scrollWidth ?? null,
        currentChunkScrollHeight: currentChunkBody?.scrollHeight ?? null,
        currentChunkOverflow: currentChunkBody instanceof HTMLElement ? chunkBodyHasOverflow(currentChunkBody, buildMetrics?.vertical === true) : null,
        spreadCandidateDetected,
        visibleUnitKind,
        visibleUnitAxis,
        visiblePageCount,
        currentUnitIndex,
        leadingPageIndex,
        trailingPageIndex,
        hasLeadingSingleton,
        hasTrailingSingleton,
        multiUnitActive,
        spreadPagesAllowedForViewport: multiUnitActive,
        vertical: buildMetrics?.vertical ?? null,
        writingMode: buildMetrics?.vertical === true ? buildMetrics?.verticalRTL === true ? "vertical-rl" : "vertical-lr" : "horizontal-tb",
        layoutComplete: this.isLayoutComplete()
      };
    }
    ensurePageBuilt(pageIndex, { reason = "ensure-page" } = {}) {
      if (!Number.isFinite(pageIndex) || pageIndex < 0) {
        return {
          pageCount: this.pageCount(),
          reason,
          layoutComplete: this.isLayoutComplete()
        };
      }
      if (pageIndex < this.pageCount() || this.#buildState == null) {
        return {
          pageCount: this.pageCount(),
          reason,
          layoutComplete: this.isLayoutComplete()
        };
      }
      const doc = this.#doc;
      const runtime = doc?.defaultView;
      const root = this.#root;
      if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null;
      let result = null;
      this.#runWithSuppressedMutations(() => {
        if (this.#buildState) {
          this.#cancelWarmup();
          this.#buildState.stopAfterPageIndex = Math.max(
            pageIndex,
            this.#buildState.stopAfterPageIndex ?? -1
          );
          this.#continueBuilding();
          this.#refreshLiveRoot({
            runtime,
            root,
            complete: this.isLayoutComplete()
          });
          if (!this.isLayoutComplete()) {
            this.#scheduleWarmup();
          }
        }
        result = {
          pageCount: this.pageCount(),
          reason,
          layoutComplete: this.isLayoutComplete()
        };
      });
      return result;
    }
    sourceRangeForPage(pageIndex) {
      return this.sourceRangeForLocation(this.captureLocationForPage(pageIndex));
    }
    captureLocationForPage(pageIndex) {
      const pageRecord = this.#pageRecords[pageIndex];
      if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) return null;
      let anchorUnitIndex = pageRecord.startUnitIndex;
      const currentAnchorUnitIndex = this.#sourceUnitIndexForAnchor(this.#currentSourceAnchor);
      if (Number.isFinite(currentAnchorUnitIndex) && currentAnchorUnitIndex >= pageRecord.startUnitIndex && currentAnchorUnitIndex <= pageRecord.endUnitIndex) {
        anchorUnitIndex = currentAnchorUnitIndex;
      }
      return {
        pageIndex,
        startUnitIndex: pageRecord.startUnitIndex,
        endUnitIndex: pageRecord.endUnitIndex,
        anchorUnitIndex,
        anchorSentenceIdentifier: this.#sentenceIdentifierForUnitIndex(anchorUnitIndex),
        startSourceLocation: this.#sourceLocationForUnitIndex(pageRecord.startUnitIndex, "start"),
        endSourceLocation: this.#sourceLocationForUnitIndex(pageRecord.endUnitIndex, "end"),
        anchorSourceLocation: this.#sourceLocationForAnchor(this.#currentSourceAnchor) || this.#sourceLocationForUnitIndex(anchorUnitIndex, "start"),
        layoutVersion: this.#layoutVersion
      };
    }
    pageIndexForLocation(location) {
      const anchorUnitIndex = this.#sourceUnitIndexForLocation(location?.anchorSourceLocation) ?? this.#unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier) ?? location?.anchorUnitIndex;
      if (Number.isFinite(anchorUnitIndex)) {
        return this.#unitRecords[anchorUnitIndex]?.pageIndex ?? location?.pageIndex ?? null;
      }
      return Number.isFinite(location?.pageIndex) ? location.pageIndex : null;
    }
    sourceRangeForLocation(location) {
      const resolvedPageIndex = this.pageIndexForLocation(location);
      const resolvedPageRecord = Number.isFinite(resolvedPageIndex) ? this.#pageRecords[resolvedPageIndex] : null;
      if (resolvedPageRecord && resolvedPageRecord.startUnitIndex != null && resolvedPageRecord.endUnitIndex != null && this.#sourceDoc) {
        const currentPageRange = this.#sourceDoc.createRange();
        this.#setRangeBoundary(
          currentPageRange,
          "start",
          this.#sourceLocationForUnitIndex(resolvedPageRecord.startUnitIndex, "start")
        );
        this.#setRangeBoundary(
          currentPageRange,
          "end",
          this.#sourceLocationForUnitIndex(resolvedPageRecord.endUnitIndex, "end")
        );
        if (!currentPageRange.collapsed || currentPageRange.toString()?.length) {
          return currentPageRange;
        }
      }
      const startSourceLocation = location?.startSourceLocation;
      const endSourceLocation = location?.endSourceLocation;
      if (startSourceLocation?.sourceNode && endSourceLocation?.sourceNode && this.#sourceDoc) {
        const range2 = this.#sourceDoc.createRange();
        this.#setRangeBoundary(range2, "start", startSourceLocation);
        this.#setRangeBoundary(range2, "end", endSourceLocation);
        if (!range2.collapsed || range2.toString()?.length) {
          return range2;
        }
      }
      const startUnitIndex = location?.startUnitIndex;
      const endUnitIndex = location?.endUnitIndex;
      if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) return null;
      const startUnit = this.#unitRecords[startUnitIndex];
      const endUnit = this.#unitRecords[endUnitIndex];
      if (!startUnit || !endUnit || !this.#sourceDoc) return null;
      const range = this.#sourceDoc.createRange();
      this.#setRangeBoundary(range, "start", this.#sourceLocationForUnitIndex(startUnitIndex, "start"));
      this.#setRangeBoundary(range, "end", this.#sourceLocationForUnitIndex(endUnitIndex, "end"));
      if (!range.collapsed || range.toString()?.length) {
        return range;
      }
      const pageIndex = resolvedPageIndex;
      const pageRecord = resolvedPageRecord;
      if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) {
        return range;
      }
      const pageRange = this.#sourceDoc.createRange();
      this.#setRangeBoundary(pageRange, "start", this.#sourceLocationForUnitIndex(pageRecord.startUnitIndex, "start"));
      this.#setRangeBoundary(pageRange, "end", this.#sourceLocationForUnitIndex(pageRecord.endUnitIndex, "end"));
      return pageRange;
    }
    visibleSourceRange(pageIndex) {
      return this.sourceRangeForLocation(this.captureLocationForPage(pageIndex));
    }
    pageIndexForAnchor(anchor) {
      if (typeof anchor === "number") {
        const count = this.pageCount();
        if (count <= 1) return 0;
        return Math.max(0, Math.min(count - 1, Math.round(anchor * (count - 1))));
      }
      if (!anchor) return 0;
      const index = this.#sourceUnitIndexForAnchor(anchor);
      return index != null ? this.#unitRecords[index]?.pageIndex ?? 0 : null;
    }
    getChunkIdForPage(pageIndex, columnIndex = 0) {
      const pageRecord = this.#pageRecords[pageIndex];
      if (!pageRecord) return null;
      const chunkRecord = pageRecord.chunkRecords.find((record) => record.columnIndex === columnIndex) || pageRecord.chunkRecords[0];
      return chunkRecord?.chunkId ?? null;
    }
    #effectivePageCount() {
      if (this.#pageRecords.length === 0) return 0;
      const lastPageRecord = this.#pageRecords[this.#pageRecords.length - 1];
      const hasOnlyEmptyChunks = lastPageRecord?.chunkRecords?.length > 0 && lastPageRecord.chunkRecords.every((record) => record.startUnitIndex == null);
      if (hasOnlyEmptyChunks && this.#buildState) {
        return Math.max(0, this.#pageRecords.length - 1);
      }
      return this.#pageRecords.length;
    }
    #runWithSuppressedMutations(callback) {
      const suppressMutations = this.#doc?.defaultView?.manabiWithTrackingStructureMutationSuppressed || ((fn2) => fn2());
      return suppressMutations(callback);
    }
    #prepareSourceSnapshot({ doc, runtime, root }) {
      const preservedSnapshot = preservedSourceSnapshotForRuntime(runtime);
      const liveRootIsPaginated = rootLooksPaginated(root);
      const currentContentURL = runtime?.manabiCurrentContentURL ?? doc?.URL ?? null;
      const preservedSnapshotMatchesCurrentContent = !preservedSnapshot?.contentURL || preservedSnapshot.contentURL === currentContentURL;
      if (this.#sourceContentURL && currentContentURL && this.#sourceContentURL !== currentContentURL) {
        logReaderPerf("ebook-layout-source-reset-content-url", {
          previousContentURL: this.#sourceContentURL,
          currentContentURL,
          layoutVersion: this.#layoutVersion
        });
        this.#normalizedRootHTML = null;
        this.#sourceDoc = null;
        this.#sourceRoot = null;
        this.#unitRecords = [];
        this.#unitIndicesBySourceNode = /* @__PURE__ */ new Map();
      }
      if (this.#normalizedRootHTML == null) {
        if (liveRootIsPaginated && preservedSnapshot && preservedSnapshotMatchesCurrentContent) {
          this.#normalizedRootHTML = preservedSnapshot.rootInnerHTML || null;
        } else {
          this.#normalizedRootHTML = root.innerHTML;
          root.innerHTML = this.#normalizedRootHTML;
          runtime?.manabiNormalizeLegacyTrackingStructure?.(doc);
          runtime?.manabiBuildSentenceArchive?.(doc);
          this.#normalizedRootHTML = root.innerHTML;
          const refreshedSnapshot = capturePreservedSourceSnapshot({ doc, root });
          storePreservedSourceSnapshot(runtime, refreshedSnapshot);
          this.#sourceContentURL = refreshedSnapshot?.contentURL ?? currentContentURL;
        }
        this.#sourceDoc = null;
        this.#sourceRoot = null;
      } else if (this.#sourceDoc instanceof Document && this.#sourceRoot instanceof HTMLElement && this.#unitRecords.length > 0 && (!currentContentURL || this.#sourceContentURL === currentContentURL)) {
        logReaderPerf("ebook-layout-source-snapshot-reused", {
          unitCount: this.#unitRecords.length,
          layoutVersion: this.#layoutVersion,
          contentURL: this.#sourceContentURL ?? null
        });
        return this.#unitRecords;
      } else {
        if (!liveRootIsPaginated) {
          runtime?.manabiBuildSentenceArchive?.(doc);
          const refreshedSnapshot = capturePreservedSourceSnapshot({ doc, root });
          storePreservedSourceSnapshot(runtime, refreshedSnapshot);
          this.#normalizedRootHTML = root.innerHTML;
          this.#sourceContentURL = refreshedSnapshot?.contentURL ?? currentContentURL;
        }
      }
      if (!(this.#sourceDoc instanceof Document) || !(this.#sourceRoot instanceof HTMLElement)) {
        this.#sourceDoc = doc.implementation.createHTMLDocument("");
        if (preservedSnapshot && preservedSnapshotMatchesCurrentContent) {
          applyStoredAttributes(this.#sourceDoc.documentElement, preservedSnapshot.documentElementAttributes);
          applyStoredAttributes(this.#sourceDoc.body, preservedSnapshot.bodyAttributes);
          this.#sourceDoc.body.className = preservedSnapshot.bodyClassName || "";
          this.#sourceDoc.body.innerHTML = preservedSnapshot.bodyHTML || "";
          this.#sourceContentURL = preservedSnapshot.contentURL ?? currentContentURL;
          logReaderPerf("ebook-layout-source-snapshot-restored", {
            layoutVersion: this.#layoutVersion,
            bodyHTMLLength: preservedSnapshot.bodyHTML?.length ?? 0,
            capturedAt: preservedSnapshot.capturedAt ?? null,
            liveRootWasPaginated: liveRootIsPaginated,
            contentURL: this.#sourceContentURL ?? null
          });
        } else {
          copyAttributes(doc.documentElement, this.#sourceDoc.documentElement);
          copyAttributes(doc.body, this.#sourceDoc.body);
          this.#sourceDoc.body.className = doc.body.className;
          this.#sourceDoc.body.innerHTML = doc.body.innerHTML;
          this.#sourceContentURL = currentContentURL;
        }
        this.#sourceRoot = resolveSectionRoot(this.#sourceDoc);
      }
      if (!(this.#sourceRoot instanceof HTMLElement)) {
        this.#unitRecords = [];
        this.#unitIndicesBySourceNode = /* @__PURE__ */ new Map();
        return [];
      }
      this.#unitRecords = collectEbookChunkUnits(this.#sourceRoot);
      this.#refreshUnitIndexMap();
      logReaderPerf("ebook-layout-source-snapshot-built", {
        unitCount: this.#unitRecords.length,
        layoutVersion: this.#layoutVersion
      });
      return this.#unitRecords;
    }
    #refreshUnitIndexMap() {
      this.#unitIndicesBySourceNode = /* @__PURE__ */ new Map();
      this.#unitRecords.forEach((unit, index) => {
        const indices = this.#unitIndicesBySourceNode.get(unit.sourceNode) || [];
        indices.push(index);
        this.#unitIndicesBySourceNode.set(unit.sourceNode, indices);
      });
    }
    #sourceUnitIndexForAnchor(anchor) {
      const unitCount = this.#unitRecords.length;
      if (unitCount <= 1) return unitCount === 0 ? null : 0;
      if (typeof anchor === "number") {
        return Math.max(0, Math.min(unitCount - 1, Math.round(anchor * (unitCount - 1))));
      }
      if (!anchor) return null;
      if (isRangeLike(anchor)) {
        const directIndex2 = this.#unitIndexForAnchorNode(anchor.startContainer, anchor.startOffset);
        if (directIndex2 != null) return directIndex2;
        const sentenceIdentifier2 = this.#sentenceIdentifierForNode(anchor.startContainer);
        return sentenceIdentifier2 ? this.#unitIndexForSentenceIdentifier(sentenceIdentifier2) : null;
      }
      const directIndex = this.#unitIndexForAnchorNode(anchor, 0);
      if (directIndex != null) return directIndex;
      const sentenceIdentifier = this.#sentenceIdentifierForNode(anchor);
      return sentenceIdentifier ? this.#unitIndexForSentenceIdentifier(sentenceIdentifier) : null;
    }
    #resolveTargetUnitIndex(anchor) {
      const unitCount = this.#unitRecords.length;
      if (unitCount <= 1) return 0;
      return this.#sourceUnitIndexForAnchor(anchor) ?? 0;
    }
    #resolveTargetUnitIndexFromLocationOrAnchor(location, anchor) {
      const anchorUnitIndex = this.#sourceUnitIndexForAnchor(anchor);
      const anchorSentenceIdentifier = this.#sentenceIdentifierForAnchor(anchor);
      if (Number.isFinite(anchorUnitIndex)) {
        const startUnitIndex = location?.startUnitIndex;
        const endUnitIndex = location?.endUnitIndex;
        if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex) || anchorUnitIndex >= startUnitIndex && anchorUnitIndex <= endUnitIndex) {
          return Math.max(0, Math.min(this.#unitRecords.length - 1, anchorUnitIndex));
        }
      }
      const locationAnchorUnitIndex = this.#sourceUnitIndexForLocation(location?.anchorSourceLocation) ?? this.#unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier) ?? location?.anchorUnitIndex;
      const locationSentenceIdentifier = location?.anchorSentenceIdentifier;
      const locationAnchorIsInRange = Number.isFinite(locationAnchorUnitIndex) && locationAnchorUnitIndex >= 0 && locationAnchorUnitIndex < this.#unitRecords.length;
      const locationMatchesAnchorSentence = !anchorSentenceIdentifier || !locationSentenceIdentifier || locationSentenceIdentifier === anchorSentenceIdentifier || this.#sentenceIdentifierForUnitIndex(locationAnchorUnitIndex) === anchorSentenceIdentifier;
      if (locationAnchorIsInRange && locationMatchesAnchorSentence) {
        return Math.max(0, Math.min(this.#unitRecords.length - 1, locationAnchorUnitIndex));
      }
      return this.#resolveTargetUnitIndex(anchor);
    }
    #createBuildState({
      doc,
      runtime,
      liveRoot,
      metrics,
      columnCount,
      units,
      layoutVersion,
      targetUnitIndex,
      targetSourceLocation
    }) {
      this.#removeStagingRoot();
      const root = createStagingRootForLiveRoot(liveRoot);
      if (!(root instanceof HTMLElement)) {
        throw new Error("Unable to create ebook layout staging root.");
      }
      this.#stagingRoot = root;
      root.innerHTML = "";
      root.classList.add("manabi-page-root");
      applyPageRootLayoutStyles(root);
      root.dataset.manabiLayoutVersion = String(layoutVersion);
      const pageViewportSize = resolvePageViewportSize(root);
      this.#pageRecords = [];
      updatePageRootLayoutExtent(root, {
        inlineSize: pageViewportSize.inlineSize,
        pageCount: 1
      });
      const pageNode = doc.createElement("div");
      pageNode.className = "manabi-page";
      pageNode.dataset.manabiPageIndex = "0";
      applyPageLayoutStyles(pageNode, {
        ...pageViewportSize,
        pageIndex: 0
      });
      root.appendChild(pageNode);
      const pageRecord = {
        pageIndex: 0,
        pageNode,
        startUnitIndex: null,
        endUnitIndex: null,
        chunkRecords: []
      };
      this.#pageRecords.push(pageRecord);
      const { chunkNode, chunkBody } = createChunkSection({
        doc,
        pageNode,
        pageIndex: 0,
        columnIndex: 0,
        layoutVersion,
        runtime
      });
      const chunkRecord = {
        pageIndex: 0,
        columnIndex: 0,
        chunkId: chunkNode.dataset.manabiChunkId,
        chunkNode,
        startUnitIndex: null,
        endUnitIndex: null
      };
      pageRecord.chunkRecords.push(chunkRecord);
      return {
        doc,
        runtime,
        root,
        liveRoot,
        metrics,
        columnCount,
        units,
        layoutVersion,
        targetUnitIndex,
        targetSourceLocation,
        stopAfterPageIndex: null,
        pageViewportSize,
        unitIndex: 0,
        pageIndex: 0,
        columnIndex: 0,
        pageNode,
        pageRecord,
        chunkNode,
        chunkBody,
        chunkRecord,
        appendState: createChunkAppendState()
      };
    }
    #assignUnitToCurrentChunk(state, unitIndex) {
      const unit = state.units[unitIndex];
      unit.pageIndex = state.pageIndex;
      unit.columnIndex = state.columnIndex;
      unit.chunkId = state.chunkRecord.chunkId;
      if (state.pageRecord.startUnitIndex == null) state.pageRecord.startUnitIndex = unitIndex;
      state.pageRecord.endUnitIndex = unitIndex;
      if (state.chunkRecord.startUnitIndex == null) state.chunkRecord.startUnitIndex = unitIndex;
      state.chunkRecord.endUnitIndex = unitIndex;
      if (state.stopAfterPageIndex == null && (this.#unitContainsSourceLocation(unit, state.targetSourceLocation) || unitIndex === state.targetUnitIndex)) {
        state.stopAfterPageIndex = state.pageIndex;
      }
    }
    #advanceChunk(state) {
      state.columnIndex += 1;
      if (state.columnIndex >= state.columnCount) {
        state.pageIndex += 1;
        state.columnIndex = 0;
        state.pageNode = state.doc.createElement("div");
        state.pageNode.className = "manabi-page";
        state.pageNode.dataset.manabiPageIndex = String(state.pageIndex);
        applyPageLayoutStyles(state.pageNode, {
          ...state.pageViewportSize,
          pageIndex: state.pageIndex
        });
        state.root.appendChild(state.pageNode);
        updatePageRootLayoutExtent(state.root, {
          inlineSize: state.pageViewportSize.inlineSize,
          pageCount: state.pageIndex + 1
        });
        state.pageRecord = {
          pageIndex: state.pageIndex,
          pageNode: state.pageNode,
          startUnitIndex: null,
          endUnitIndex: null,
          chunkRecords: []
        };
        this.#pageRecords.push(state.pageRecord);
      }
      const next = createChunkSection({
        doc: state.doc,
        pageNode: state.pageNode,
        pageIndex: state.pageIndex,
        columnIndex: state.columnIndex,
        layoutVersion: state.layoutVersion,
        runtime: state.runtime
      });
      state.chunkNode = next.chunkNode;
      state.chunkBody = next.chunkBody;
      state.chunkRecord = {
        pageIndex: state.pageIndex,
        columnIndex: state.columnIndex,
        chunkId: state.chunkNode.dataset.manabiChunkId,
        chunkNode: state.chunkNode,
        startUnitIndex: null,
        endUnitIndex: null
      };
      state.pageRecord.chunkRecords.push(state.chunkRecord);
      state.appendState = createChunkAppendState();
    }
    #continueBuilding() {
      const state = this.#buildState;
      if (!state) return;
      while (state.unitIndex < state.units.length) {
        if (state.stopAfterPageIndex != null && state.pageIndex > state.stopAfterPageIndex) {
          break;
        }
        const unit = state.units[state.unitIndex];
        const appendRecord = appendChunkUnit(state.chunkBody, state.appendState, unit);
        if (state.appendState.unitCount <= 1) {
          if (chunkBodyHasOverflow(state.chunkBody, state.metrics.vertical)) {
            const splitUnits2 = splitChunkUnitForFit(unit);
            if (splitUnits2 && splitUnits2.length > 1) {
              revertChunkUnit(state.appendState, appendRecord);
              state.units.splice(state.unitIndex, 1, ...splitUnits2);
              continue;
            }
            if (!shouldDelayChunkOverflowBoundary(state.chunkBody, state.appendState, unit)) {
              allowOversizeChunkOverflow(state.chunkNode, state.chunkBody);
            }
          }
          this.#assignUnitToCurrentChunk(state, state.unitIndex);
          state.unitIndex += 1;
          continue;
        }
        if (!chunkBodyHasOverflow(state.chunkBody, state.metrics.vertical)) {
          this.#assignUnitToCurrentChunk(state, state.unitIndex);
          state.unitIndex += 1;
          continue;
        }
        if (shouldDelayChunkOverflowBoundary(state.chunkBody, state.appendState, unit)) {
          this.#assignUnitToCurrentChunk(state, state.unitIndex);
          state.unitIndex += 1;
          continue;
        }
        revertChunkUnit(state.appendState, appendRecord);
        const splitUnits = splitChunkUnitForFit(unit);
        if (splitUnits && splitUnits.length > 1) {
          state.units.splice(state.unitIndex, 1, ...splitUnits);
          continue;
        }
        this.#advanceChunk(state);
      }
      this.#refreshUnitIndexMap();
      if (state.unitIndex >= state.units.length) {
        this.#trimTrailingEmptyPage();
        this.#buildState = null;
        return;
      }
      this.#buildState = state;
    }
    #trimTrailingEmptyPage() {
      const lastPageRecord = this.#pageRecords[this.#pageRecords.length - 1];
      if (!lastPageRecord?.chunkRecords?.length) return;
      const hasOnlyEmptyChunks = lastPageRecord.chunkRecords.every((record) => record.startUnitIndex == null);
      if (!hasOnlyEmptyChunks) return;
      lastPageRecord.pageNode.remove();
      this.#pageRecords.pop();
    }
    #removeStagingRoot() {
      this.#stagingRoot?.remove?.();
      this.#stagingRoot = null;
    }
    #commitStagingRootToLiveRoot({ liveRoot, stagingRoot }) {
      if (!(liveRoot instanceof HTMLElement) || !(stagingRoot instanceof HTMLElement)) return;
      const commitStart = perfNow();
      liveRoot.className = stagingRoot.className;
      liveRoot.dataset.manabiLayoutVersion = stagingRoot.dataset.manabiLayoutVersion || "";
      liveRoot.style.cssText = stagingRoot.style.cssText;
      liveRoot.innerHTML = stagingRoot.innerHTML;
      logReaderPerf("ebook-layout-commit-live-root", {
        childCount: liveRoot.childElementCount,
        htmlLength: liveRoot.innerHTML.length,
        commitInnerHTMLDurationMs: Math.round((perfNow() - commitStart) * 100) / 100
      });
    }
    #syncChunkSourceMetadata() {
      for (const pageRecord of this.#pageRecords) {
        for (const chunkRecord of pageRecord.chunkRecords || []) {
          const chunkNode = chunkRecord?.chunkNode;
          if (!(chunkNode instanceof HTMLElement)) continue;
          const startUnitIndex = chunkRecord.startUnitIndex;
          const endUnitIndex = chunkRecord.endUnitIndex;
          if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) continue;
          chunkNode.dataset.manabiSourceStartUnitIndex = String(startUnitIndex);
          chunkNode.dataset.manabiSourceEndUnitIndex = String(endUnitIndex);
          const startSentenceIdentifier = this.#sentenceIdentifierForUnitIndex(startUnitIndex);
          const endSentenceIdentifier = this.#sentenceIdentifierForUnitIndex(endUnitIndex);
          if (startSentenceIdentifier) {
            chunkNode.dataset.manabiSourceStartSentenceIdentifier = startSentenceIdentifier;
          } else {
            delete chunkNode.dataset.manabiSourceStartSentenceIdentifier;
          }
          if (endSentenceIdentifier) {
            chunkNode.dataset.manabiSourceEndSentenceIdentifier = endSentenceIdentifier;
          } else {
            delete chunkNode.dataset.manabiSourceEndSentenceIdentifier;
          }
        }
      }
    }
    #scheduleWarmup() {
      this.#cancelWarmup();
      if (!this.#buildState || !(this.#doc?.defaultView instanceof Window)) return;
      const token = ++this.#warmupToken;
      logReaderPerf("ebook-layout-warmup-scheduled", {
        layoutVersion: this.#layoutVersion,
        pageCount: this.pageCount()
      });
      this.#warmupTimer = this.#doc.defaultView.setTimeout(() => {
        this.#warmupTimer = null;
        this.#warmRemainingPages(token);
      }, WARMUP_DELAY_MS);
    }
    #cancelWarmup() {
      if (this.#warmupTimer != null && this.#doc?.defaultView) {
        this.#doc.defaultView.clearTimeout(this.#warmupTimer);
      }
      this.#warmupTimer = null;
      this.#warmupToken += 1;
    }
    #warmRemainingPages(token) {
      if (token !== this.#warmupToken || !this.#buildState) return;
      const doc = this.#doc;
      const runtime = doc?.defaultView;
      const root = this.#root;
      if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return;
      this.#runWithSuppressedMutations(() => {
        if (!this.#buildState) return;
        const warmupStart = perfNow();
        const pageCountBefore = this.pageCount();
        const nextVisiblePageIndex = Math.max(0, this.pageCount() + WARMUP_PAGE_BATCH - 1);
        this.#buildState.stopAfterPageIndex = Math.max(
          nextVisiblePageIndex,
          this.#buildState.stopAfterPageIndex ?? -1
        );
        this.#continueBuilding();
        this.#commitStagingRootToLiveRoot({
          liveRoot: root,
          stagingRoot: this.#buildState?.root ?? this.#stagingRoot
        });
        this.#refreshLiveRoot({
          runtime,
          root,
          complete: this.isLayoutComplete()
        });
        logReaderPerf("ebook-layout-warmup-batch", {
          layoutVersion: this.#layoutVersion,
          pageCountBefore,
          pageCountAfter: this.pageCount(),
          builtPageCount: Math.max(0, this.pageCount() - pageCountBefore),
          durationMs: Math.round((perfNow() - warmupStart) * 100) / 100,
          layoutComplete: this.isLayoutComplete()
        });
        if (!this.isLayoutComplete()) {
          this.#scheduleWarmup();
        } else {
          this.#removeStagingRoot();
          logReaderPerf("ebook-layout-warmup-complete", {
            layoutVersion: this.#layoutVersion,
            pageCount: this.pageCount()
          });
        }
      });
    }
    #refreshLiveRoot({ runtime, root, complete }) {
      this.#syncChunkSourceMetadata();
      runtime?.manabiEnsureTrackingFooter?.();
      runtime?.manabiEnsureTrackingMarkers?.(root);
      if (complete) {
        runtime?.manabiMarkSentenceOwnershipByTerminalSegment?.(root);
        root.querySelectorAll(".manabi-page-column-chunk").forEach((sectionNode) => {
          runtime?.manabiFinalizeTrackingSectionState?.(sectionNode);
        });
        runtime?.manabiWireAllTrackingButtons?.();
        runtime?.manabi_refreshArticleReadingProgress?.();
        runtime?.manabi_refreshSectionsMarkedAsRead?.();
      } else {
        root.querySelectorAll(".manabi-page-column-chunk .manabi-tracking-button").forEach((buttonNode) => {
          if (buttonNode instanceof HTMLButtonElement) {
            buttonNode.disabled = true;
            buttonNode.setAttribute("aria-pressed", "false");
          }
        });
      }
      try {
        runtime?.manabiTategakiText?.clear?.({ root });
        runtime?.manabiTategakiText?.apply?.({
          root,
          vertical: this.#buildState?.metrics?.vertical ?? root.ownerDocument?.body?.classList?.contains?.("reader-vertical-writing") === true,
          isReaderMode: true,
          isEbook: true
        });
      } catch (_error) {
      }
      if (this.#doc?.documentElement) {
        this.#doc.documentElement.dataset.manabiLayoutComplete = complete ? "true" : "false";
      }
      if (complete) {
        try {
          this.#doc?.defaultView?.dispatchEvent?.(new CustomEvent("manabi-ebook-layout-complete", {
            detail: {
              layoutVersion: this.#layoutVersion,
              pageCount: this.pageCount()
            }
          }));
        } catch (_error) {
        }
      }
    }
    #normalizeSourceAnchor(anchor, fallbackPageIndex = 0) {
      const sourceDoc = this.#sourceDoc;
      const anchorDoc = anchor?.startContainer?.getRootNode?.() ?? anchor?.ownerDocument ?? null;
      if (sourceDoc && anchorDoc === sourceDoc) {
        return anchor;
      }
      return this.sourceRangeForPage(fallbackPageIndex) || this.sourceRangeForPage(0) || this.#currentSourceAnchor;
    }
    #sourceAnchorForUnitIndex(unitIndex) {
      return this.#sourceAnchorForLocation(this.#sourceLocationForUnitIndex(unitIndex, "start"));
    }
    #sourceAnchorForSentenceIdentifier(sentenceIdentifier) {
      return this.#sourceAnchorForLocation(this.#sourceLocationForSentenceIdentifier(sentenceIdentifier));
    }
    #sourceLocationForAnchor(anchor) {
      if (!anchor) return null;
      if (isRangeLike(anchor)) {
        return this.#sourceLocationForBoundaryNode(anchor.startContainer, anchor.startOffset) || this.#sourceLocationForNode(anchor.startContainer);
      }
      return this.#sourceLocationForNode(anchor);
    }
    #sourceLocationForUnitIndex(unitIndex, edge = "start") {
      const unit = this.#unitRecords[unitIndex];
      if (!unit) return null;
      return {
        sourceNode: unit.sourceNode,
        sourceOffset: unit.type === "text" ? edge === "end" ? unit.sourceEndOffset : unit.sourceStartOffset : 0,
        edge
      };
    }
    #sourceLocationForSentenceIdentifier(sentenceIdentifier) {
      const unitIndex = this.#unitIndexForSentenceIdentifier(sentenceIdentifier);
      return Number.isFinite(unitIndex) ? this.#sourceLocationForUnitIndex(unitIndex, "start") : null;
    }
    #sourceAnchorForLocation(location) {
      const sourceNode = location?.sourceNode;
      if (!sourceNode || !this.#sourceDoc) return null;
      const range = this.#sourceDoc.createRange();
      this.#setRangeBoundary(range, "start", location);
      range.collapse(true);
      return range;
    }
    #unitContainsSourceLocation(unit, location) {
      if (!unit || !location?.sourceNode || unit.sourceNode !== location.sourceNode) {
        return false;
      }
      if (unit.type !== "text") {
        return true;
      }
      const sourceOffset = Number.isFinite(location.sourceOffset) ? location.sourceOffset : 0;
      return sourceOffset >= unit.sourceStartOffset && sourceOffset < unit.sourceEndOffset;
    }
    #sentenceIdentifierForNode(node) {
      if (!node) return null;
      const sentenceNode = node.nodeType === Node.ELEMENT_NODE ? node.closest?.("manabi-sentence") : node.parentElement?.closest?.("manabi-sentence");
      return sentenceNode?.dataset?.sentenceIdentifier || null;
    }
    #sentenceIdentifierForAnchor(anchor) {
      if (!anchor) return null;
      if (isRangeLike(anchor)) {
        return this.#sentenceIdentifierForNode(anchor.startContainer);
      }
      return this.#sentenceIdentifierForNode(anchor);
    }
    #sentenceIdentifierForUnitIndex(unitIndex) {
      const unit = this.#unitRecords[unitIndex];
      return this.#sentenceIdentifierForNode(unit?.sourceNode);
    }
    #sourceUnitIndexForLocation(location) {
      const anchor = this.#sourceAnchorForLocation(location);
      return this.#sourceUnitIndexForAnchor(anchor);
    }
    #setRangeBoundary(range, edge, location) {
      const sourceNode = location?.sourceNode;
      if (!range || !sourceNode) return;
      const isStart = edge === "start";
      if (sourceNode.nodeType === Node.TEXT_NODE) {
        const offset = Math.max(0, Number.isFinite(location?.sourceOffset) ? location.sourceOffset : 0);
        if (isStart) {
          range.setStart(sourceNode, offset);
        } else {
          range.setEnd(sourceNode, offset);
        }
        return;
      }
      if (sourceNode.nodeType === Node.ELEMENT_NODE) {
        const boundaryOffset = isStart ? 0 : sourceNode.childNodes.length;
        if (isStart) {
          range.setStart(sourceNode, boundaryOffset);
        } else {
          range.setEnd(sourceNode, boundaryOffset);
        }
        return;
      }
      if (isStart) {
        range.setStartBefore(sourceNode);
      } else {
        range.setEndAfter(sourceNode);
      }
    }
    #sourceLocationForBoundaryNode(node, offset = 0) {
      if (!node) return null;
      if (node.nodeType === Node.TEXT_NODE) {
        return {
          sourceNode: node,
          sourceOffset: Math.max(0, Math.min(node.nodeValue?.length ?? 0, offset)),
          edge: "start"
        };
      }
      if (node.nodeType !== Node.ELEMENT_NODE) {
        return this.#sourceLocationForNode(node);
      }
      const childNodes = Array.from(node.childNodes || []);
      const preferredChild = childNodes[offset] || childNodes[childNodes.length - 1] || null;
      return this.#sourceLocationForNode(preferredChild) || this.#sourceLocationForNode(node);
    }
    #sourceLocationForNode(node) {
      if (!node) return null;
      if (node.nodeType === Node.TEXT_NODE) {
        return {
          sourceNode: node,
          sourceOffset: 0,
          edge: "start"
        };
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return null;
      const directUnitIndices = this.#unitIndicesBySourceNode.get(node);
      if (directUnitIndices?.length) {
        return this.#sourceLocationForUnitIndex(directUnitIndices[0], "start");
      }
      const walker = node.ownerDocument?.createTreeWalker?.(
        node,
        NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
      );
      let current = walker?.currentNode;
      while (current) {
        if (current !== node) {
          const currentUnitIndices = this.#unitIndicesBySourceNode.get(current);
          if (currentUnitIndices?.length) {
            return this.#sourceLocationForUnitIndex(currentUnitIndices[0], "start");
          }
          if (current.nodeType === Node.TEXT_NODE && shouldKeepChunkTextNode(current)) {
            return {
              sourceNode: current,
              sourceOffset: 0,
              edge: "start"
            };
          }
        }
        current = walker?.nextNode?.() || null;
      }
      return {
        sourceNode: node,
        sourceOffset: 0,
        edge: "start"
      };
    }
    #unitIndexForSentenceIdentifier(sentenceIdentifier) {
      if (!sentenceIdentifier) return null;
      for (let index = 0; index < this.#unitRecords.length; index += 1) {
        if (this.#sentenceIdentifierForUnitIndex(index) === sentenceIdentifier) {
          return index;
        }
      }
      return null;
    }
    #unitIndexForAnchorNode(node, offset = 0) {
      if (!node) return null;
      if (node.nodeType === Node.TEXT_NODE) {
        const indices = this.#unitIndicesBySourceNode.get(node);
        if (indices?.length) {
          for (const index of indices) {
            const unit = this.#unitRecords[index];
            if (unit.type === "text" && offset < unit.sourceEndOffset) {
              return index;
            }
          }
          return indices[indices.length - 1];
        }
      }
      if (node.nodeType === Node.ELEMENT_NODE) {
        const directIndices = this.#unitIndicesBySourceNode.get(node);
        if (directIndices?.length) return directIndices[0];
        const walker = node.ownerDocument?.createTreeWalker?.(
          node,
          NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
        );
        let current = walker?.currentNode;
        while (current) {
          const currentIndices = this.#unitIndicesBySourceNode.get(current);
          if (currentIndices?.length) return currentIndices[0];
          current = walker.nextNode();
        }
      }
      let ancestor = node.parentNode;
      while (ancestor) {
        const indices = this.#unitIndicesBySourceNode.get(ancestor);
        if (indices?.length) return indices[0];
        ancestor = ancestor.parentNode;
      }
      return null;
    }
  };

  // paginator.js
  var CSS_DEFAULTS = {
    gapPct: 5,
    minGapPx: 36,
    topMarginPx: 0,
    //4,
    bottomMarginPx: 69,
    sideMarginPx: 32,
    maxInlineSizePx: 720,
    maxBlockSizePx: 1440,
    maxColumnCount: 2,
    maxColumnCountPortrait: 1
  };
  var COLUMNIZATION_CHARACTER_THRESHOLDS = {
    verticalFullWidthCharacters: 40,
    horizontalFullWidthCharacters: 30,
    sampleCount: 20
  };
  var parsePixelValue = (value) => {
    if (value == null) return null;
    const parsed = Number.parseFloat(String(value).trim());
    return Number.isFinite(parsed) ? parsed : null;
  };
  var fallbackFullWidthCharacterAdvancePx = (doc) => {
    const style = doc?.defaultView?.getComputedStyle?.(doc?.body || doc?.documentElement);
    const fontSize = parsePixelValue(style?.fontSize || style?.getPropertyValue?.("font-size"));
    return Math.max(1, fontSize || 16);
  };
  var measureFullWidthCharacterAdvancePx = ({ doc, vertical }) => {
    const container = doc?.body || doc?.documentElement;
    if (!(container instanceof HTMLElement)) {
      return fallbackFullWidthCharacterAdvancePx(doc);
    }
    const probe = doc.createElement("span");
    probe.textContent = "\u6F22".repeat(COLUMNIZATION_CHARACTER_THRESHOLDS.sampleCount);
    probe.setAttribute("aria-hidden", "true");
    Object.assign(probe.style, {
      position: "absolute",
      visibility: "hidden",
      pointerEvents: "none",
      whiteSpace: "nowrap",
      inset: "0",
      font: "inherit",
      lineHeight: "inherit",
      letterSpacing: "normal",
      writingMode: vertical ? "vertical-rl" : "horizontal-tb",
      textOrientation: vertical ? "upright" : "mixed"
    });
    container.appendChild(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    const measuredSpan = vertical ? rect.height : rect.width;
    if (measuredSpan > 0) return measuredSpan / COLUMNIZATION_CHARACTER_THRESHOLDS.sampleCount;
    return fallbackFullWidthCharacterAdvancePx(doc);
  };
  var resolveColumnizationThreshold = ({ doc, vertical }) => {
    const fullWidthCharacterAdvancePx = Math.max(
      1,
      measureFullWidthCharacterAdvancePx({ doc, vertical })
    );
    const fullWidthCharacterThreshold = vertical ? COLUMNIZATION_CHARACTER_THRESHOLDS.verticalFullWidthCharacters : COLUMNIZATION_CHARACTER_THRESHOLDS.horizontalFullWidthCharacters;
    const columnizationThresholdPx = Math.max(
      1,
      fullWidthCharacterAdvancePx * fullWidthCharacterThreshold
    );
    return {
      fullWidthCharacterAdvancePx,
      fullWidthCharacterThreshold,
      columnizationThresholdPx
    };
  };
  var CHEVRON_VISUALS_ENABLED = true;
  var CHEVRON_SWIPE_PREVIEW_ENABLED = false;
  var logBug = (event, detail = {}) => {
    try {
      return globalThis.logBug?.(event, detail);
    } catch (_error) {
      return void 0;
    }
  };
  var wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  var debounce = (fn2, delay) => {
    let timeout;
    let isLeadingInvoked = false;
    return function(...args) {
      const context = this;
      if (!timeout) {
        fn2.apply(context, args);
        isLeadingInvoked = true;
        timeout = setTimeout(() => {
          timeout = null;
          if (!isLeadingInvoked) {
            fn2.apply(context, args);
          }
        }, delay);
      } else {
        isLeadingInvoked = false;
      }
    };
  };
  var lerp = (min, max, x2) => x2 * (max - min) + min;
  var easeOutQuad = (x2) => 1 - (1 - x2) * (1 - x2);
  var animate = (a2, b2, duration, ease, render) => new Promise((resolve) => {
    let start;
    const step = (now) => {
      start ??= now;
      const fraction = Math.min(1, (now - start) / duration);
      render(lerp(a2, b2, ease(fraction)));
      if (fraction < 1) requestAnimationFrame(step);
      else resolve();
    };
    requestAnimationFrame(step);
  });
  var nextFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));
  var requestTrackingSizeCache = (payload) => new Promise((resolve) => {
    try {
      const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER];
      if (!handler?.postMessage) return resolve(null);
      const requestId = `cache-${Date.now()}-${trackingSizeCacheRequestCounter++}`;
      trackingSizeCacheResolvers.set(requestId, resolve);
      handler.postMessage({ requestId, ...payload });
    } catch (error) {
      resolve(null);
    }
  });
  globalThis.manabiResolveTrackingSizeCache = function(requestId, entries) {
    const resolver = trackingSizeCacheResolvers.get(requestId);
    if (resolver) {
      trackingSizeCacheResolvers.delete(requestId);
      resolver(entries);
    }
  };
  var MANABI_TRACKING_SECTION_CLASS = "manabi-tracking-section";
  var MANABI_TRACKING_SECTION_SELECTOR = `.${MANABI_TRACKING_SECTION_CLASS}`;
  var MANABI_TRACKING_SECTION_VISIBLE_CLASS = "manabi-tracking-section-visible";
  var MANABI_TRACKING_PREBAKE_HIDDEN_CLASS = "manabi-prebake-hidden";
  var MANABI_TRACKING_PREBAKE_HIDE_ENABLED = true;
  var MANABI_TRACKING_SIZE_BAKED_ATTR = "data-manabi-size-baked";
  var MANABI_TRACKING_SIZE_BAKE_ENABLED = true;
  var MANABI_RENDERER_SENTINEL_ADJUST_ENABLED = true;
  var MANABI_TRACKING_SIZE_BAKE_BATCH_SIZE = 5;
  var MANABI_TRACKING_SIZE_BAKING_OPTIMIZED = true;
  var MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED = true;
  var MANABI_TRACKING_SIZE_BAKING_BODY_CLASS = "manabi-tracking-size-baking";
  var MANABI_TRACKING_FORCE_VISIBLE_CLASS = "manabi-tracking-force-visible";
  var MANABI_TRACKING_SECTION_BAKING_CLASS = "manabi-tracking-section-baking";
  var MANABI_TRACKING_SECTION_HIDDEN_CLASS = "manabi-tracking-section-hidden";
  var MANABI_TRACKING_SECTION_BAKED_CLASS = "manabi-tracking-section-baked";
  var MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS = "manabi-tracking-section-bake-skipped";
  var MANABI_TRACKING_SIZE_BAKE_STYLE_ID = "manabi-tracking-size-bake-style";
  var MANABI_TRACKING_SIZE_STABLE_MAX_EVENTS = 120;
  var MANABI_TRACKING_SIZE_STABLE_REQUIRED_STREAK = 2;
  var MANABI_TRACKING_DOC_STABLE_MAX_EVENTS = 180;
  var MANABI_TRACKING_DOC_STABLE_REQUIRED_STREAK = 2;
  var MANABI_TRACKING_CACHE_HANDLER = globalThis.MANABI_TRACKING_CACHE_HANDLER || "trackingSizeCache";
  globalThis.MANABI_TRACKING_CACHE_HANDLER = MANABI_TRACKING_CACHE_HANDLER;
  var MANABI_TRACKING_CACHE_VERSION = "v1";
  var MANABI_SENTINEL_ROOT_MARGIN_PX = 64;
  var getLiveChunkPageCount = (doc) => {
    const count = doc?.querySelectorAll?.(".manabi-page")?.length ?? 0;
    return count > 0 ? count : null;
  };
  var trackingSizeCacheResolvers = /* @__PURE__ */ new Map();
  var trackingSizeCacheRequestCounter = 0;
  var setSameDocumentHostTurnDiagnostics = (detail) => {
    try {
      globalThis.manabiSameDocumentHostTurnDiagnostics = {
        ...globalThis.manabiSameDocumentHostTurnDiagnostics || {},
        ...detail
      };
    } catch (_error) {
    }
  };
  var logEBookPerf = (event, detail = {}) => ({ event, ...detail });
  var logEBookResize = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      const line = `# EBOOK RESIZE ${JSON.stringify(payload)}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
      try {
        console.log("# EBOOK RESIZE fallback", event, detail, error);
      } catch (_2) {
      }
    }
  };
  var logEBookFlash = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      const line = `# EBOOKFLASH ${JSON.stringify(payload)}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
      try {
        console.log("# EBOOKFLASH fallback", event, detail, error);
      } catch (_2) {
      }
    }
  };
  var logEBookBakeCounter = 0;
  var LOG_EBOOK_BAKE_LIMIT = 400;
  var logEBookBake = (event, detail = {}) => {
    if (logEBookBakeCounter >= LOG_EBOOK_BAKE_LIMIT) return;
    logEBookBakeCounter += 1;
    try {
      const payload = { event, ...detail };
      const line = `# EBOOKBAKE ${JSON.stringify(payload)}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
      try {
        console.log("# EBOOKBAKE fallback", event, detail, error);
      } catch (_2) {
      }
    }
  };
  var MANABI_PAGE_NUM_WHITELIST = /* @__PURE__ */ new Set([
    // Core pagination signals
    "nav:set-page-targets",
    "nav:total-pages-source",
    "nav:page-metrics",
    "relocate",
    "relocate:label",
    "relocate:detail",
    "afterScroll:metrics",
    // Bake/cache checkpoints (still useful but low volume)
    "bake:reset-state",
    "bake:reveal-prebake-content",
    "cache:apply",
    "cache:container-apply",
    "tracking-size-skip-writing-mode",
    // Paging outcomes (omit per-frame size churn)
    "pages",
    "size:anomaly"
  ]);
  var logEBookPageNum = (event, detail = {}) => {
    try {
      const verbose = !!globalThis.manabiPageNumVerbose;
      const allow = verbose || MANABI_PAGE_NUM_WHITELIST.has(event);
      if (!allow) return;
      const payload = { event, ...detail };
      const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
      try {
        console.log("# EBOOKK PAGENUM fallback", event, detail, error);
      } catch (_2) {
      }
    }
  };
  var logEBookPageNumCounter = 0;
  var LOG_EBOOK_PAGE_NUM_LIMIT = 1200;
  var logEBookPageNumLimited = (event, detail = {}) => {
    if (logEBookPageNumCounter >= LOG_EBOOK_PAGE_NUM_LIMIT) return;
    logEBookPageNumCounter += 1;
    logEBookPageNum(event, { count: logEBookPageNumCounter, ...detail });
  };
  var MANABI_SAME_DOCUMENT_RENDERER_ENABLED = true;
  var applyVerticalWritingClass = (doc, isVertical) => {
    const enable = !!isVertical;
    try {
      doc?.body?.classList?.toggle("reader-vertical-writing", enable);
    } catch (_2) {
    }
  };
  var applyTategakiDisplayTransform = (doc, isVertical) => {
    if (!doc?.body) return;
    try {
      globalThis.manabiApplyTategakiDisplayTransformToDocument?.(doc, {
        vertical: !!isVertical,
        isReaderMode: doc.body.classList.contains("readability-mode"),
        isEbook: true,
        root: doc.getElementById?.("reader-content") || doc.body
      });
    } catch (_2) {
    }
  };
  var summarizeAnchor = (anchor) => {
    if (anchor == null) return "null";
    if (typeof anchor === "number") return `fraction:${Number(anchor).toFixed(6)}`;
    if (typeof anchor === "function") return "function";
    if (anchor?.startContainer) return "range";
    if (anchor?.nodeType === Node.ELEMENT_NODE) return `element:${anchor.tagName ?? "unknown"}`;
    if (anchor?.nodeType) return `nodeType:${anchor.nodeType}`;
    return typeof anchor;
  };
  var snapshotInlineStyleProperty = (element, property) => {
    if (!(element instanceof HTMLElement)) return null;
    const value = element.style.getPropertyValue(property);
    if (!value) return null;
    const priority = element.style.getPropertyPriority(property);
    return {
      value,
      priority
    };
  };
  var restoreInlineStyleProperty = (element, property, snapshot) => {
    if (!(element instanceof HTMLElement)) return;
    if (snapshot) element.style.setProperty(property, snapshot.value, snapshot.priority);
    else element.style.removeProperty(property);
  };
  var preBakeDisplaySnapshots = /* @__PURE__ */ new WeakMap();
  var hideDocumentContentForPreBake = (doc) => {
    if (!MANABI_TRACKING_PREBAKE_HIDE_ENABLED) return null;
    const target = doc?.getElementById?.("reader-content") || doc?.body;
    if (!(target instanceof HTMLElement)) return null;
    if (preBakeDisplaySnapshots.has(doc)) return target;
    const snapshot = snapshotInlineStyleProperty(target, "display");
    preBakeDisplaySnapshots.set(doc, { target, snapshot });
    const beforeRect = target.getBoundingClientRect?.();
    target.classList.add(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS);
    target.style.setProperty("display", "none", "important");
    const afterRect = target.getBoundingClientRect?.();
    logEBookFlash("prebake-hide", {
      url: doc?.URL || null,
      targetId: target.id || null,
      beforeRect: beforeRect ? {
        width: Math.round(beforeRect.width),
        height: Math.round(beforeRect.height)
      } : null,
      afterRect: afterRect ? {
        width: Math.round(afterRect.width),
        height: Math.round(afterRect.height)
      } : null
    });
    logEBookPageNumLimited("bake:hide-doc", {
      url: doc?.URL || null,
      targetId: target.id || null,
      beforeRect: beforeRect ? {
        width: Math.round(beforeRect.width),
        height: Math.round(beforeRect.height)
      } : null,
      afterRect: afterRect ? {
        width: Math.round(afterRect.width),
        height: Math.round(afterRect.height)
      } : null
    });
    logEBookPerf("prebake-hide", {
      url: doc?.URL || null,
      targetId: target.id || null
    });
    return target;
  };
  var revealDocumentContentForBake = (doc) => {
    if (!MANABI_TRACKING_PREBAKE_HIDE_ENABLED) return;
    if (!doc) return;
    const entry = preBakeDisplaySnapshots.get(doc);
    if (!entry) return;
    const { target, snapshot } = entry;
    const beforeRect = target?.getBoundingClientRect?.();
    if (target instanceof HTMLElement) {
      target.classList.remove(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS);
      restoreInlineStyleProperty(target, "display", snapshot);
    }
    const afterRect = target?.getBoundingClientRect?.();
    logEBookFlash("prebake-reveal", {
      url: doc?.URL || null,
      targetId: target?.id || null,
      beforeRect: beforeRect ? {
        width: Math.round(beforeRect.width),
        height: Math.round(beforeRect.height)
      } : null,
      afterRect: afterRect ? {
        width: Math.round(afterRect.width),
        height: Math.round(afterRect.height)
      } : null
    });
    logEBookPageNumLimited("bake:reveal-doc", {
      url: doc?.URL || null,
      targetId: target?.id || null,
      beforeRect: beforeRect ? {
        width: Math.round(beforeRect.width),
        height: Math.round(beforeRect.height)
      } : null,
      afterRect: afterRect ? {
        width: Math.round(afterRect.width),
        height: Math.round(afterRect.height)
      } : null
    });
    logEBookPerf("prebake-reveal", {
      url: doc?.URL || null,
      targetId: target?.id || null
    });
    preBakeDisplaySnapshots.delete(doc);
  };
  var formatPx = (value) => {
    if (!Number.isFinite(value)) return "0px";
    const rounded = Math.max(0, Math.round(value * 1e3) / 1e3);
    return `${rounded}px`;
  };
  var ensureTrackingSizeBakeStyles = (doc) => {
    if (!MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) return;
    if (!doc?.head) return;
    if (doc.getElementById(MANABI_TRACKING_SIZE_BAKE_STYLE_ID)) return;
    const style = doc.createElement("style");
    style.id = MANABI_TRACKING_SIZE_BAKE_STYLE_ID;
    style.textContent = `body.${MANABI_TRACKING_SIZE_BAKING_BODY_CLASS} { visibility: hidden !important; }
.${MANABI_TRACKING_SECTION_CLASS} { contain: paint style !important; }
.${MANABI_TRACKING_SECTION_HIDDEN_CLASS} { display: none !important; }
${MANABI_TRACKING_SECTION_SELECTOR}.${MANABI_TRACKING_SECTION_BAKED_CLASS},
${MANABI_TRACKING_SECTION_SELECTOR}.${MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS} { contain: layout style !important; }
body:not(.${MANABI_TRACKING_SIZE_BAKING_BODY_CLASS}):not(.${MANABI_TRACKING_FORCE_VISIBLE_CLASS}) ${MANABI_TRACKING_SECTION_SELECTOR}:not(.${MANABI_TRACKING_SECTION_VISIBLE_CLASS}) { display: none !important; }
body.${MANABI_TRACKING_FORCE_VISIBLE_CLASS} ${MANABI_TRACKING_SECTION_SELECTOR} { display: block !important; visibility: visible !important; }`;
    doc.head.append(style);
  };
  var findNextTrackingSectionSibling = (section) => {
    if (!section) return null;
    let cursor = section.nextElementSibling;
    while (cursor) {
      if (cursor.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return cursor;
      cursor = cursor.nextElementSibling;
    }
    return null;
  };
  var findPrevTrackingSectionSibling = (section) => {
    if (!section) return null;
    let cursor = section.previousElementSibling;
    while (cursor) {
      if (cursor.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return cursor;
      cursor = cursor.previousElementSibling;
    }
    return null;
  };
  var applySentinelVisibilityToTrackingSections = (doc, {
    visibleSentinels = [],
    container = null,
    sectionsCache = null
  } = {}) => {
    if (!doc) return;
    const sections = Array.isArray(sectionsCache) && sectionsCache.length ? sectionsCache : Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR));
    if (sections.length === 0) return;
    const visibleSections = /* @__PURE__ */ new Set();
    const visibleCount = visibleSentinels instanceof Set ? visibleSentinels.size : Array.isArray(visibleSentinels) ? visibleSentinels.length : 0;
    const markSectionVisible = (section, { includeBuffer = true } = {}) => {
      if (!section?.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return;
      visibleSections.add(section);
      if (includeBuffer) {
        const buffer = findNextTrackingSectionSibling(section);
        if (buffer) visibleSections.add(buffer);
        const prevBuffer = findPrevTrackingSectionSibling(section);
        if (prevBuffer) visibleSections.add(prevBuffer);
      }
    };
    for (const sentinel of visibleSentinels) {
      const section = sentinel?.closest?.(MANABI_TRACKING_SECTION_SELECTOR);
      markSectionVisible(section, { includeBuffer: true });
    }
    if (visibleSections.size === 0 && visibleCount > 0) {
      const fallback = sections[0];
      markSectionVisible(fallback, { includeBuffer: true });
    }
    if (visibleSections.size === 0) {
      let seeded = 0;
      for (let i2 = 0; i2 < Math.min(3, sections.length); i2++) {
        markSectionVisible(sections[i2], { includeBuffer: false });
        seeded++;
      }
      const appliedForceVisible = !doc.body?.classList?.contains?.(MANABI_TRACKING_FORCE_VISIBLE_CLASS);
      if (appliedForceVisible) {
        doc.body.classList.add(MANABI_TRACKING_FORCE_VISIBLE_CLASS);
      }
    } else if (doc.body?.classList?.contains?.(MANABI_TRACKING_FORCE_VISIBLE_CLASS)) {
      doc.body.classList.remove(MANABI_TRACKING_FORCE_VISIBLE_CLASS);
    }
    for (const section of sections) {
      if (visibleSections.has(section)) section.classList.add(MANABI_TRACKING_SECTION_VISIBLE_CLASS);
      else section.classList.remove(MANABI_TRACKING_SECTION_VISIBLE_CLASS);
    }
  };
  var waitForStableSectionSize = (section, {
    maxEvents = MANABI_TRACKING_SIZE_STABLE_MAX_EVENTS,
    requiredStreak = MANABI_TRACKING_SIZE_STABLE_REQUIRED_STREAK
  } = {}) => new Promise((resolve) => {
    if (!(section instanceof Element)) return resolve(null);
    let lastRect = null;
    let stableCount = 0;
    let events = 0;
    let finished = false;
    const finish = (rect) => {
      if (finished) return;
      finished = true;
      resizeObserver.disconnect();
      resolve(rect ?? lastRect);
    };
    const resizeObserver = new ResizeObserver((entries) => {
      if (finished) return;
      events++;
      const rect = entries?.[0]?.contentRect;
      if (!rect) return;
      const roundedRect = {
        width: Math.round(rect.width * 1e3) / 1e3,
        height: Math.round(rect.height * 1e3) / 1e3
      };
      const unchanged = lastRect && roundedRect.width === lastRect.width && roundedRect.height === lastRect.height;
      lastRect = roundedRect;
      stableCount = unchanged ? stableCount + 1 : 1;
      if (stableCount >= requiredStreak || events >= maxEvents) finish(roundedRect);
    });
    const initialRect = section.getBoundingClientRect?.();
    if (initialRect) {
      logEBookPerf("RECT.wait-stable-section-initial", {
        id: section?.id || null,
        width: Math.round(initialRect.width * 1e3) / 1e3,
        height: Math.round(initialRect.height * 1e3) / 1e3
      });
    }
    if (initialRect) {
      lastRect = {
        width: Math.round(initialRect.width * 1e3) / 1e3,
        height: Math.round(initialRect.height * 1e3) / 1e3
      };
    }
    resizeObserver.observe(section);
    requestAnimationFrame(() => {
      if (!finished && lastRect) finish(lastRect);
    });
  });
  var waitForStableDocumentSize = (doc, {
    maxEvents = MANABI_TRACKING_DOC_STABLE_MAX_EVENTS,
    requiredStreak = MANABI_TRACKING_DOC_STABLE_REQUIRED_STREAK
  } = {}) => new Promise((resolve) => {
    const body = doc?.body;
    if (!body) return resolve(null);
    let lastRect = null;
    let stableCount = 0;
    let events = 0;
    let finished = false;
    const finish = (rect) => {
      if (finished) return;
      finished = true;
      resizeObserver.disconnect();
      resolve(rect ?? lastRect);
    };
    const resizeObserver = new ResizeObserver((entries) => {
      if (finished) return;
      events++;
      const rect = entries?.[0]?.contentRect;
      if (!rect) return;
      const roundedRect = {
        width: Math.round(rect.width * 1e3) / 1e3,
        height: Math.round(rect.height * 1e3) / 1e3
      };
      const unchanged = lastRect && roundedRect.width === lastRect.width && roundedRect.height === lastRect.height;
      lastRect = roundedRect;
      stableCount = unchanged ? stableCount + 1 : 1;
      if (stableCount >= requiredStreak || events >= maxEvents) finish(roundedRect);
    });
    const initialRect = body.getBoundingClientRect?.();
    if (initialRect) {
      logEBookPerf("RECT.wait-stable-doc-initial", {
        width: Math.round(initialRect.width * 1e3) / 1e3,
        height: Math.round(initialRect.height * 1e3) / 1e3
      });
    }
    if (initialRect) {
      lastRect = {
        width: Math.round(initialRect.width * 1e3) / 1e3,
        height: Math.round(initialRect.height * 1e3) / 1e3
      };
    }
    resizeObserver.observe(body);
    requestAnimationFrame(() => {
      if (!finished && lastRect) finish(lastRect);
    });
  });
  var waitForDocumentFontsReady = async (doc, {
    timeoutMs = 1200,
    reason = "unspecified",
    sectionIndex = null
  } = {}) => {
    const fontsReady = doc?.fonts?.ready;
    if (!fontsReady || typeof fontsReady.then !== "function") return;
    let timeoutID = null;
    const timeoutPromise2 = new Promise((resolve) => {
      timeoutID = setTimeout(() => {
        logEBookPerf("tracking-size-fonts-timeout", {
          reason,
          sectionIndex,
          timeoutMs
        });
        resolve("timeout");
      }, timeoutMs);
    });
    try {
      await Promise.race([
        Promise.resolve(fontsReady).then(() => "ready"),
        timeoutPromise2
      ]);
    } catch (error) {
      logEBookPerf("tracking-size-fonts-error", {
        reason,
        sectionIndex,
        error: String(error)
      });
    } finally {
      if (timeoutID != null) clearTimeout(timeoutID);
    }
  };
  var serializeElementTag = (element) => {
    if (!element || element.nodeType !== 1) return "";
    const safeEscape = (v2) => String(v2 ?? "").replace(/"/g, "&quot;");
    try {
      const shallow = element.cloneNode(false);
      const html = shallow?.outerHTML;
      if (html && html.length > 0) return html;
    } catch (error) {
    }
    const tag = (element.tagName || element.nodeName || "div").toLowerCase();
    const attrs = Array.from(element.attributes ?? [], ({ name, value }) => value === "" ? name : `${name}="${safeEscape(value)}"`);
    const attrString = attrs.length ? ` ${attrs.join(" ")}` : "";
    return `<${tag}${attrString}></${tag}>`;
  };
  var inlineBlockSizesForWritingMode = (rect, vertical) => {
    const inlineSize = vertical ? rect.height : rect.width;
    const blockSize = vertical ? rect.width : rect.height;
    return {
      inlineSize,
      blockSize
    };
  };
  var measureSectionSizes = (el, vertical, preMeasuredRects) => {
    logEBookPerf("RECT.before-measure", {
      id: el?.id || null,
      baked: el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || false
    });
    const id = el?.id;
    const preRects = preMeasuredRects?.get(id);
    if (preMeasuredRects && (el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || preRects)) {
      if (!preRects || preRects.length === 0) return null;
      return summarizeRects(preRects, vertical);
    }
    const rects = Array.from(el.getClientRects?.() ?? []).filter((r2) => r2 && (r2.width || r2.height));
    if (rects.length === 0) return null;
    let gap = 0;
    try {
      const cs = el.ownerDocument?.defaultView?.getComputedStyle?.(el);
      gap = parseFloat(cs?.columnGap) || 0;
    } catch {
    }
    return summarizeRects(rects, vertical, gap);
  };
  var summarizeRects = (rects, vertical, gap = 0) => {
    const inlineLengths = rects.map((r2) => vertical ? r2.height : r2.width);
    const blockLengths = rects.map((r2) => vertical ? r2.width : r2.height);
    const inlineSize = Math.max(...inlineLengths);
    const blockSize = blockLengths.reduce((acc, v2) => acc + v2, 0) + gap * Math.max(0, rects.length - 1);
    return {
      inlineSize,
      blockSize,
      multiColumn: rects.length > 1
    };
  };
  var measureElementLogicalSize = (el, vertical) => {
    if (!(el instanceof Element)) return null;
    logEBookPerf("RECT.getBoundingClientRect", {
      id: el?.id || null,
      baked: el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || false
    });
    const rect = el.getBoundingClientRect?.();
    if (!rect) return null;
    return inlineBlockSizesForWritingMode(rect, vertical);
  };
  var bakeTrackingSectionSizes = async (doc, {
    vertical,
    batchSize = MANABI_TRACKING_SIZE_BAKE_BATCH_SIZE,
    reason = "unspecified",
    sectionIndex = null,
    bookId = null,
    sectionHref = null
  } = {}) => {
    if (!doc) return;
    if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) return;
    const body = doc.body;
    if (!body) return;
    revealDocumentContentForBake(doc);
    if (MANABI_TRACKING_SIZE_BAKE_ENABLED) ensureTrackingSizeBakeStyles(doc);
    await waitForDocumentFontsReady(doc, {
      timeoutMs: 1200,
      reason,
      sectionIndex
    });
    const sections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR));
    if (sections.length === 0) return;
    const viewport = {
      width: Math.round(doc.documentElement?.clientWidth ?? 0),
      height: Math.round(doc.documentElement?.clientHeight ?? 0),
      dpr: Math.round((doc.defaultView?.devicePixelRatio ?? 1) * 1e3) / 1e3,
      safeTop: Math.round((globalThis.manabiSafeAreaInsets?.top ?? 0) * 1e3) / 1e3,
      safeBottom: Math.round((globalThis.manabiSafeAreaInsets?.bottom ?? 0) * 1e3) / 1e3,
      safeLeft: Math.round((globalThis.manabiSafeAreaInsets?.left ?? 0) * 1e3) / 1e3,
      safeRight: Math.round((globalThis.manabiSafeAreaInsets?.right ?? 0) * 1e3) / 1e3
    };
    logEBookBake("bake:start", {
      reason,
      sectionIndex,
      sections: sections.length,
      viewport,
      bookId: bookId ?? null,
      sectionHref: sectionHref ?? null
    });
    const initialViewportBlockTarget = vertical ? Math.max(1, viewport.width + viewport.safeLeft + viewport.safeRight) : Math.max(1, viewport.height + viewport.safeTop + viewport.safeBottom);
    let settingsKey = globalThis.paginationTrackingSettingsKey ?? "";
    if (!settingsKey) {
      try {
        const cs = doc?.defaultView?.getComputedStyle?.(doc.body);
        const fontSize = cs?.fontSize || "0";
        const fontFamily = (cs?.fontFamily || "").split(",")[0]?.trim?.() || "unknown";
        settingsKey = `fallback|font:${fontSize}|family:${fontFamily}`;
      } catch {
      }
    }
    const writingModeKey = globalThis.manabiTrackingWritingMode || (vertical ? "vertical-rl" : "horizontal-ltr");
    const cacheKey = [
      MANABI_TRACKING_CACHE_VERSION,
      settingsKey || "no-settings",
      writingModeKey,
      `rtl:${globalThis.manabiTrackingRTL ? 1 : 0}`,
      `vw:${viewport.width}`,
      `vh:${viewport.height}`,
      `dpr:${viewport.dpr}`,
      `safe:${viewport.safeTop},${viewport.safeRight},${viewport.safeBottom},${viewport.safeLeft}`,
      `sect:${sectionIndex ?? -1}`,
      `book:${globalThis.paginationTrackingBookKey || bookId || ""}`,
      `href:${sectionHref || ""}`
    ].join("|");
    const cachedEntries = await requestTrackingSizeCache({ command: "get", key: cacheKey });
    logEBookPerf("tracking-size-cache-fetched", {
      key: cacheKey,
      status: cachedEntries === null || cachedEntries === void 0 ? "miss" : "hit",
      entries: Array.isArray(cachedEntries) ? cachedEntries.length : null
    });
    if (cachedEntries === null || cachedEntries === void 0) {
    }
    const stableDocRect = await waitForStableDocumentSize(doc);
    logEBookBake("bake:doc-stable", {
      reason,
      sectionIndex,
      rect: stableDocRect ? {
        width: Math.round(stableDocRect.width),
        height: Math.round(stableDocRect.height)
      } : null
    });
    const bakedTags = [];
    const bakedEntryMap = /* @__PURE__ */ new Map();
    const startTs = performance?.now?.() ?? Date.now();
    const addedBodyClass = MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && !body.classList.contains(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS);
    for (const el of sections) {
      el.removeAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR);
      el.classList.remove(MANABI_TRACKING_SECTION_BAKED_CLASS);
      el.classList.remove(MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS);
      if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.remove(MANABI_TRACKING_SECTION_BAKING_CLASS);
      el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
      el.style.removeProperty("block-size");
      el.style.removeProperty("inline-size");
      el.style.removeProperty("position");
      el.style.removeProperty("top");
      el.style.removeProperty("left");
      el.style.removeProperty("right");
      el.style.removeProperty("bottom");
    }
    const blockStartProp = vertical ? globalThis.manabiTrackingVerticalRTL ? "right" : "left" : "top";
    const crossProp = vertical ? "top" : "left";
    const applyCachedEntries = (cached, container2) => {
      if (!Array.isArray(cached)) return 0;
      let applied = 0;
      for (const entry of cached) {
        const el = doc.getElementById(entry?.id);
        if (!el) continue;
        if (hasWritingModeOverride(el, vertical)) {
          continue;
        }
        const inlineSize = Number(entry.inlineSize);
        const blockSize = Number(entry.blockSize);
        if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) continue;
        logEBookPerf("RECT.cache-apply", {
          id: el.id || null,
          inlineSize,
          blockSize
        });
        logEBookPageNumLimited("cache:apply", {
          id: el.id || null,
          inlineSize,
          blockSize,
          vertical
        });
        el.style.setProperty("inline-size", formatPx(inlineSize), "important");
        el.style.setProperty("block-size", formatPx(blockSize), "important");
        el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, "true");
        el.classList.add(MANABI_TRACKING_SECTION_BAKED_CLASS);
        el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
        bakedEntryMap.set(entry.id, {
          id: entry.id,
          inlineSize,
          blockSize,
          blockStart: entry.blockStart ?? null
        });
        applied++;
      }
      const containerEntry2 = cached.find((e2) => e2?.id === "__container__");
      if (containerEntry2 && container2 instanceof HTMLElement) {
        const inlineSize = Number(containerEntry2.inlineSize);
        const blockSize = Number(containerEntry2.blockSize);
        logEBookPageNumLimited("cache:container-apply", {
          inlineSize,
          blockSize,
          vertical
        });
        if (Number.isFinite(inlineSize) && Number.isFinite(blockSize)) {
          if (vertical) {
            container2.style.setProperty("width", formatPx(blockSize), "important");
            container2.style.setProperty("height", formatPx(inlineSize), "important");
          } else {
            container2.style.setProperty("height", formatPx(blockSize), "important");
            container2.style.setProperty("width", formatPx(inlineSize), "important");
          }
        }
        bakedEntryMap.set("__container__", {
          id: "__container__",
          inlineSize,
          blockSize,
          blockStart: 0
        });
      }
      if (applied > 0) {
        globalThis.manabiTrackingAppliedFromCache = true;
      } else {
        globalThis.manabiTrackingAppliedFromCache = false;
      }
      return applied;
    };
    const container = sections[0]?.parentElement;
    const hasContainerCache = bakedEntryMap.has("__container__");
    const appliedFromCache = applyCachedEntries(cachedEntries, container);
    logEBookBake("bake:cache", {
      reason,
      sectionIndex,
      applied: appliedFromCache,
      total: sections.length,
      hasContainerCache,
      cacheKey
    });
    logEBookPerf("tracking-size-cache-apply", {
      key: cacheKey,
      applied: appliedFromCache,
      total: sections.length,
      missing: Math.max(0, sections.length - appliedFromCache)
    });
    let preMeasuredRects = null;
    if (appliedFromCache === sections.length) {
      applyAbsoluteLayout();
      seedInitialVisibility();
      const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER];
      try {
        doc.manabiTrackingSectionIOApply?.(doc.manabiTrackingSectionIO?.takeRecords?.() ?? []);
      } catch {
      }
      return;
    }
    if (addedBodyClass) body.classList.add(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS);
    let bakedCount = 0;
    let multiColumnCount = 0;
    let coverageBlock = 0;
    let coverageCursor = 0;
    let initialViewportReleased = !addedBodyClass;
    const hideTrailing = (startIndex) => {
      for (let t2 = startIndex; t2 < sections.length; t2++) {
        const el = sections[t2];
        if (!el.getAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)) {
          el.classList.add(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
        }
      }
    };
    const unhideWindow = (startIndex, count) => {
      for (let t2 = startIndex; t2 < Math.min(sections.length, startIndex + count); t2++) {
        sections[t2].classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
      }
    };
    const bakeSection = async (section) => {
      if (!section || section.nodeType !== 1) return null;
      const el = section;
      if (el.hasAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)) {
        logEBookPerf("tracking-size-measure-skip", {
          id: el.id || null,
          reason: "already-baked"
        });
        return null;
      }
      if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.add(MANABI_TRACKING_SECTION_BAKING_CLASS);
      const yokoDescendant = el.querySelector?.(".yoko");
      const skipForWritingMode = yokoDescendant ? true : hasWritingModeOverride(el, vertical);
      if (skipForWritingMode) {
        const logical = measureElementLogicalSize(el, vertical);
        const inlineSize = Number(logical?.inlineSize) || 0;
        const blockSize = Number(logical?.blockSize) || 0;
        el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, "skip-writing-mode");
        el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
        el.classList.add(MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS);
        bakedEntryMap.set(el.id || "", {
          id: el.id || "",
          inlineSize,
          blockSize,
          skipCache: true
        });
        bakedCount++;
        logEBookPerf("tracking-size-skip-writing-mode", {
          id: el.id || null,
          inlineSize,
          blockSize
        });
        logEBookPageNumLimited("tracking-size-skip-writing-mode", {
          id: el.id || null,
          inlineSize,
          blockSize,
          vertical
        });
        return { inlineSize, blockSize, multiColumn: false };
      }
      try {
        await waitForStableSectionSize(el);
        const sizes = measureSectionSizes(el, vertical, preMeasuredRects);
        if (!sizes) return null;
        const { inlineSize, blockSize, multiColumn } = sizes;
        if (!Number.isFinite(blockSize) || blockSize <= 0) return null;
        if (!Number.isFinite(inlineSize) || inlineSize <= 0) return null;
        el.style.setProperty("block-size", formatPx(blockSize), "important");
        el.style.setProperty("inline-size", formatPx(inlineSize), "important");
        el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, "true");
        el.classList.add(MANABI_TRACKING_SECTION_BAKED_CLASS);
        el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
        bakedTags.push(serializeElementTag(el));
        if (multiColumn) multiColumnCount++;
        bakedCount++;
        const entry = { id: el.id || "", inlineSize, blockSize };
        bakedEntryMap.set(entry.id, entry);
        logEBookPerf("tracking-size-measured", {
          id: entry.id,
          inlineSize,
          blockSize,
          multiColumn
        });
        return sizes;
      } finally {
        if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.remove(MANABI_TRACKING_SECTION_BAKING_CLASS);
      }
    };
    const tryAdvanceInitialViewport = () => {
      while (coverageCursor < sections.length) {
        const el = sections[coverageCursor];
        if (!el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR)) break;
        const entry = bakedEntryMap.get(el.id || "");
        let blockSize = entry?.blockSize;
        if (!Number.isFinite(blockSize)) {
          const styleBlock = parseFloat(el.style?.getPropertyValue?.("block-size")) || null;
          if (Number.isFinite(styleBlock)) blockSize = styleBlock;
        }
        if (!Number.isFinite(blockSize)) break;
        coverageBlock += blockSize;
        coverageCursor++;
        if (coverageBlock >= initialViewportBlockTarget) break;
      }
      if (!initialViewportReleased && bakedCount > 0 && coverageBlock >= initialViewportBlockTarget) {
        initialViewportReleased = true;
        if (addedBodyClass && body.classList.contains(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)) {
          body.classList.remove(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS);
        }
        seedInitialVisibility();
        logEBookBake("bake:viewport-ready", {
          reason,
          sectionIndex,
          bakedCount,
          coverageBlock,
          target: initialViewportBlockTarget
        });
        logEBookPerf("tracking-size-bake-viewport-ready", {
          reason,
          sectionIndex,
          bakedCount,
          coverageBlock,
          target: initialViewportBlockTarget,
          batchSize
        });
      }
    };
    try {
      doc?.body?.getBoundingClientRect?.();
      const map = /* @__PURE__ */ new Map();
      for (const el of sections) {
        const id = el?.id;
        if (!id) continue;
        const rects = Array.from(el.getClientRects?.() ?? []).filter((r2) => r2 && (r2.width || r2.height));
        if (rects.length > 0) {
          map.set(id, rects);
        }
      }
      preMeasuredRects = map;
      logEBookPerf("RECT.batch-collected", { count: preMeasuredRects.size });
    } catch (error) {
    }
    try {
      await Promise.all(sections.map(bakeSection));
      tryAdvanceInitialViewport();
    } finally {
      for (const el of sections) el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
      if (addedBodyClass) body.classList.remove(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS);
    }
    function seedInitialVisibility() {
      let seeded = 0;
      for (const el of sections) {
        if (!el || el.nodeType !== 1) continue;
        el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS);
        if (seeded < 3) {
          el.classList.add(MANABI_TRACKING_SECTION_VISIBLE_CLASS);
          seeded++;
        } else {
          el.classList.remove(MANABI_TRACKING_SECTION_VISIBLE_CLASS);
        }
      }
    }
    function applyAbsoluteLayout() {
      if (!container) {
        return null;
      }
      const siblings = Array.from(container.children ?? []).filter(
        (el) => el.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)
      );
      if (siblings.length === 0) {
        return null;
      }
      container.style.removeProperty("position");
      let blockCursor = 0;
      let maxInline = 0;
      const getMarginAfter = (el) => {
        try {
          const cs = doc.defaultView?.getComputedStyle?.(el);
          if (!cs) return 0;
          if (vertical) {
            return parseFloat(cs[globalThis.manabiTrackingVerticalRTL ? "marginLeft" : "marginRight"]) || 0;
          }
          return parseFloat(cs.marginBottom) || 0;
        } catch {
          return 0;
        }
      };
      for (const el of siblings) {
        if (!el || el.nodeType !== 1) continue;
        const id = el.id || "";
        const bakedSize = bakedEntryMap.get(id);
        const logical = bakedSize ?? measureElementLogicalSize(el, vertical);
        let inlineSize = Number(logical?.inlineSize);
        let blockSize = Number(logical?.blockSize);
        if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
          const measured = measureElementLogicalSize(el, vertical);
          inlineSize = Number(measured?.inlineSize);
          blockSize = Number(measured?.blockSize);
        }
        if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
          const styleInline = parseFloat(el.style.getPropertyValue("inline-size"));
          const styleBlock = parseFloat(el.style.getPropertyValue("block-size"));
          if (Number.isFinite(styleInline) && Number.isFinite(styleBlock)) {
            inlineSize = styleInline;
            blockSize = styleBlock;
          }
        }
        if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
          continue;
        }
        maxInline = Math.max(maxInline, inlineSize);
        const blockProp = vertical ? globalThis.manabiTrackingVerticalRTL ? "right" : "left" : "top";
        const crossProp2 = vertical ? "top" : "left";
        el.style.removeProperty("position");
        el.style.removeProperty(blockProp);
        el.style.removeProperty(crossProp2);
        const entry = bakedEntryMap.get(id);
        if (entry) entry.blockStart = blockCursor;
        blockCursor += blockSize + getMarginAfter(el);
      }
      if (vertical) {
        container.style.removeProperty("width");
        container.style.removeProperty("height");
        bakedEntryMap.set("__container__", { id: "__container__", inlineSize: maxInline, blockSize: blockCursor, blockStart: 0 });
      } else {
        container.style.removeProperty("height");
        container.style.removeProperty("width");
        bakedEntryMap.set("__container__", { id: "__container__", inlineSize: maxInline, blockSize: blockCursor, blockStart: 0 });
      }
    }
    applyAbsoluteLayout();
    seedInitialVisibility();
    try {
      const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER];
      const entriesForCache = Array.from(bakedEntryMap.values()).filter((e2) => !e2.skipCache);
      if (handler?.postMessage && entriesForCache.length > 0) {
        handler.postMessage({
          command: "set",
          key: cacheKey,
          entries: entriesForCache,
          reason
        });
      }
    } catch (error) {
    }
    const durationMs = (performance?.now?.() ?? Date.now()) - startTs;
    const containerEntry = bakedEntryMap.get("__container__") || null;
    logEBookBake("bake:done", {
      reason,
      sectionIndex,
      durationMs: Math.round(durationMs),
      bakedCount,
      multiColumnCount,
      coverageBlock,
      target: initialViewportBlockTarget,
      initialViewportReleased,
      appliedFromCache,
      containerSize: containerEntry ? {
        inline: containerEntry.inlineSize,
        block: containerEntry.blockSize
      } : null
    });
  };
  var uncollapse = (range) => {
    if (!range?.collapsed) return range;
    const {
      endOffset,
      endContainer
    } = range;
    if (endContainer.nodeType === 1) {
      const node = endContainer.childNodes[endOffset];
      if (node?.nodeType === 1) return node;
      return endContainer;
    }
    if (endOffset + 1 < endContainer.length) range.setEnd(endContainer, endOffset + 1);
    else if (endOffset > 1) range.setStart(endContainer, endOffset - 1);
    else return endContainer.parentNode;
    return range;
  };
  var NF = globalThis.NodeFilter ?? {};
  var {
    SHOW_ELEMENT,
    SHOW_TEXT,
    SHOW_CDATA_SECTION,
    FILTER_ACCEPT,
    FILTER_REJECT,
    FILTER_SKIP
  } = NF;
  var hasWritingModeOverride = (section, vertical, { maxNodes = Infinity } = {}) => {
    if (!(section instanceof Element)) return false;
    let rootMode = "horizontal-tb";
    try {
      const cs = section.ownerDocument?.defaultView?.getComputedStyle?.(section);
      const mode = cs?.writingMode || cs?.webkitWritingMode || cs?.getPropertyValue?.("writing-mode") || cs?.getPropertyValue?.("-webkit-writing-mode") || "";
      if (mode) rootMode = mode;
    } catch {
    }
    const rootVertical = rootMode ? rootMode.startsWith("vertical") : vertical;
    const yokoProbe = section.querySelector?.(".yoko");
    if (yokoProbe) {
      let yokoMode = "";
      try {
        const cs = yokoProbe.ownerDocument?.defaultView?.getComputedStyle?.(yokoProbe);
        yokoMode = cs?.writingMode || cs?.webkitWritingMode || cs?.getPropertyValue?.("writing-mode") || cs?.getPropertyValue?.("-webkit-writing-mode") || "";
      } catch {
      }
      const yokoIsVertical = yokoMode ? yokoMode.startsWith("vertical") : false;
      const yokoOrientationMismatch = yokoIsVertical !== vertical;
      const yokoStringMismatch = rootMode && yokoMode && yokoMode !== rootMode;
      if (yokoStringMismatch || yokoOrientationMismatch || yokoIsVertical !== rootVertical) {
        return true;
      }
    }
    const nodes = section.querySelectorAll("*");
    let visited = 0;
    for (const el of nodes) {
      if (!(el instanceof Element)) continue;
      visited++;
      if (visited > maxNodes) break;
      let mode = "";
      try {
        const cs = el.ownerDocument?.defaultView?.getComputedStyle?.(el);
        mode = cs?.writingMode || cs?.webkitWritingMode || cs?.getPropertyValue?.("writing-mode") || cs?.getPropertyValue?.("-webkit-writing-mode") || "";
      } catch {
      }
      if (el.classList?.contains?.("yoko") && !mode) mode = "horizontal-tb";
      if (!mode) continue;
      const isVertical = mode.startsWith("vertical");
      const orientationMismatch = isVertical !== vertical;
      const stringMismatch = rootMode && mode && mode !== rootMode;
      if (stringMismatch || orientationMismatch || isVertical !== rootVertical) {
        return true;
      }
    }
    return false;
  };
  async function getBodylessComputedStyle(sourceDoc) {
    const cloneDoc = document.implementation.createHTMLDocument();
    const clonedHead = sourceDoc.head.cloneNode(true);
    ["manabi-font-data", "manabi-custom-fonts"].forEach((id) => {
      const el = clonedHead.querySelector(`#${id}`);
      if (el) el.remove();
    });
    for (const link of clonedHead.querySelectorAll('link[rel="stylesheet"][href^="blob:"]')) {
      try {
        const css = await fetch(link.href).then((r2) => r2.text());
        const blobUrl2 = URL.createObjectURL(new Blob([css], {
          type: "text/css"
        }));
        link.href = blobUrl2;
      } catch {
        link.remove();
      }
    }
    clonedHead.querySelectorAll("script").forEach((el) => el.remove());
    cloneDoc.head.replaceWith(clonedHead);
    const bodyClone = sourceDoc.body.cloneNode(false);
    cloneDoc.body.replaceWith(bodyClone);
    for (const { name, value } of sourceDoc.documentElement.attributes) {
      cloneDoc.documentElement.setAttribute(name, value);
    }
    cloneDoc.documentElement.setAttribute(
      "dir",
      sourceDoc.documentElement.getAttribute("dir") || ""
    );
    const html = "<!doctype html>" + cloneDoc.documentElement.outerHTML;
    const blob = new Blob([html], {
      type: "text/html"
    });
    const blobUrl = URL.createObjectURL(blob);
    const iframe = document.createElement("iframe");
    iframe.style.cssText = "position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;";
    document.documentElement.appendChild(iframe);
    await new Promise((resolve) => {
      iframe.onload = resolve;
      iframe.src = blobUrl;
    });
    await new Promise((r2) => requestAnimationFrame(r2));
    const bodylessDoc = iframe.contentDocument;
    const bodylessStyle = iframe.contentWindow.getComputedStyle(bodylessDoc.body);
    URL.revokeObjectURL(blobUrl);
    iframe.remove();
    return { bodylessStyle, bodylessDoc };
  }
  function resolvePaginatorDirection({
    bodylessStyle,
    bodylessDoc,
    writingDirectionOverride = globalThis.manabiEbookWritingDirection || "original"
  }) {
    const writingMode = bodylessStyle.writingMode;
    const direction = bodylessStyle.direction;
    const rtl = bodylessDoc.body.dir === "rtl" || direction === "rtl" || bodylessDoc.documentElement.dir === "rtl";
    if (writingDirectionOverride === "vertical") {
      return { vertical: true, verticalRTL: true, rtl };
    }
    if (writingDirectionOverride === "horizontal") {
      return { vertical: false, verticalRTL: false, rtl };
    }
    const vertical = writingMode === "vertical-rl" || writingMode === "vertical-lr";
    const verticalRTL = writingMode === "vertical-rl";
    return { vertical, verticalRTL, rtl };
  }
  globalThis.manabiResolvePaginatorDirection = resolvePaginatorDirection;
  async function getDirection({ bodylessStyle, bodylessDoc }) {
    return resolvePaginatorDirection({ bodylessStyle, bodylessDoc });
  }
  var makeMarginals = (length, part) => Array.from({
    length
  }, () => {
    const div = document.createElement("div");
    const child = document.createElement("div");
    div.append(child);
    child.setAttribute("part", part);
    return div;
  });
  var setStylesImportant = (el, styles) => {
    const {
      style
    } = el;
    for (const [k2, v2] of Object.entries(styles)) style.setProperty(k2, v2, "important");
  };
  var View = class {
    #wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    #debouncedExpand;
    #inExpand = false;
    #hasResizerObserverTriggered = false;
    #lastResizerRect = null;
    #lastBodyRect = null;
    #lastContainerRect = null;
    #resizeEventSeq = 0;
    #resizeObserverFrame = null;
    #pendingResizeRect = null;
    #resizeObserver = null;
    #styleCache = /* @__PURE__ */ new WeakMap();
    #isCacheWarmer = false;
    #pendingResizeAfterExpand = null;
    #expandRetryScheduled = false;
    #sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED;
    #sameDocumentStyleNodes = [];
    #sameDocumentAppliedBodyClasses = [];
    #sameDocumentSourceURL = null;
    #sameDocumentObservedElement = null;
    cachedViewSize = null;
    getLastBodyRect() {
      return this.#lastBodyRect;
    }
    #handleResize(newSize) {
      if (!newSize) return;
      const inExpand = this.#inExpand || false;
      if (this.#isCacheWarmer) return;
      this.#lastBodyRect = newSize;
      if (inExpand) {
        this.#pendingResizeAfterExpand = newSize;
        logEBookResize("iframe-resize-buffered", {
          newSize,
          inExpand,
          isCacheWarmer: this.#isCacheWarmer
        });
        console.log("[paginator] handleResize buffered during expand", { newSize, inExpand });
        return;
      }
      logEBookResize("iframe-resize-apply", {
        newSize,
        inExpand,
        isCacheWarmer: this.#isCacheWarmer
      });
      console.log("[paginator] handleResize apply", { newSize, inExpand });
      this.cachedViewSize = null;
      if (MANABI_TRACKING_SIZE_BAKE_ENABLED) {
        this.container?.requestTrackingSectionSizeBakeDebounced?.({
          reason: "iframe-resize",
          rect: newSize
        });
      } else {
        this.expand().catch(() => {
        });
      }
    }
    #element = document.createElement("div");
    #iframe = document.createElement("iframe");
    #iframeShownForBake = false;
    #contentRange = document.createRange();
    #overlayer;
    #vertical = null;
    #verticalRTL = null;
    #rtl = null;
    #directionReadyResolve = null;
    #directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
    #column = true;
    #size;
    #lastElementStyleHeight = null;
    #elementStyleObserver = null;
    layout = {};
    constructor({
      container,
      onBeforeExpand,
      onExpand,
      isCacheWarmer
    }) {
      this.container = container;
      this.#isCacheWarmer = isCacheWarmer;
      this.#sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED && !isCacheWarmer;
      this.#debouncedExpand = debounce(this.expand.bind(this), 999);
      this.onBeforeExpand = onBeforeExpand;
      this.onExpand = onExpand;
      if (this.#sameDocumentMode) {
        this.#iframe = document.createElement("div");
      }
      this.#element.append(this.#iframe);
      Object.assign(this.#element.style, {
        boxSizing: "content-box",
        position: "relative",
        overflow: "hidden",
        flex: "0 0 auto",
        width: "100%",
        height: "100%",
        display: "flex",
        justifyContent: "center",
        alignItems: "center"
      });
      if (this.#sameDocumentMode) {
        this.#element.style.justifyContent = "flex-start";
        this.#element.style.alignItems = "flex-start";
      }
      this.#lastElementStyleHeight = this.#element.style.height || null;
      this.#elementStyleObserver = new MutationObserver((mutations) => {
        for (const m2 of mutations) {
          if (m2.attributeName !== "style") continue;
          const current = this.#element.style.height || null;
          if (current === this.#lastElementStyleHeight) continue;
          const prevNumeric = parseFloat(this.#lastElementStyleHeight ?? "NaN");
          const currentNumeric = parseFloat(current ?? "NaN");
          const isSpike = Number.isFinite(currentNumeric) && currentNumeric > 4e3;
          if (isSpike || current !== this.#lastElementStyleHeight) {
            logEBookPageNumLimited("element-style-height", {
              previous: this.#lastElementStyleHeight,
              next: current,
              isSpike
            });
          }
          this.#lastElementStyleHeight = current;
        }
      });
      try {
        this.#elementStyleObserver.observe(this.#element, { attributes: true, attributeFilter: ["style"] });
      } catch (_2) {
      }
      Object.assign(this.#iframe.style, {
        overflow: "hidden",
        border: "0",
        //            display: 'none',
        display: "block",
        width: "100%",
        height: "100%"
      });
      if (this.#sameDocumentMode) {
        this.#iframe.id = "manabi-same-document-mount";
        this.#iframe.className = "manabi-same-document-mount";
        this.#iframe.style.position = "relative";
        this.#iframe.style.boxSizing = "border-box";
      } else {
        this.#iframe.setAttribute("scrolling", "no");
      }
      this.#resizeObserver = new ResizeObserver((entries) => {
        if (this.#isCacheWarmer) return;
        const entry = entries[0];
        if (!entry) return;
        const rect = entry.contentRect;
        this.#pendingResizeRect = {
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          top: Math.round(rect.top),
          left: Math.round(rect.left)
        };
        if (this.#resizeObserverFrame !== null) cancelAnimationFrame(this.#resizeObserverFrame);
        this.#resizeObserverFrame = requestAnimationFrame(() => {
          this.#resizeObserverFrame = null;
          this.#handleResize(this.#pendingResizeRect);
        });
      });
    }
    revealIframeForBake(reason) {
      if (this.#iframeShownForBake) return;
      if (this.#iframe?.style?.display === "none") {
        this.#iframe.style.display = "block";
        this.#iframeShownForBake = true;
        logEBookPerf("iframe-display-set", { state: "shown-for-bake", reason });
        logEBookPageNumLimited("bake:iframe-reveal", {
          reason,
          sectionIndex: this.container?.currentIndex ?? null
        });
        logEBookFlash("iframe-reveal", {
          reason,
          sectionIndex: this.container?.currentIndex ?? null
        });
      }
    }
    get element() {
      return this.#element;
    }
    reconcileSameDocumentExpandedWidth() {
      if (!this.#sameDocumentMode || !this.#column || !Number.isFinite(this.#size) || this.#size <= 0) {
        return null;
      }
      try {
        const layoutController = document?.defaultView?.manabiEbookSectionLayoutController;
        const layoutPageCount = Math.max(
          1,
          Number.parseInt(String(layoutController?.pageCount?.() ?? 1), 10) || 1
        );
        const side = this.#vertical ? "height" : "width";
        const otherSide = this.#vertical ? "width" : "height";
        const layoutExpandedSize = layoutPageCount * this.#size;
        this.#iframe.style[side] = `${layoutExpandedSize}px`;
        this.#element.style[side] = `${layoutExpandedSize + this.#size * 2}px`;
        this.#iframe.style[otherSide] = "100%";
        this.#element.style[otherSide] = "100%";
        logEBookPageNumLimited("expand:same-document-reconcile", {
          side,
          size: this.#size,
          layoutPageCount,
          layoutExpandedSize,
          iframe: this.#iframe?.style?.[side] || null,
          element: this.#element?.style?.[side] || null
        });
        return {
          layoutPageCount,
          layoutExpandedSize
        };
      } catch (_error) {
        return null;
      }
    }
    get document() {
      if (this.#sameDocumentMode) return document;
      return this.#iframe.contentDocument;
    }
    #getContentRoot() {
      if (this.#sameDocumentMode) {
        return this.#iframe.querySelector("#reader-content") || this.#iframe;
      }
      return this.document?.getElementById?.("reader-content") || this.document?.body || null;
    }
    #removeSameDocumentStyles() {
      for (const node of this.#sameDocumentStyleNodes) node?.remove?.();
      this.#sameDocumentStyleNodes = [];
    }
    #clearSameDocumentBodyState() {
      if (document?.body) {
        for (const className of this.#sameDocumentAppliedBodyClasses) {
          document.body.classList.remove(className);
        }
        document.body.removeAttribute("data-is-ebook");
      }
      this.#sameDocumentAppliedBodyClasses = [];
    }
    #resetSameDocumentState() {
      this.#removeSameDocumentStyles();
      this.#clearSameDocumentBodyState();
      this.#iframe.replaceChildren();
      this.#sameDocumentSourceURL = null;
    }
    async #loadSameDocument(src, afterLoad, beforeRender, sectionIndex = null, sectionLocation = null) {
      this.#iframeShownForBake = true;
      this.#sameDocumentSourceURL = src;
      this.#vertical = this.#verticalRTL = this.#rtl = null;
      this.#directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
      this.#resetSameDocumentState();
      this.#sameDocumentSourceURL = src;
      const html = await fetch(src).then((r2) => r2.text());
      const sourceDoc = new DOMParser().parseFromString(html, "text/html");
      for (const node of Array.from(sourceDoc.head?.children || [])) {
        const tagName = node.tagName?.toLowerCase?.();
        if (tagName !== "style" && tagName !== "link") continue;
        if (tagName === "link" && node.getAttribute("rel") !== "stylesheet") continue;
        const clone = node.cloneNode(true);
        clone.dataset.manabiSameDocumentSectionStyle = "true";
        document.head.append(clone);
        this.#sameDocumentStyleNodes.push(clone);
      }
      if (document?.body) {
        document.body.dataset.isEbook = sourceDoc.body?.dataset?.isEbook || "true";
        const applied = Array.from(sourceDoc.body?.classList || []).filter(Boolean);
        for (const className of applied) document.body.classList.add(className);
        this.#sameDocumentAppliedBodyClasses = applied;
      }
      for (const child of Array.from(sourceDoc.body?.childNodes || [])) {
        this.#iframe.append(child.cloneNode(true));
      }
      if (!this.#iframe.querySelector("#reader-content")) {
        const readerContent = document.createElement("div");
        readerContent.id = "reader-content";
        const page = document.createElement("div");
        page.className = "page";
        const article = document.createElement("article");
        while (this.#iframe.firstChild) {
          article.append(this.#iframe.firstChild);
        }
        page.append(article);
        readerContent.append(page);
        this.#iframe.append(readerContent);
      }
      try {
        document.defaultView.manabiCurrentContentURL = sectionLocation || src;
      } catch (_error) {
      }
      await afterLoad?.(document);
      Promise.resolve().then(() => globalThis.manabiWaitForFontCSS?.()).catch(() => {
      });
      Promise.resolve().then(() => globalThis.manabiEnsureCustomFonts?.(document)).catch(() => {
      });
      const writingDirectionOverride = globalThis.manabiEbookWritingDirection || "original";
      const sourceDir = sourceDoc.body?.getAttribute?.("dir") || sourceDoc.documentElement?.getAttribute?.("dir") || "ltr";
      this.#rtl = sourceDir === "rtl";
      if (writingDirectionOverride === "vertical") {
        this.#vertical = true;
        this.#verticalRTL = true;
      } else {
        this.#vertical = false;
        this.#verticalRTL = false;
      }
      applyVerticalWritingClass(document, this.#vertical);
      applyTategakiDisplayTransform(document, this.#vertical);
      globalThis.manabiTrackingVertical = this.#vertical;
      globalThis.manabiTrackingVerticalRTL = this.#verticalRTL;
      globalThis.manabiTrackingRTL = this.#rtl;
      globalThis.manabiTrackingWritingMode = this.#vertical ? this.#verticalRTL ? "vertical-rl" : "vertical-lr" : this.#rtl ? "horizontal-rtl" : "horizontal-ltr";
      this.#directionReadyResolve?.();
      const contentRoot = this.#getContentRoot();
      if (contentRoot) {
        this.#contentRange.selectNodeContents(contentRoot);
      }
      const layout = await beforeRender?.({
        vertical: this.#vertical,
        rtl: this.#rtl
      });
      revealDocumentContentForBake(document);
      this.#sameDocumentObservedElement = contentRoot || this.#iframe;
      if (this.#sameDocumentObservedElement) {
        this.#resizeObserver.observe(this.#sameDocumentObservedElement);
      }
      await this.container?.performInitialBakeFromView?.(sectionIndex ?? this.container?.currentIndex, layout);
    }
    async load(src, afterLoad, beforeRender, sectionIndex = null, sectionLocation = null) {
      if (typeof src !== "string") throw new Error(`${src} is not string`);
      if (this.#sameDocumentMode) {
        globalThis.manabiLoadEBookLastState = "paginator-load-same-document-begin";
        return await this.#loadSameDocument(src, afterLoad, beforeRender, sectionIndex, sectionLocation);
      }
      globalThis.manabiLoadEBookLastState = "paginator-load-iframe-begin";
      this.#iframeShownForBake = false;
      this.#vertical = this.#verticalRTL = this.#rtl = null;
      this.#directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
      if (MANABI_TRACKING_SIZE_BAKE_ENABLED) {
        this.#iframe.style.display = "none";
        logEBookPerf("iframe-display-set", { state: "hidden-before-src", src });
      } else {
        this.#iframe.style.display = "block";
      }
      return new Promise(async (resolve) => {
        if (this.#isCacheWarmer) {
          console.log("Don't create View for cache warmers");
          resolve();
        } else {
          this.#iframe.addEventListener("load", async () => {
            globalThis.manabiLoadEBookLastState = "paginator-load-iframe-load-event";
            try {
              await globalThis.manabiWaitForFontCSS?.();
            } catch {
            }
            const doc = this.document;
            try {
              globalThis.manabiEnsureCustomFonts?.(doc);
            } catch {
            }
            globalThis.manabiLoadEBookLastState = "paginator-load-before-afterLoad";
            await afterLoad?.(doc);
            globalThis.manabiLoadEBookLastState = "paginator-load-after-afterLoad";
            const { bodylessStyle, bodylessDoc } = await getBodylessComputedStyle(doc);
            const direction = await getDirection({ bodylessStyle, bodylessDoc });
            this.#vertical = direction.vertical;
            this.#verticalRTL = direction.verticalRTL;
            this.#rtl = direction.rtl;
            applyVerticalWritingClass(doc, this.#vertical);
            applyTategakiDisplayTransform(doc, this.#vertical);
            globalThis.manabiTrackingVertical = this.#vertical;
            globalThis.manabiTrackingVerticalRTL = this.#verticalRTL;
            globalThis.manabiTrackingRTL = this.#rtl;
            globalThis.manabiTrackingWritingMode = this.#vertical ? this.#verticalRTL ? "vertical-rl" : "vertical-lr" : this.#rtl ? "horizontal-rtl" : "horizontal-ltr";
            this.#directionReadyResolve?.();
            const contentRoot = this.#getContentRoot() || doc.body;
            this.#contentRange.selectNodeContents(contentRoot);
            globalThis.manabiLoadEBookLastState = "paginator-load-before-beforeRender";
            const layout = await beforeRender?.({
              vertical: this.#vertical,
              rtl: this.#rtl
            });
            globalThis.manabiLoadEBookLastState = "paginator-load-after-beforeRender";
            this.revealIframeForBake("initial-load");
            revealDocumentContentForBake(doc);
            globalThis.manabiLoadEBookLastState = "paginator-load-before-initial-bake";
            await this.container?.performInitialBakeFromView?.(sectionIndex ?? this.container?.currentIndex, layout);
            globalThis.manabiLoadEBookLastState = "paginator-load-after-initial-bake";
            this.#sameDocumentObservedElement = doc.body;
            this.#resizeObserver.observe(doc.body);
            globalThis.manabiLoadEBookLastState = "paginator-load-iframe-resolve";
            resolve();
          }, {
            once: true
          });
          globalThis.manabiLoadEBookLastState = "paginator-load-iframe-set-src";
          this.#iframe.src = src;
        }
      });
    }
    async render(layout, { skipExpand = false, source = "unknown" } = {}) {
      if (!layout) {
        return;
      }
      logEBookPerf("render-start", {
        flow: layout.flow,
        column: layout.flow !== "scrolled",
        vertical: this.#vertical,
        isCacheWarmer: this.#isCacheWarmer
      });
      logEBookPerf("EXPAND.render-start", {
        flow: layout.flow,
        skipExpand,
        source,
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        inExpand: this.#inExpand || false
      });
      layout.usePaginate = false;
      this.#column = layout.flow !== "scrolled";
      this.layout = layout;
      applyVerticalWritingClass(this.document, this.#vertical);
      applyTategakiDisplayTransform(this.document, this.#vertical);
      if (this.#column) {
        await this.columnize(layout, { skipExpand });
      } else {
        await this.scrolled(layout, { skipExpand });
      }
      logEBookPerf("render-complete", {
        flow: layout.flow,
        column: this.#column,
        vertical: this.#vertical
      });
      logEBookPerf("EXPAND.render-complete", {
        flow: layout.flow,
        skipExpand,
        source,
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        inExpand: this.#inExpand || false
      });
    }
    async scrolled({
      gap,
      columnWidth,
      shouldColumnizeForThreshold = true
    }, { skipExpand = false } = {}) {
      await this.#awaitDirection();
      const vertical = this.#vertical;
      const doc = this.document;
      const layoutRoot = this.#getContentRoot() || doc.documentElement;
      const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
      const constrainedSize = shouldColumnizeForThreshold ? `${columnWidth}px` : "none";
      const margin = shouldColumnizeForThreshold ? "auto" : "0";
      const padding = shouldColumnizeForThreshold ? vertical ? `${gap}px 0` : `0 ${gap}px` : "0";
      const effectiveGap = shouldColumnizeForThreshold ? `${gap}px` : "0px";
      logEBookPerf("EXPAND.scrolled-entry", {
        skipExpand,
        shouldColumnizeForThreshold,
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        ready: this.container?.trackingSizeBakeReadyPublic ?? null
      });
      const layoutRootStyles = {
        "box-sizing": "border-box",
        "padding": padding,
        //            border: `${gap}px solid transparent`,
        //            borderWidth: vertical ? `${gap}px 0` : `0 ${gap}px`,
        "column-width": "auto",
        "height": "auto",
        "width": "auto",
        //            // columnize parity
        // columnGap: '0',
        "--paginator-column-gap": effectiveGap,
        "column-gap": effectiveGap,
        "column-fill": "auto",
        "overflow": "hidden",
        // force wrap long words
        "overflow-wrap": "anywhere",
        // reset some potentially problematic props
        "position": "static",
        "border": "0",
        "margin": "0",
        "max-height": "none",
        "max-width": "none",
        "min-height": "none",
        "min-width": "none",
        // columnize parity
        "--paginator-margin": `${bottomMarginPx}px`
      };
      if (globalThis.manabiPageTurnInteractionDiagnostic !== true) {
        layoutRootStyles["-webkit-line-box-contain"] = "block glyphs replaced";
      }
      setStylesImportant(layoutRoot, layoutRootStyles);
      setStylesImportant(this.#getContentRoot() || doc.body, {
        [vertical ? "max-height" : "max-width"]: constrainedSize,
        "margin": margin
      });
      const canExpand = !skipExpand;
      if (canExpand) {
        await this.expand();
      } else if (!skipExpand) {
        logEBookPerf("EXPAND.expand-skip", {
          source: "scrolled",
          suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
          ready: this.container?.trackingSizeBakeReadyPublic ?? null
        });
      }
    }
    async columnize({
      width,
      height,
      gap,
      columnWidth,
      divisor
    }, { skipExpand = false } = {}) {
      await this.#awaitDirection();
      const vertical = this.#vertical;
      this.#size = vertical ? height : width;
      logEBookPerf("EXPAND.columnize-entry", {
        skipExpand,
        size: this.#size,
        width,
        height,
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        ready: this.container?.trackingSizeBakeReadyPublic ?? null
      });
      const doc = this.document;
      const layoutRoot = this.#getContentRoot() || doc.documentElement;
      const columnizeStyles = {
        "box-sizing": "border-box",
        "column-width": `${Math.trunc(columnWidth)}px`,
        "--paginator-column-gap": `${gap}px`,
        "column-gap": `${gap}px`,
        "column-fill": "auto",
        ...vertical ? {
          "width": `${width}px`
        } : {
          "height": `${height}px`
        },
        "padding": vertical ? `${gap / 2}px 0` : `0 ${gap / 2}px`,
        "overflow": "hidden",
        // force wrap long words
        "overflow-wrap": "break-word",
        // TODO: anywhere, for japanese?
        // reset some potentially problematic props
        "position": "static",
        "border": "0",
        "margin": "0",
        "max-height": "none",
        "max-width": "none",
        "min-height": "none",
        "min-width": "none"
      };
      if (globalThis.manabiPageTurnInteractionDiagnostic !== true) {
        columnizeStyles["-webkit-line-box-contain"] = "block glyphs replaced";
      }
      setStylesImportant(layoutRoot, columnizeStyles);
      const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
      layoutRoot.style.setProperty("--paginator-margin", `${bottomMarginPx}px`);
      setStylesImportant(this.#getContentRoot() || doc.body, {
        "max-height": "none",
        "max-width": "none",
        "margin": "0"
      });
      const canExpand = !skipExpand;
      if (canExpand) {
        await this.expand();
      } else if (!skipExpand) {
        logEBookPerf("EXPAND.expand-skip", {
          source: "columnize",
          suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
          ready: this.container?.trackingSizeBakeReadyPublic ?? null
        });
      }
    }
    async #awaitDirection() {
      if (this.#vertical === null) await this.#directionReady;
    }
    async expand() {
      logEBookPerf("expand-request", {
        column: this.#column,
        vertical: this.#vertical,
        size: this.#size,
        cacheWarmer: this.#isCacheWarmer
      });
      logEBookPerf("EXPAND.expand-entry", {
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
        pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
        inExpand: this.#inExpand || false
      });
      logEBookPageNumLimited("expand:entry", {
        column: this.#column,
        vertical: this.#vertical,
        size: this.#size,
        cacheWarmer: this.#isCacheWarmer,
        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
        trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
        pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
        inExpand: this.#inExpand || false
      });
      this.#expandRetryScheduled = false;
      this.#inExpand = true;
      try {
        await this.onBeforeExpand();
      } catch (error) {
        this.#inExpand = false;
        throw error;
      }
      return new Promise((resolve) => {
        requestAnimationFrame(async () => {
          try {
            const documentElement = this.#getContentRoot() || this.document?.documentElement;
            const side = this.#vertical ? "height" : "width";
            const otherSide = this.#vertical ? "width" : "height";
            const scrollProp = side === "width" ? "scrollWidth" : "scrollHeight";
            if (this.#column) {
              const contentRect = this.#contentRange.getBoundingClientRect();
              const rootRect = documentElement.getBoundingClientRect();
              logEBookPerf("RECT.expand-content", {
                contentRect: { width: contentRect?.width ?? null, height: contentRect?.height ?? null, left: contentRect?.left ?? null, right: contentRect?.right ?? null },
                rootRect: { width: rootRect?.width ?? null, height: rootRect?.height ?? null, left: rootRect?.left ?? null, right: rootRect?.right ?? null }
              });
              const contentStart = this.#vertical ? 0 : this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left;
              const contentRectSide = contentRect?.[side] ?? 0;
              const contentSize = contentStart + contentRectSide;
              const sizeValid = Number.isFinite(this.#size) && this.#size > 0;
              const contentRectValid = Number.isFinite(contentRectSide) && contentRectSide > 0;
              const contentSizeValid = Number.isFinite(contentSize) && contentSize > 0;
              const pageCount = sizeValid && contentSizeValid ? Math.ceil(contentSize / this.#size) : null;
              const invalidMeasurement = !sizeValid || !contentRectValid || !contentSizeValid || !pageCount || pageCount <= 0;
              console.log("[paginator] expand measure", {
                size: this.#size,
                side,
                contentRectSide,
                contentStart,
                contentSize,
                pageCount,
                invalidMeasurement
              });
              if (invalidMeasurement) {
                logEBookPageNumLimited("expand:invalid-measurement", {
                  mode: "column",
                  side,
                  size: this.#size,
                  contentRectSide,
                  contentStart,
                  contentSize,
                  pageCount
                });
                logEBookBake("expand:invalid-measurement", {
                  mode: "column",
                  side,
                  size: this.#size,
                  contentRectSide,
                  contentStart,
                  contentSize,
                  pageCount,
                  column: this.#column,
                  vertical: this.#vertical,
                  readyFlag: this.container?.trackingSizeBakeReadyPublic ?? null,
                  suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null
                });
                if (!this.#expandRetryScheduled) {
                  this.#expandRetryScheduled = true;
                  requestAnimationFrame(() => {
                    this.#expandRetryScheduled = false;
                    if (!this.#inExpand) this.expand().catch(() => {
                    });
                  });
                }
                return;
              }
              logEBookPerf("EXPAND.metrics", {
                mode: "column",
                side,
                size: this.#size,
                contentSize,
                pageCount,
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null
              });
              logEBookPageNumLimited("expand:metrics", {
                mode: "column",
                side,
                size: this.#size,
                contentSize,
                pageCount,
                expandedSize: pageCount * this.#size,
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null
              });
              const expandedSize = pageCount * this.#size;
              this.#element.style.padding = "0";
              this.#iframe.style[side] = `${expandedSize}px`;
              this.#element.style[side] = `${expandedSize + this.#size * 2}px`;
              this.#iframe.style[otherSide] = "100%";
              this.#element.style[otherSide] = "100%";
              if (documentElement) {
                documentElement.style[side] = `${this.#size}px`;
              }
              if (this.#overlayer) {
                this.#overlayer.element.style.margin = "0";
                this.#overlayer.element.style.left = this.#vertical ? "0" : `${this.#size}px`;
                this.#overlayer.element.style.top = this.#vertical ? `${this.#size}px` : "0";
                this.#overlayer.element.style[side] = `${expandedSize}px`;
                this.#overlayer.redraw();
              }
            } else {
              const docRect = documentElement.getBoundingClientRect();
              logEBookPerf("RECT.expand-doc", {
                width: docRect?.width ?? null,
                height: docRect?.height ?? null
              });
              const contentSize = docRect[side];
              const expandedSize = contentSize;
              const {
                topMargin,
                bottomMargin
              } = this.layout;
              logEBookPerf("EXPAND.metrics", {
                mode: "scrolled",
                side,
                size: this.#size,
                contentSize,
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null
              });
              logEBookPageNumLimited("expand:metrics", {
                mode: "scrolled",
                side,
                size: this.#size,
                contentSize,
                pageCount: null,
                expandedSize,
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null
              });
              const paddingTop = `${topMargin}px`;
              const paddingBottom = `${bottomMargin}px`;
              if (this.#vertical) {
                this.#element.style.paddingLeft = paddingTop;
                this.#element.style.paddingRight = paddingBottom;
                this.#element.style.paddingTop = "0";
                this.#element.style.paddingBottom = "0";
              } else {
                this.#element.style.paddingLeft = "0";
                this.#element.style.paddingRight = "0";
                this.#element.style.paddingTop = paddingTop;
                this.#element.style.paddingBottom = paddingBottom;
              }
              this.#iframe.style[side] = `${expandedSize}px`;
              this.#element.style[side] = `${expandedSize}px`;
              this.#iframe.style[otherSide] = "100%";
              this.#element.style[otherSide] = "100%";
              if (this.#overlayer) {
                if (this.#vertical) {
                  this.#overlayer.element.style.marginLeft = paddingTop;
                  this.#overlayer.element.style.marginRight = paddingBottom;
                  this.#overlayer.element.style.marginTop = "0";
                  this.#overlayer.element.style.marginBottom = "0";
                } else {
                  this.#overlayer.element.style.marginLeft = "0";
                  this.#overlayer.element.style.marginRight = "0";
                  this.#overlayer.element.style.marginTop = paddingTop;
                  this.#overlayer.element.style.marginBottom = paddingBottom;
                }
                this.#overlayer.element.style.left = "0";
                this.#overlayer.element.style.top = "0";
                this.#overlayer.element.style[side] = `${expandedSize}px`;
                this.#overlayer.redraw();
              }
            }
            logEBookPerf("expand-before-onexpand", {
              column: this.#column,
              vertical: this.#vertical,
              side,
              expandedSize: this.#iframe?.style?.[side] || null
            });
            logEBookPageNumLimited("expand:set-styles", {
              column: this.#column,
              vertical: this.#vertical,
              side,
              iframe: this.#iframe?.style?.[side] || null,
              element: this.#element?.style?.[side] || null,
              otherSide,
              iframeOther: this.#iframe?.style?.[otherSide] || null,
              elementOther: this.#element?.style?.[otherSide] || null
            });
            await this.onExpand();
            this.reconcileSameDocumentExpandedWidth();
            logEBookPerf("expand-complete", {
              column: this.#column,
              vertical: this.#vertical,
              size: this.#size
            });
            logEBookPerf("EXPAND.expand-complete", {
              suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
              trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
              pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
              inExpand: this.#inExpand || false
            });
            logEBookPageNumLimited("expand:complete", {
              column: this.#column,
              vertical: this.#vertical,
              size: this.#size,
              suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
              trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
              pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null
            });
          } finally {
            const bufferedResize = this.#pendingResizeAfterExpand;
            this.#pendingResizeAfterExpand = null;
            this.#inExpand = false;
            if (bufferedResize) {
              console.log("[paginator] expand: replay buffered resize after expand", bufferedResize);
              this.#handleResize(bufferedResize);
            }
            resolve();
          }
        });
      });
    }
    set overlayer(overlayer) {
      this.#overlayer = overlayer;
      if (overlayer?.element) {
        this.#element.append(overlayer.element);
      }
    }
    get overlayer() {
      return this.#overlayer;
    }
    destroy() {
      if (this.#sameDocumentObservedElement) {
        this.#resizeObserver.unobserve(this.#sameDocumentObservedElement);
        this.#sameDocumentObservedElement = null;
      } else if (this.document?.body) {
        this.#resizeObserver.unobserve(this.document.body);
      }
      if (this.#sameDocumentMode) {
        this.#resetSameDocumentState();
      }
    }
  };
  var Paginator = class extends HTMLElement {
    static observedAttributes = [
      "flow",
      "gap",
      "marginTop",
      "marginBottom",
      "max-inline-size",
      "max-block-size",
      "max-column-count"
    ];
    #logChevronDispatch(_event, _payload = {}) {
    }
    #emitChevronOpacity(detail, source) {
      if (!CHEVRON_VISUALS_ENABLED) return;
      const nextLeft = detail?.leftOpacity ?? null;
      const nextRight = detail?.rightOpacity ?? null;
      if (this.#lastChevronEmit.left === nextLeft && this.#lastChevronEmit.right === nextRight) {
        this.#logChevronDispatch("sideNavChevronOpacity:ignoredDuplicate", {
          source: source ?? null,
          leftOpacity: nextLeft,
          rightOpacity: nextRight,
          bookDir: this.bookDir ?? null,
          rtl: this.#rtl
        });
        return;
      }
      this.#lastChevronEmit = { left: nextLeft, right: nextRight };
      const payload = { ...detail };
      if (source !== void 0) payload.source = source;
      const shouldLog = payload?.leftOpacity === "" || payload?.rightOpacity === "" || Number(payload?.leftOpacity) >= 1 || Number(payload?.rightOpacity) >= 1 || typeof source === "string" && source.includes("reset");
      if (shouldLog) {
        this.#logChevronDispatch("sideNavChevronOpacity:emit", {
          source: payload?.source ?? null,
          leftOpacity: payload?.leftOpacity ?? null,
          rightOpacity: payload?.rightOpacity ?? null,
          bookDir: this.bookDir ?? null,
          rtl: this.#rtl,
          touchTriggeredNav: this.#touchTriggeredNav,
          touchHasShownChevron: this.#touchHasShownChevron,
          maxLeft: this.#maxChevronLeft,
          maxRight: this.#maxChevronRight
        });
      }
      this.dispatchEvent(new CustomEvent("sideNavChevronOpacity", {
        bubbles: true,
        composed: true,
        detail: payload
      }));
    }
    #root = this.attachShadow({
      mode: "closed"
    });
    #debouncedRender = debounce(() => {
      if (!this.layout) return;
      this.render(this.layout, { source: "resize" });
    }, 333);
    #lastResizerRect = null;
    #resizeObserverFrame = null;
    #pendingResizeRect = null;
    #resizeObserver = new ResizeObserver((entries) => {
      if (this.#isCacheWarmer) return;
      const entry = entries[0];
      if (!entry) return;
      const rect = entry.contentRect;
      this.#pendingResizeRect = {
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        top: Math.round(rect.top),
        left: Math.round(rect.left)
      };
      if (this.#resizeObserverFrame !== null) cancelAnimationFrame(this.#resizeObserverFrame);
      this.#resizeObserverFrame = requestAnimationFrame(() => {
        this.#resizeObserverFrame = null;
        this.#handleContainerResize(this.#pendingResizeRect);
      });
    });
    #suppressBakeOnExpand = false;
    #handleContainerResize(newSize) {
      if (!newSize) return;
      const old = this.#lastResizerRect;
      const changed = !old || newSize.width !== old.width || newSize.height !== old.height || newSize.top !== old.top || newSize.left !== old.left;
      if (!changed) {
        logEBookResize("container-resize-no-change", {
          newSize,
          old
        });
        return;
      }
      this.#lastResizerRect = newSize;
      this.#cachedSizes = null;
      this.#cachedStart = null;
      logEBookResize("container-resize-change", {
        newSize,
        old
      });
      this.#debouncedRender();
      if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED) {
        requestAnimationFrame(() => {
          const r2 = this.#container?.getBoundingClientRect?.();
          logEBookPerf("RECT.container-resize-check", {
            rect: r2 ? {
              width: Math.round(r2.width),
              height: Math.round(r2.height),
              top: Math.round(r2.top),
              left: Math.round(r2.left)
            } : null,
            last: this.#lastResizerRect
          });
          if (!r2) return;
          const stable = {
            width: Math.round(r2.width),
            height: Math.round(r2.height),
            top: Math.round(r2.top),
            left: Math.round(r2.left)
          };
          const still = stable.width === this.#lastResizerRect?.width && stable.height === this.#lastResizerRect?.height;
          if (!still) {
            logEBookResize("container-resize-unstable", {
              stable,
              last: this.#lastResizerRect,
              compareTopLeft: true
            });
            return;
          }
          logEBookResize("container-resize-bake", {
            stable,
            reason: "container-resize",
            note: "top/left ignored for stability"
          });
          this.requestTrackingSectionGeometryBake({
            reason: "container-resize",
            restoreLocation: true
          });
          this.requestTrackingSectionSizeBake({
            reason: "container-resize",
            rect: stable
          });
        });
      } else {
        this.requestTrackingSectionGeometryBake({
          reason: "container-resize",
          restoreLocation: true
        });
      }
    }
    #top;
    #transitioning = false;
    //    #background
    #container;
    #defaultContainer;
    #header;
    #footer;
    #view;
    #ebookSectionLayout = new EbookSectionLayout();
    #ebookLayoutEventTarget = null;
    #vertical = null;
    #verticalRTL = null;
    #rtl = null;
    #directionReadyResolve = null;
    #directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
    #column = true;
    #topMargin = 0;
    #bottomMargin = 0;
    #index = -1;
    #loadingReason = null;
    #hasExpandedOnce = false;
    #activeBakeCount = 0;
    #sizeBakeDebounceTimer = null;
    #sizeBakeDebounceArgs = null;
    #trackingSizeBakeQueuedRect = null;
    get currentIndex() {
      return this.#index;
    }
    #anchor = 0;
    // anchor view to a fraction (0-1), Range, or Element
    #justAnchored = false;
    #isLoading = false;
    #locked = false;
    // while true, prevent any further navigation
    #lockTimestamp = 0;
    #styles;
    #styleMap = /* @__PURE__ */ new WeakMap();
    #scrollBounds;
    #touchState;
    #touchScrolled;
    #isCacheWarmer = false;
    #prefetchTimer = null;
    #prefetchCache = /* @__PURE__ */ new Map();
    #schedulePrefetchLoad(index) {
      const start = () => this.sections[index].load().catch(() => {
      });
      const ric = globalThis.requestIdleCallback;
      const promise = typeof ric === "function" ? new Promise((resolve) => ric(() => resolve(start()), { timeout: 500 })) : new Promise((resolve) => setTimeout(() => resolve(start()), 50));
      this.#prefetchCache.set(index, promise);
    }
    #skipTouchEndOpacity = false;
    #isAdjustingSelectionHandle = false;
    #trackingGeometryRebakeTimer = null;
    #trackingGeometryPendingReason = null;
    #trackingGeometryPendingRestoreLocation = false;
    #trackingGeometryBakeInFlight = null;
    #trackingGeometryBakeNeedsRerun = false;
    #trackingGeometryBakeQueuedRestoreLocation = false;
    #trackingGeometryBakeQueuedReason = null;
    #wheelArmed = true;
    // Hysteresis-based horizontal wheel paging
    #scrolledToAnchorOnLoad = false;
    #trackingSizeBakeTimer = null;
    #trackingSizeBakeInFlight = null;
    #trackingSizeBakeNeedsRerun = false;
    #trackingSizeBakeQueuedReason = null;
    #skipNextExpandBake = false;
    requestTrackingSectionSizeBakeDebounced = (args) => {
      logEBookResize("size-bake-requested", {
        reason: args?.reason ?? "unspecified",
        rectProvided: !!args?.rect
      });
      if (this.#sizeBakeDebounceTimer) {
        clearTimeout(this.#sizeBakeDebounceTimer);
      }
      this.#sizeBakeDebounceArgs = args;
      this.#sizeBakeDebounceTimer = setTimeout(() => {
        const pending = this.#sizeBakeDebounceArgs;
        this.#sizeBakeDebounceTimer = null;
        this.#sizeBakeDebounceArgs = null;
        logEBookResize("size-bake-debounced-fire", {
          reason: pending?.reason ?? "unspecified",
          rectProvided: !!pending?.rect
        });
        this.requestTrackingSectionSizeBake(pending);
      }, 240);
      return true;
    };
    #trackingSizeBakeReady = false;
    #trackingSizeLastObservedRect = null;
    #pendingTrackingSizeBakeReason = null;
    #lastTrackingSizeBakedRect = null;
    #relocateGeneration = 0;
    // Expose selected private state for logging/debug from View.
    get trackingSizeBakeReadyPublic() {
      return this.#trackingSizeBakeReady;
    }
    get suppressBakeOnExpandPublic() {
      return this.#suppressBakeOnExpand;
    }
    get pendingTrackingSizeBakeReasonPublic() {
      return this.#pendingTrackingSizeBakeReason;
    }
    #cachedSizes = null;
    #cachedStart = null;
    #cachedSentinelDoc = null;
    #cachedSentinelElements = [];
    #cachedTrackingSections = [];
    #cachedTrackingContainer = null;
    #sentinelGroups = [];
    #sentinelGroupsDoc = null;
    #sentinelGroupsTotal = 0;
    #sentinelGroupSize = 50;
    #visibleSentinelElements = /* @__PURE__ */ new Set();
    #sentinelElementIndex = /* @__PURE__ */ new WeakMap();
    #activeSentinelGroupRange = {
      start: null,
      end: null
    };
    #sentinelsInitialized = false;
    #hasSentinels = false;
    #lastSizesSnapshot = null;
    #lastViewSizeSnapshot = null;
    #elementVisibilityObserver = null;
    #elementMutationObserver = null;
    #sameDocumentViewport = null;
    #sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED;
    #sameDocumentCurrentPageIndex = 0;
    constructor() {
      super();
      const {
        gapPct,
        topMarginPx,
        bottomMarginPx,
        sideMarginPx,
        maxInlineSizePx,
        maxBlockSizePx,
        maxColumnCount,
        maxColumnCountPortrait
      } = CSS_DEFAULTS;
      this.#root.innerHTML = `<style>
            :host {
                display: block;
                container-type: size;
            }
            :host, #top {
                box-sizing: border-box;
                position: relative;
                overflow: hidden;
                width: 100%;
                height: 100%;
            }
            #top {
                contain: none;
        
                --_gap: ${gapPct}%;
                --_top-margin: ${topMarginPx}px;
                --_bottom-margin: ${bottomMarginPx}px;
                --_side-margin: var(--side-nav-width, ${sideMarginPx}px);
                --_max-inline-size: ${maxInlineSizePx}px;
                --_max-block-size: ${maxBlockSizePx}px;
                --_max-column-count: ${maxColumnCount};
                --_max-column-count-portrait: ${maxColumnCountPortrait};
                --_max-column-count-spread: var(--_max-column-count);
                --_half-gap: calc(var(--_gap) / 2);
                --_max-width: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                --_max-height: var(--_max-block-size);
                display: grid;
                grid-template-columns:
                    /*
                    minmax(var(--_half-gap), 1fr)
                    var(--_half-gap)
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    var(--_half-gap)
                    minmax(var(--_half-gap), 1fr);
                    */
                    var(--_side-margin)
                    1fr
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    1fr
                    var(--_side-margin); 
                grid-template-rows:
                    minmax(var(--_top-margin), 1fr)
                    minmax(0, var(--_max-height))
                    minmax(var(--_bottom-margin), 1fr);
                &.vertical {
                    --_max-column-count-spread: var(--_max-column-count-portrait);
                    --_max-width: var(--_max-block-size);
                    --_max-height: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                }
                @container (orientation: portrait) {
                    & {
                        --_max-column-count-spread: var(--_max-column-count-portrait);
                    }
                    &.vertical {
                        --_max-column-count-spread: var(--_max-column-count);
                    }
                }
            }
            #top.reader-loading {
                opacity: 0;
                pointer-events: none;
            }
            /*#background {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
            }*/
            #container {
                grid-column: 2 / 5;
                grid-row: 2;
                overflow: hidden;

                contain: none;
                will-change: auto;
                transform: none;
            }
            :host([flow="scrolled"]) #container {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
                overflow: auto;
            }
            #header {
                grid-column: 3 / 4;
                grid-row: 1;
            }
            #footer {
                grid-column: 3 / 4;
                grid-row: 3;
                align-self: end;
            }
            #header, #footer {
                display: grid;
            }
            #header {
                height: var(--_top-margin);
            }
            #footer {
                height: var(--_bottom-margin);
            }
            :is(#header, #footer) > * {
                display: flex;
                align-items: center;
                min-width: 0;
            }
            :is(#header, #footer) > * > * {
                width: 100%;
                overflow: hidden;
                white-space: nowrap;
                text-overflow: ellipsis;
                text-align: center;
                font-size: .75em;
                opacity: .6;
            }        
            /* For page-turning */
            .view-fade {
                opacity: 0.45;
                /*transition: opacity 0.85s ease-out;*/
            }
            .view-faded {
                opacity: 0.45;
            }
        </style>
        <div id="top">
            <!-- <div id="background" part="filter"></div> -->
            <div id="header"></div>
            <div id="container"></div>
            <div id="footer"></div>
        </div>
        `;
      this.#top = this.#root.getElementById("top");
      this.#container = this.#root.getElementById("container");
      this.#defaultContainer = this.#container;
      this.#header = this.#root.getElementById("header");
      this.#footer = this.#root.getElementById("footer");
      this.#resizeObserver.observe(this.#container);
      this.#attachContainerListeners(this.#container);
    }
    #attachContainerListeners(container) {
      if (!container || container.dataset.manabiPaginatorListenersAttached === "true") return;
      container.dataset.manabiPaginatorListenersAttached = "true";
      container.addEventListener("scroll", () => this.dispatchEvent(new Event("scroll")));
      container.addEventListener("scroll", debounce(async () => {
        if (this.#view?.isLoading) return;
        if (this.scrolled && !this.#isCacheWarmer) {
          const range = await this.#getVisibleRange();
          const index = this.#index;
          let fraction = 0;
          if (this.scrolled) {
            fraction = await this.start() / await this.viewSize();
          } else if (await this.pages() > 0) {
            const {
              page,
              pages
            } = this;
            fraction = (page - 1) / (pages - 2);
          }
          this.dispatchEvent(new CustomEvent("relocate", {
            detail: {
              reason: "live-scroll",
              range,
              index,
              fraction
            }
          }));
        }
      }, 450));
      container.addEventListener("scroll", debounce(async () => {
        if (this.scrolled) {
          if (this.#justAnchored) {
            this.#justAnchored = false;
          } else {
            await this.#afterScroll("scroll");
          }
        }
      }, 450));
    }
    #ensureSameDocumentViewport() {
      if (!this.#sameDocumentMode || this.#isCacheWarmer) return;
      if (this.#sameDocumentViewport) return;
      const viewportHost = document.getElementById("reader-stage") || document.body;
      const viewport = document.createElement("div");
      viewport.id = "manabi-same-document-viewport";
      Object.assign(viewport.style, {
        position: viewportHost?.id === "reader-stage" ? "absolute" : "fixed",
        inset: "0",
        overflow: "hidden",
        zIndex: "2",
        pointerEvents: "auto",
        boxSizing: "border-box",
        background: "transparent"
      });
      const container = document.createElement("div");
      container.id = "manabi-same-document-container";
      Object.assign(container.style, {
        position: "absolute",
        inset: "0",
        overflow: "hidden",
        boxSizing: "border-box",
        background: "transparent"
      });
      viewport.style.direction = "ltr";
      container.style.direction = "ltr";
      viewport.append(container);
      viewportHost.append(viewport);
      this.#resizeObserver.unobserve(this.#container);
      this.#sameDocumentViewport = viewport;
      this.#container = container;
      this.#attachContainerListeners(this.#container);
      this.#resizeObserver.observe(this.#container);
      this.#top.style.display = "none";
    }
    #teardownSameDocumentViewport() {
      if (!this.#sameDocumentViewport) return;
      this.#resizeObserver.unobserve(this.#container);
      this.#sameDocumentViewport.remove();
      this.#sameDocumentViewport = null;
      this.#container = this.#defaultContainer;
      this.#top.style.display = "";
      this.#attachContainerListeners(this.#container);
      this.#resizeObserver.observe(this.#container);
    }
    // NOTE: In this foliate-js fork, currently paginator can only open a book once
    open(book, isCacheWarmer) {
      this.style.display = "none";
      this.#isCacheWarmer = isCacheWarmer;
      this.#sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED && !isCacheWarmer;
      if (this.#sameDocumentMode) {
        this.#ensureSameDocumentViewport();
      } else {
        this.#teardownSameDocumentViewport();
      }
      this.bookDir = book.dir;
      this.sections = book.sections;
      document.removeEventListener("resetSideNavChevrons", this.#handleChevronResetEvent);
      document.addEventListener("resetSideNavChevrons", this.#handleChevronResetEvent);
      if (!this.#isCacheWarmer) {
        const opts = {
          passive: false
        };
        this.addEventListener("touchstart", this.#onTouchStart.bind(this), opts);
        this.addEventListener("touchmove", this.#onTouchMove.bind(this), opts);
        this.addEventListener("touchend", this.#onTouchEnd.bind(this));
        this.addEventListener("touchcancel", this.#onTouchCancel.bind(this));
        this.addEventListener("load", ({
          detail: {
            doc
          }
        }) => {
          doc.addEventListener("touchstart", this.#onTouchStart.bind(this), opts);
          doc.addEventListener("touchmove", this.#onTouchMove.bind(this), opts);
          doc.addEventListener("touchend", this.#onTouchEnd.bind(this));
          doc.addEventListener("touchcancel", this.#onTouchCancel.bind(this));
        });
        this.addEventListener("wheel", this.#onWheel.bind(this), opts);
      }
    }
    setSideNavWidth(widthPx) {
      this.#top?.style?.setProperty("--side-nav-width", typeof widthPx === "number" ? `${widthPx}px` : widthPx);
    }
    #createView() {
      this.#cancelTrackingGeometryBakeSchedule();
      this.#resetTrackingSectionSizeState();
      this.#hasExpandedOnce = false;
      if (this.#view) {
        this.#view.destroy();
        this.#container.removeChild(this.#view.element);
      }
      this.#view = new View({
        container: this,
        onBeforeExpand: this.#onBeforeExpand.bind(this),
        onExpand: this.#onExpand.bind(this),
        isCacheWarmer: this.#isCacheWarmer
        //            onExpand: debounce(() => this.#onExpand.bind(this), 500),
      });
      this.#container.append(this.#view.element);
      return this.#view;
    }
    #setLoading(isLoading, reason = "unspecified") {
      const isExpand = reason === "expand";
      if (isLoading && isExpand && this.#hasExpandedOnce && !this.#isLoading) {
        this.#loadingReason = reason || this.#loadingReason || "unspecified";
        logEBookFlash("loading-skip", {
          sectionIndex: this.#index,
          reason: this.#loadingReason,
          hasExpandedOnce: this.#hasExpandedOnce,
          isCacheWarmer: this.#isCacheWarmer
        });
        return;
      }
      if (this.#isLoading === isLoading) return;
      this.#isLoading = isLoading;
      this.#loadingReason = reason || this.#loadingReason || "unspecified";
      if (isLoading) {
        this.#top.classList.add("reader-loading");
        logEBookFlash("loading-start", {
          sectionIndex: this.#index,
          reason: this.#loadingReason
        });
      } else {
        this.#top.classList.remove("reader-loading");
        logEBookFlash("loading-stop", {
          sectionIndex: this.#index,
          reason: this.#loadingReason
        });
      }
    }
    requestTrackingSectionGeometryBake({
      reason = "unspecified",
      restoreLocation = false,
      immediate = false
    } = {}) {
      return;
    }
    requestTrackingSectionSizeBake({
      reason = "unspecified",
      rect = null,
      sectionIndex = null,
      skipPostBakeRefresh = false
    } = {}) {
      if (reason === "styles-applied" && !this.#trackingSizeBakeReady) {
        logEBookPerf("tracking-size-bake-request", {
          reason,
          sectionIndex: sectionIndex ?? this.#index,
          status: "skip-not-ready-styles-applied"
        });
        logEBookResize("size-bake-skip", {
          reason,
          sectionIndex: sectionIndex ?? this.#index,
          status: "skip-not-ready-styles-applied",
          ready: this.#trackingSizeBakeReady
        });
        return false;
      }
      const ctxBase = {
        reason,
        sectionIndex: sectionIndex ?? this.#index,
        hasDoc: !!this.#view?.document,
        ready: this.#trackingSizeBakeReady,
        inFlight: !!this.#trackingSizeBakeInFlight,
        pendingReason: this.#pendingTrackingSizeBakeReason || null
      };
      if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
        logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "disabled" });
        this.#setLoading(false, "size-bake-disabled");
        return false;
      }
      if (this.#isCacheWarmer) return false;
      if (!this.#view?.document) {
        logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "no-document" });
        logEBookResize("size-bake-skip", { ...ctxBase, status: "no-document" });
        this.#pendingTrackingSizeBakeReason = reason;
        return false;
      }
      if (!this.#trackingSizeBakeReady) {
        logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "not-ready" });
        logEBookResize("size-bake-skip", { ...ctxBase, status: "not-ready" });
        this.#pendingTrackingSizeBakeReason = reason;
        return false;
      }
      if (rect) {
        const last = this.#trackingSizeLastObservedRect;
        const unchanged = last && rect.width === last.width && rect.height === last.height && rect.top === last.top && rect.left === last.left;
        if (unchanged) {
          logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "unchanged-rect" });
          logEBookResize("size-bake-skip", { ...ctxBase, status: "unchanged-rect", rect });
          return false;
        }
        this.#trackingSizeLastObservedRect = rect;
      } else {
        const cachedBodyRect = this.#view?.getLastBodyRect?.();
        if (!cachedBodyRect) {
          logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "no-cached-rect" });
          logEBookResize("size-bake-skip", { ...ctxBase, status: "no-cached-rect" });
          return false;
        }
        const derived = {
          width: Math.round(cachedBodyRect.width),
          height: Math.round(cachedBodyRect.height),
          top: Math.round(cachedBodyRect.top),
          left: Math.round(cachedBodyRect.left)
        };
        const lastBaked = this.#lastTrackingSizeBakedRect;
        if (lastBaked && derived.width === lastBaked.width && derived.height === lastBaked.height && derived.top === lastBaked.top && derived.left === lastBaked.left) {
          logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "unchanged-derived" });
          logEBookResize("size-bake-skip", { ...ctxBase, status: "unchanged-derived", derived });
          return false;
        }
        this.#trackingSizeLastObservedRect = derived;
      }
      if (this.#trackingSizeBakeInFlight) {
        const sameQueuedReason = this.#trackingSizeBakeQueuedReason === reason;
        const sameQueuedRect = rect && this.#trackingSizeBakeQueuedRect && rect.width === this.#trackingSizeBakeQueuedRect.width && rect.height === this.#trackingSizeBakeQueuedRect.height && rect.top === this.#trackingSizeBakeQueuedRect.top && rect.left === this.#trackingSizeBakeQueuedRect.left;
        if (sameQueuedReason && sameQueuedRect) {
          logEBookResize("size-bake-queued-skip-same", { ...ctxBase, rectProvided: !!rect });
          return true;
        }
        this.#trackingSizeBakeNeedsRerun = true;
        this.#trackingSizeBakeQueuedReason = reason;
        this.#trackingSizeBakeQueuedRect = rect || this.#trackingSizeBakeQueuedRect;
        logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "queued-rerun" });
        logEBookPageNumLimited("bake:request", { ...ctxBase, status: "queued-rerun" });
        logEBookResize("size-bake-queued-rerun", { ...ctxBase, rectProvided: !!rect, rect });
        return true;
      }
      this.#trackingSizeBakeQueuedReason = null;
      this.#trackingSizeBakeNeedsRerun = false;
      this.#trackingSizeBakeQueuedRect = null;
      logEBookPerf("tracking-size-bake-request", { ...ctxBase, status: "start" });
      logEBookPageNumLimited("bake:request", { ...ctxBase, status: "start", rectProvided: !!rect });
      logEBookResize("size-bake-start", { ...ctxBase, rectProvided: !!rect, rect });
      this.#trackingSizeBakeInFlight = this.#performTrackingSectionSizeBake({
        reason,
        sectionIndex: sectionIndex ?? this.#index,
        skipPostBakeRefresh
      }).catch((error) => {
        console.error("tracking size bake error", error);
        logEBookPageNumLimited("bake:error", { ...ctxBase, error: String(error) });
        logEBookResize("size-bake-error", { ...ctxBase, error: String(error) });
      }).finally(() => {
        this.#trackingSizeBakeInFlight = null;
        if (this.#trackingSizeBakeNeedsRerun) {
          const queuedReason = this.#trackingSizeBakeQueuedReason || "rerun";
          this.#trackingSizeBakeNeedsRerun = false;
          this.requestTrackingSectionSizeBake({ reason: queuedReason });
        }
      });
      return true;
    }
    #resetTrackingSectionSizeState() {
      if (this.#trackingSizeBakeTimer) {
        clearTimeout(this.#trackingSizeBakeTimer);
        this.#trackingSizeBakeTimer = null;
      }
      this.#trackingSizeBakeInFlight = null;
      this.#trackingSizeBakeNeedsRerun = false;
      this.#trackingSizeBakeQueuedReason = null;
      this.#trackingSizeLastObservedRect = null;
      this.#pendingTrackingSizeBakeReason = null;
      this.#trackingSizeBakeReady = false;
      this.#lastTrackingSizeBakedRect = null;
      this.#skipNextExpandBake = false;
      this.#loadingReason = null;
      this.#cachedSentinelDoc = null;
      this.#cachedSentinelElements = [];
      this.#cachedTrackingSections = [];
      logEBookPageNumLimited("bake:reset-state", {
        sectionIndex: this.#index ?? null
      });
    }
    #revealPreBakeContent() {
      if (!this.#view?.document) return;
      revealDocumentContentForBake(this.#view.document);
      logEBookPageNumLimited("bake:reveal-prebake-content", {
        sectionIndex: this.#index ?? null
      });
    }
    // Public helper for View to force an initial size bake before first expand.
    async performInitialBakeFromView(sectionIndex, layout) {
      if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
        this.#suppressBakeOnExpand = false;
        this.#trackingSizeBakeReady = true;
        logEBookPageNumLimited("bake:initial:skipped", {
          sectionIndex,
          suppressBakeOnExpand: this.#suppressBakeOnExpand,
          readyFlag: this.#trackingSizeBakeReady
        });
        await this.#view?.render(layout, { source: "initial-bake-disabled" });
        return;
      }
      this.#suppressBakeOnExpand = true;
      this.#trackingSizeBakeReady = false;
      logEBookBake("initial-bake:start", {
        sectionIndex,
        suppressBakeOnExpand: this.#suppressBakeOnExpand
      });
      logEBookPageNumLimited("bake:initial:start", {
        sectionIndex,
        suppressBakeOnExpand: this.#suppressBakeOnExpand,
        readyFlag: this.#trackingSizeBakeReady
      });
      await this.#view?.render(layout, { skipExpand: true, source: "initial-bake-pre-render" });
      logEBookPerf("tracking-size-bake-initial-from-view", {
        sectionIndex,
        ready: this.#trackingSizeBakeReady
      });
      const hasTrackingSections = !!this.#view?.document?.querySelector?.(MANABI_TRACKING_SECTION_SELECTOR);
      if (!hasTrackingSections) {
        this.#trackingSizeBakeReady = true;
        this.#suppressBakeOnExpand = false;
        this.#skipNextExpandBake = true;
        logEBookBake("initial-bake:skip-no-tracking-sections", {
          sectionIndex,
          ready: this.#trackingSizeBakeReady,
          suppressBakeOnExpand: this.#suppressBakeOnExpand
        });
        logEBookBake("initial-bake:done-no-tracking-sections", {
          sectionIndex,
          ready: this.#trackingSizeBakeReady,
          suppressBakeOnExpand: this.#suppressBakeOnExpand
        });
        return;
      }
      logEBookPerf("EXPAND.callsite", {
        source: "initial-bake-start",
        suppressBakeOnExpand: this.#suppressBakeOnExpand,
        ready: this.#trackingSizeBakeReady
      });
      try {
        await this.#performTrackingSectionSizeBake({
          reason: "initial-load",
          sectionIndex,
          skipPostBakeRefresh: true
        });
        logEBookBake("initial-bake:after-perform", {
          sectionIndex,
          ready: this.#trackingSizeBakeReady,
          suppressBakeOnExpand: this.#suppressBakeOnExpand
        });
      } finally {
      }
      logEBookPerf("EXPAND.callsite", {
        source: "initial-bake-after-bake",
        suppressBakeOnExpand: this.#suppressBakeOnExpand,
        ready: this.#trackingSizeBakeReady,
        bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null
      });
      this.#suppressBakeOnExpand = false;
      this.#skipNextExpandBake = true;
      logEBookBake("initial-bake:post-render-begin", {
        sectionIndex,
        ready: this.#trackingSizeBakeReady,
        suppressBakeOnExpand: this.#suppressBakeOnExpand
      });
      await this.#view?.render(layout, { source: "initial-bake-post-render" });
      logEBookPerf("EXPAND.callsite", {
        source: "initial-bake-after-render",
        suppressBakeOnExpand: this.#suppressBakeOnExpand,
        ready: this.#trackingSizeBakeReady,
        bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null
      });
      logEBookPageNumLimited("bake:initial:done", {
        sectionIndex,
        ready: this.#trackingSizeBakeReady,
        suppressBakeOnExpand: this.#suppressBakeOnExpand
      });
      logEBookBake("initial-bake:done", {
        sectionIndex,
        ready: this.#trackingSizeBakeReady,
        suppressBakeOnExpand: this.#suppressBakeOnExpand
      });
    }
    async #performTrackingSectionSizeBake({
      reason = "unspecified",
      sectionIndex = null,
      skipPostBakeRefresh = false
    } = {}) {
      if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
        logEBookPageNumLimited("bake:begin", {
          reason,
          sectionIndex,
          status: "disabled"
        });
        this.#setLoading(false, "size-bake-disabled");
        return;
      }
      const perfStart = performance?.now?.() ?? null;
      const doc = this.#view?.document;
      if (!doc) {
        logEBookPerf("tracking-size-bake-begin", {
          reason,
          sectionIndex,
          status: "no-doc"
        });
        logEBookPageNumLimited("bake:begin", {
          reason,
          sectionIndex,
          status: "no-doc"
        });
        this.#setLoading(false, "size-bake-no-doc");
        return;
      }
      this.#view?.revealIframeForBake(reason);
      logEBookPerf("tracking-size-bake-begin", {
        reason,
        sectionIndex,
        isCacheWarmer: this.#isCacheWarmer,
        hasDoc: !!doc
      });
      logEBookPageNumLimited("bake:begin", {
        reason,
        sectionIndex,
        isCacheWarmer: this.#isCacheWarmer,
        hasDoc: !!doc,
        readyFlag: this.#trackingSizeBakeReady,
        pendingReason: this.#pendingTrackingSizeBakeReason ?? null
      });
      logEBookBake("bake:begin", {
        reason,
        sectionIndex,
        isCacheWarmer: this.#isCacheWarmer,
        readyFlag: this.#trackingSizeBakeReady,
        pendingReason: this.#pendingTrackingSizeBakeReason ?? null
      });
      logEBookFlash("size-bake-begin", {
        sectionIndex: sectionIndex ?? this.#index,
        reason,
        activeBakeCount: this.#activeBakeCount,
        hasExpandedOnce: this.#hasExpandedOnce,
        loadingReason: this.#loadingReason,
        isLoading: this.#isLoading
      });
      const activeView = this.#view;
      this.#activeBakeCount += 1;
      if (this.#activeBakeCount === 1) {
        const shouldShowLoading = !(this.#hasExpandedOnce && reason !== "initial-load");
        if (shouldShowLoading) {
          this.#setLoading(true, "size-bake");
        } else {
          logEBookFlash("loading-skip", {
            sectionIndex: sectionIndex ?? this.#index,
            reason: "size-bake",
            bakeReason: reason,
            hasExpandedOnce: this.#hasExpandedOnce,
            isCacheWarmer: this.#isCacheWarmer
          });
        }
      }
      hideDocumentContentForPreBake(doc);
      this.#trackingSizeBakeReady = false;
      logEBookPageNumLimited("bake:flag-reset-false", {
        reason,
        sectionIndex
      });
      logEBookBake("bake:flag-reset", {
        reason,
        sectionIndex
      });
      try {
        await nextFrame();
        await bakeTrackingSectionSizes(doc, {
          vertical: this.#vertical,
          reason,
          sectionIndex,
          bookId: this.bookDir,
          sectionHref: this.sections?.[this.#index]?.href || this.sections?.[this.#index]?.url || null
        });
        try {
          await this.#getSentinelVisibilities();
        } catch (error) {
        }
        const cachedBodyRect = this.#view?.getLastBodyRect?.();
        if (cachedBodyRect) {
          this.#lastTrackingSizeBakedRect = {
            width: Math.round(cachedBodyRect.width),
            height: Math.round(cachedBodyRect.height),
            top: Math.round(cachedBodyRect.top),
            left: Math.round(cachedBodyRect.left)
          };
          logEBookPageNumLimited("bake:last-baked-rect", {
            sectionIndex,
            rect: this.#lastTrackingSizeBakedRect
          });
        }
        this.#trackingSizeBakeQueuedRect = null;
        if (!skipPostBakeRefresh && !this.#isCacheWarmer && this.#view === activeView && sectionIndex === this.#index) {
          try {
            logEBookPerf("EXPAND.callsite", {
              source: "post-bake-refresh",
              suppressBakeOnExpand: this.#suppressBakeOnExpand,
              ready: this.#trackingSizeBakeReady
            });
            this.#suppressBakeOnExpand = true;
            if (typeof this.render === "function") {
              await this.render(this.layout, { source: "post-bake-refresh" });
            } else {
            }
            this.#suppressBakeOnExpand = false;
            await this.#afterScroll("bake");
          } catch (error) {
            this.#suppressBakeOnExpand = false;
          }
        }
      } finally {
        this.#revealPreBakeContent();
        if (this.#view === activeView) {
          this.#activeBakeCount = Math.max(0, this.#activeBakeCount - 1);
          const keepLoading = this.#activeBakeCount > 0 || !!this.#sizeBakeDebounceTimer || !!this.#trackingSizeBakeNeedsRerun;
          if (keepLoading) {
            logEBookFlash("loading-keep", {
              sectionIndex: this.#index,
              reason: "size-bake-pending",
              activeBakeCount: this.#activeBakeCount,
              debouncePending: !!this.#sizeBakeDebounceTimer,
              rerunQueued: !!this.#trackingSizeBakeNeedsRerun
            });
          } else {
            this.#setLoading(false, "size-bake-complete");
          }
          logEBookFlash("size-bake-finish", {
            sectionIndex: this.#index,
            reason,
            keepLoading,
            activeBakeCount: this.#activeBakeCount,
            debouncePending: !!this.#sizeBakeDebounceTimer,
            rerunQueued: !!this.#trackingSizeBakeNeedsRerun
          });
        }
        const durationMs = perfStart !== null && typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() - perfStart : null;
        logEBookPerf("tracking-size-bake-complete", {
          reason,
          sectionIndex,
          durationMs,
          stillActiveView: this.#view === activeView
        });
        logEBookPerf("tracking-size-bake-ready-reset", {
          reason,
          sectionIndex,
          ready: this.#trackingSizeBakeReady
        });
        if (this.#view === activeView) {
          this.#trackingSizeBakeReady = true;
          logEBookPerf("tracking-size-bake-ready-set", {
            reason,
            sectionIndex,
            ready: this.#trackingSizeBakeReady
          });
          logEBookBake("bake:ready-set", {
            reason,
            sectionIndex,
            durationMs,
            stillActiveView: this.#view === activeView,
            lastBakedRect: this.#lastTrackingSizeBakedRect ?? null,
            lastObservedRect: this.#trackingSizeLastObservedRect ?? null
          });
          logEBookPageNumLimited("bake:ready-set", {
            reason,
            sectionIndex,
            durationMs,
            stillActiveView: this.#view === activeView,
            lastBakedRect: this.#lastTrackingSizeBakedRect ?? null,
            lastObservedRect: this.#trackingSizeLastObservedRect ?? null,
            readyFlag: this.#trackingSizeBakeReady
          });
        }
      }
    }
    #cancelTrackingGeometryBakeSchedule() {
      if (this.#trackingGeometryRebakeTimer) {
        clearTimeout(this.#trackingGeometryRebakeTimer);
        this.#trackingGeometryRebakeTimer = null;
      }
      this.#trackingGeometryPendingReason = null;
      this.#trackingGeometryPendingRestoreLocation = false;
    }
    async #performTrackingSectionGeometryBake({
      reason = "unspecified",
      restoreLocation = false
    } = {}) {
      return;
    }
    async #safeCaptureVisibleRange() {
      try {
        const range = await this.#getVisibleRange();
        if (!range) return null;
        if (typeof range.cloneRange === "function") return range.cloneRange();
        return range;
      } catch (error) {
        return null;
      }
    }
    async #calculateSentinelGroupSize(totalSentinels) {
      const defaultSize = 50;
      if (!Number.isFinite(totalSentinels) || totalSentinels <= 0) return defaultSize;
      let pages = null;
      try {
        pages = await this.pages();
      } catch {
      }
      const targetGroups = Math.max(1, Math.round((pages ?? 0) * 1.5));
      if (!Number.isFinite(targetGroups) || targetGroups <= 0) return defaultSize;
      return Math.max(1, Math.ceil(totalSentinels / targetGroups));
    }
    #resetSentinelObservers() {
      for (const group of this.#sentinelGroups) {
        try {
          group?.observer?.disconnect?.();
        } catch {
        }
      }
      this.#sentinelGroups = [];
      this.#sentinelGroupsDoc = null;
      this.#sentinelGroupsTotal = 0;
      this.#sentinelGroupSize = 50;
      this.#visibleSentinelElements = /* @__PURE__ */ new Set();
      this.#sentinelElementIndex = /* @__PURE__ */ new WeakMap();
      this.#activeSentinelGroupRange = {
        start: null,
        end: null
      };
      this.#sentinelsInitialized = false;
    }
    #makeSentinelObserver(groupIndex) {
      return new IntersectionObserver((entries) => {
        this.#handleSentinelIntersections(groupIndex, entries);
      }, {
        root: this.#container ?? null,
        rootMargin: `${MANABI_SENTINEL_ROOT_MARGIN_PX}px`,
        threshold: [0]
      });
    }
    #createSentinelGroup(groupIndex) {
      const visible = /* @__PURE__ */ new Set();
      return {
        index: groupIndex,
        observer: null,
        elements: [],
        visible,
        startIndex: groupIndex * this.#sentinelGroupSize,
        endIndex: groupIndex * this.#sentinelGroupSize - 1,
        active: false
      };
    }
    #handleSentinelIntersections(groupIndex, entries) {
      const group = this.#sentinelGroups?.[groupIndex];
      if (!group) return;
      for (const entry of entries || []) {
        const el = entry.target;
        if (!el) continue;
        const isVisible = entry.isIntersecting || (entry.intersectionRatio ?? 0) > 0;
        if (isVisible) {
          group.visible.add(el);
          this.#visibleSentinelElements.add(el);
        } else {
          group.visible.delete(el);
          this.#visibleSentinelElements.delete(el);
        }
      }
    }
    #deactivateSentinelGroup(group) {
      if (!group || !group.active) return;
      for (const el of group.elements) {
        try {
          group.observer?.unobserve?.(el);
        } catch {
        }
        group.visible.delete(el);
        this.#visibleSentinelElements.delete(el);
      }
      group.active = false;
    }
    #activateSentinelGroup(group) {
      if (!group || group.active) return;
      if (!group.observer) {
        group.observer = this.#makeSentinelObserver(group.index ?? 0);
      }
      for (const el of group.elements) {
        group.observer.observe(el);
      }
      group.active = true;
    }
    #syncSentinelGroups(doc, sentinelElements, groupSize) {
      const total = sentinelElements?.length ?? 0;
      this.#hasSentinels = total > 0;
      if (this.#sentinelGroupsDoc !== doc || this.#sentinelGroupsTotal !== total) {
        this.#resetSentinelObservers();
        this.#sentinelGroupsDoc = doc;
        this.#sentinelGroupsTotal = total;
      }
      if (!Number.isFinite(groupSize) || groupSize <= 0) groupSize = 50;
      this.#sentinelGroupSize = groupSize;
      const requiredGroups = Math.max(0, Math.ceil(total / this.#sentinelGroupSize));
      while (this.#sentinelGroups.length < requiredGroups) {
        this.#sentinelGroups.push(this.#createSentinelGroup(this.#sentinelGroups.length));
      }
      while (this.#sentinelGroups.length > requiredGroups) {
        const group = this.#sentinelGroups.pop();
        try {
          group?.observer?.disconnect?.();
        } catch {
        }
      }
      for (let groupIndex = 0; groupIndex < requiredGroups; groupIndex++) {
        const start = groupIndex * this.#sentinelGroupSize;
        const end = Math.min(total, start + this.#sentinelGroupSize);
        const slice = sentinelElements.slice(start, end);
        const group = this.#sentinelGroups[groupIndex];
        const unchanged = group.elements.length === slice.length && group.elements.every((el, idx) => el === slice[idx]);
        if (!unchanged) {
          if (group.active) {
            for (const el of group.elements) {
              try {
                group.observer?.unobserve?.(el);
              } catch {
              }
            }
          }
          for (const el of group.elements) {
            group.visible.delete(el);
            this.#visibleSentinelElements.delete(el);
          }
          group.elements = slice;
          group.visible.clear();
          group.active = false;
        }
        group.startIndex = start;
        group.endIndex = end - 1;
        slice.forEach((el, idx) => this.#sentinelElementIndex.set(el, start + idx));
      }
    }
    #updateSentinelGroupActivation(startGroup, endGroup) {
      if (!Array.isArray(this.#sentinelGroups) || this.#sentinelGroups.length === 0) return;
      for (let i2 = 0; i2 < this.#sentinelGroups.length; i2++) {
        const group = this.#sentinelGroups[i2];
        const withinRange = startGroup !== null && endGroup !== null && i2 >= startGroup && i2 <= endGroup;
        if (withinRange) this.#activateSentinelGroup(group);
        else this.#deactivateSentinelGroup(group);
      }
      this.#activeSentinelGroupRange = {
        start: startGroup,
        end: endGroup
      };
    }
    #flushSentinelRecords(startGroup = 0, endGroup = this.#sentinelGroups.length - 1) {
      if (!Array.isArray(this.#sentinelGroups) || this.#sentinelGroups.length === 0) return;
      const start = Math.max(0, startGroup);
      const end = Math.min(this.#sentinelGroups.length - 1, endGroup);
      for (let i2 = start; i2 <= end; i2++) {
        const group = this.#sentinelGroups[i2];
        const records = group?.observer?.takeRecords?.() ?? [];
        if (records.length) this.#handleSentinelIntersections(i2, records);
      }
    }
    #collectVisibleSentinelSnapshot() {
      if (!this.#visibleSentinelElements || this.#visibleSentinelElements.size === 0) {
        return {
          visibleIds: [],
          minIndex: null,
          maxIndex: null
        };
      }
      const indexed = [];
      let minIndex = null;
      let maxIndex = null;
      for (const el of this.#visibleSentinelElements) {
        const idx = this.#sentinelElementIndex.get(el);
        if (typeof idx === "number") {
          if (minIndex === null || idx < minIndex) minIndex = idx;
          if (maxIndex === null || idx > maxIndex) maxIndex = idx;
        }
        if (el?.id) indexed.push({
          id: el.id,
          idx: typeof idx === "number" ? idx : Number.POSITIVE_INFINITY
        });
      }
      indexed.sort((a2, b2) => (a2.idx ?? 0) - (b2.idx ?? 0));
      const visibleIds = indexed.map((item) => item.id);
      return {
        visibleIds,
        minIndex,
        maxIndex
      };
    }
    async #onBeforeExpand() {
      logEBookPerf("on-before-expand", {
        pendingBakeReason: this.#pendingTrackingSizeBakeReason || null,
        vertical: this.#vertical,
        column: this.#column
      });
      this.#revealPreBakeContent();
      this.#view.cachedViewSize = null;
      this.#view.cachedSizes = null;
      this.#cachedStart = null;
      this.#setLoading(true, "expand");
      this.#cachedStart = null;
      this.#trackingSizeBakeReady = false;
      this.#trackingSizeLastObservedRect = null;
    }
    async #onExpand() {
      this.#view.cachedViewSize = null;
      this.#view.cachedSizes = null;
      this.#cachedStart = null;
      const layoutSync = await this.#syncEbookSectionLayout({
        reason: "expand"
      });
      if (this.#scrolledToAnchorOnLoad) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        await this.#scrollToAnchor(layoutSync?.restoreAnchor ?? this.#anchor);
      }
      this.#trackingSizeBakeReady = true;
      const pendingReason = this.#pendingTrackingSizeBakeReason;
      this.#pendingTrackingSizeBakeReason = null;
      this.#hasExpandedOnce = true;
      if (!(this.#isLoading && this.#loadingReason === "size-bake")) {
        this.#setLoading(false, "expand");
      }
      const skipNextExpandBake = this.#skipNextExpandBake;
      const shouldBake = !this.#suppressBakeOnExpand && !skipNextExpandBake;
      this.#skipNextExpandBake = false;
      logEBookPerf("on-expand", {
        pendingReason: pendingReason || null,
        suppressBake: this.#suppressBakeOnExpand,
        skipNext: skipNextExpandBake,
        hasDoc: !!this.#view?.document,
        vertical: this.#vertical,
        column: this.#column
      });
      logEBookPageNumLimited("bake:on-expand", {
        sectionIndex: this.#index ?? null,
        pendingReason: pendingReason || null,
        suppressBake: this.#suppressBakeOnExpand,
        readyFlag: this.#trackingSizeBakeReady,
        skipNext: skipNextExpandBake
      });
      if (shouldBake) {
        this.requestTrackingSectionSizeBake({ reason: pendingReason || "expand" });
      }
    }
    #getActiveEbookSectionLayout() {
      const doc = this.#view?.document;
      if (!(doc instanceof Document)) return null;
      if (this.scrolled || doc.body?.dataset?.isEbook !== "true") return null;
      return this.#ebookSectionLayout.getSourceDocument() ? this.#ebookSectionLayout : null;
    }
    #getLiveChunkPageCount() {
      return this.#getActiveEbookSectionLayout()?.pageCount() || getLiveChunkPageCount(this.#view?.document);
    }
    #getSameDocumentLiveRoot() {
      const doc = this.#view?.document;
      if (!(doc instanceof Document)) return null;
      const contentRoot = doc.getElementById?.("reader-content") || doc.body || null;
      return contentRoot?.querySelector?.(".manabi-page-root") || null;
    }
    #getSameDocumentResolvedPageCountSync() {
      const livePageCount = this.#getLiveChunkPageCount();
      if (Number.isFinite(livePageCount) && livePageCount > 0) return livePageCount;
      const liveRoot = this.#getSameDocumentLiveRoot();
      const domPageCount = liveRoot?.querySelectorAll?.(":scope > .manabi-page")?.length ?? 0;
      return Math.max(0, domPageCount);
    }
    async #getSameDocumentResolvedPageCount() {
      return this.#getSameDocumentResolvedPageCountSync();
    }
    #getSameDocumentClampedPageIndexSync(pageIndex = this.#sameDocumentCurrentPageIndex) {
      const pageCount = this.#getSameDocumentResolvedPageCountSync();
      if (!(pageCount > 0)) return 0;
      const numericPageIndex = Number.isFinite(pageIndex) ? Math.floor(pageIndex) : this.#sameDocumentCurrentPageIndex;
      return Math.max(0, Math.min(pageCount - 1, numericPageIndex));
    }
    async #getSameDocumentClampedPageIndex(pageIndex = this.#sameDocumentCurrentPageIndex) {
      return this.#getSameDocumentClampedPageIndexSync(pageIndex);
    }
    #applySameDocumentPagePositionSync(pageIndex, { reason = "same-document", smooth = false } = {}) {
      const liveRoot = this.#getSameDocumentLiveRoot();
      if (!(liveRoot instanceof HTMLElement)) return false;
      const resolvedPageIndex = this.#getSameDocumentClampedPageIndexSync(pageIndex);
      const targetPageNode = liveRoot.querySelector(`:scope > .manabi-page[data-manabi-page-index="${resolvedPageIndex}"]`) || liveRoot.querySelector(`.manabi-page[data-manabi-page-index="${resolvedPageIndex}"]`) || null;
      const fallbackPageWidth = Number.isFinite(targetPageNode?.offsetWidth) && targetPageNode.offsetWidth > 0 ? targetPageNode.offsetWidth : liveRoot.firstElementChild?.getBoundingClientRect?.().width || this.getBoundingClientRect?.().width || 0;
      const fallbackOffset = resolvedPageIndex * fallbackPageWidth;
      const targetOffset = Number.isFinite(targetPageNode?.offsetLeft) ? targetPageNode.offsetLeft : fallbackOffset;
      const sameDocumentContainer = document.getElementById("manabi-same-document-container");
      const sameDocumentViewport = document.getElementById("manabi-same-document-viewport");
      liveRoot.style.willChange = "transform";
      liveRoot.style.transition = smooth ? "transform 220ms ease-out" : "none";
      liveRoot.style.transform = `translate3d(${-targetOffset}px, 0, 0)`;
      liveRoot.dataset.manabiCurrentPageIndex = String(resolvedPageIndex);
      if (sameDocumentContainer instanceof HTMLElement) {
        sameDocumentContainer.scrollLeft = targetOffset;
      }
      if (sameDocumentViewport instanceof HTMLElement) {
        sameDocumentViewport.scrollLeft = targetOffset;
      }
      if (this.#container instanceof HTMLElement) {
        this.#container.scrollLeft = targetOffset;
      }
      this.#sameDocumentCurrentPageIndex = resolvedPageIndex;
      setSameDocumentHostTurnDiagnostics({
        phase: "applied-position",
        reason,
        targetPageIndex: resolvedPageIndex,
        targetOffset,
        appliedTransform: liveRoot.style.transform,
        datasetCurrentPageIndex: liveRoot.dataset.manabiCurrentPageIndex ?? null
      });
      logEBookPageNumLimited("same-document:set-page-position", {
        reason,
        smooth: !!smooth,
        targetPage: resolvedPageIndex,
        targetOffset,
        fallbackOffset,
        livePageCount: this.#getSameDocumentResolvedPageCountSync()
      });
      return true;
    }
    async #applySameDocumentPagePosition(pageIndex, { reason = "same-document", smooth = false } = {}) {
      return this.#applySameDocumentPagePositionSync(pageIndex, { reason, smooth });
    }
    async #captureEbookRebuildLocation() {
      const activeLayout = this.#getActiveEbookSectionLayout();
      if (!activeLayout) return null;
      return activeLayout.captureLocationForPage(await this.page());
    }
    #handleEbookLayoutComplete = async () => {
      if (this.#ebookLayoutEventTarget !== this.#view?.document?.defaultView) return;
      if (this.scrolled || !this.#view) return;
      try {
        this.#view.reconcileSameDocumentExpandedWidth?.();
        if (this.#sameDocumentMode && !this.#vertical) {
          await this.#applySameDocumentPagePosition(this.#sameDocumentCurrentPageIndex, {
            reason: "layout-complete",
            smooth: false
          });
        }
        await this.#afterScroll("layout-complete");
      } catch (error) {
        console.error(error);
      }
    };
    #bindEbookLayoutEvents(doc) {
      const nextTarget = doc?.defaultView ?? null;
      if (this.#ebookLayoutEventTarget === nextTarget) return;
      this.#ebookLayoutEventTarget?.removeEventListener?.(
        "manabi-ebook-layout-complete",
        this.#handleEbookLayoutComplete
      );
      this.#ebookLayoutEventTarget = nextTarget;
      this.#ebookLayoutEventTarget?.addEventListener?.(
        "manabi-ebook-layout-complete",
        this.#handleEbookLayoutComplete
      );
    }
    async #syncEbookSectionLayout({ reason = "unknown", anchor = null } = {}) {
      const doc = this.#view?.document;
      if (!(doc instanceof Document)) {
        this.#bindEbookLayoutEvents(null);
        this.#ebookSectionLayout.destroy();
        return null;
      }
      if (this.scrolled || doc.body?.dataset?.isEbook !== "true") {
        this.#bindEbookLayoutEvents(null);
        this.#ebookSectionLayout.destroy();
        return null;
      }
      this.#ebookSectionLayout.attach(doc);
      this.#bindEbookLayoutEvents(doc);
      const rebuildLocation = anchor == null ? await this.#captureEbookRebuildLocation() : null;
      const result = await this.#ebookSectionLayout.build({
        reason,
        anchor: typeof anchor === "function" ? null : anchor,
        anchorResolver: typeof anchor === "function" ? anchor : null,
        location: rebuildLocation
      });
      const restoreAnchor = rebuildLocation ? this.#ebookSectionLayout.sourceRangeForLocation(rebuildLocation) : null;
      return {
        result,
        restoreAnchor
      };
    }
    #resolveAnchorAgainstActiveLayout(anchor) {
      if (typeof anchor !== "function") return anchor;
      const activeLayout = this.#getActiveEbookSectionLayout();
      const sourceDoc = activeLayout?.getSourceDocument();
      const liveDoc = this.#view?.document;
      const preferredDoc = sourceDoc ?? liveDoc;
      let resolvedAnchor = preferredDoc ? anchor(preferredDoc) : anchor;
      if (resolvedAnchor == null && sourceDoc && liveDoc && sourceDoc !== liveDoc) {
        resolvedAnchor = anchor(liveDoc);
      }
      return resolvedAnchor;
    }
    async #awaitDirection() {
      if (this.#vertical === null) await this.#directionReady;
    }
    async #getSentinelVisibilities({ allowRetry = true } = {}) {
      await nextFrame();
      const perfStart = typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : null;
      const doc = this.#view?.document;
      if (!doc?.body) return [];
      if (this.#cachedSentinelDoc !== doc) {
        this.#cachedSentinelDoc = doc;
        this.#cachedSentinelElements = Array.from(doc.body.getElementsByTagName("reader-sentinel"));
        this.#cachedTrackingSections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR));
        this.#sentinelsInitialized = false;
      } else if (!Array.isArray(this.#cachedSentinelElements) || this.#cachedSentinelElements.length === 0) {
        this.#cachedSentinelElements = Array.from(doc.body.getElementsByTagName("reader-sentinel"));
      }
      const sentinelElements = this.#cachedSentinelElements;
      logEBookPageNumLimited("bake:sentinels:init", {
        sectionIndex: this.#index ?? null,
        sentinelCount: sentinelElements.length,
        trackingSections: this.#cachedTrackingSections?.length ?? null,
        allowRetry,
        containerClientWidth: this.#container?.clientWidth ?? null,
        containerClientHeight: this.#container?.clientHeight ?? null,
        containerScrollWidth: this.#container?.scrollWidth ?? null,
        containerScrollHeight: this.#container?.scrollHeight ?? null
      });
      const applyVisibility = (reason) => {
        if (this.#cachedTrackingSections.length === 0) return;
        applySentinelVisibilityToTrackingSections(doc, {
          visibleSentinels: this.#visibleSentinelElements,
          logReason: reason,
          container: this.#container,
          sectionsCache: this.#cachedTrackingSections
        });
      };
      const bodyClasses = Array.from(doc.body?.classList ?? []);
      const isBakingHidden = bodyClasses.includes(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) || bodyClasses.includes(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS);
      if (sentinelElements.length === 0) {
        if (isBakingHidden && allowRetry && this.#trackingSizeBakeInFlight) {
          try {
            await this.#trackingSizeBakeInFlight;
          } catch {
          }
          return await this.#getSentinelVisibilities({ allowRetry: false });
        }
        applyVisibility("sentinel-visibility:none");
        this.#resetSentinelObservers();
        return [];
      }
      this.#visibleSentinelElements.clear?.();
      const docChanged = this.#sentinelGroupsDoc !== doc;
      const needsSync = docChanged || !this.#sentinelsInitialized;
      if (needsSync) {
        const groupSize = await this.#calculateSentinelGroupSize(sentinelElements.length);
        this.#syncSentinelGroups(doc, sentinelElements, groupSize);
        this.#sentinelsInitialized = true;
      }
      const groupCount = this.#sentinelGroups.length;
      if (groupCount === 0) {
        applyVisibility("sentinel-visibility:none");
        return [];
      }
      let hintGroup = 0;
      try {
        const viewSize = await this.viewSize();
        const start = await this.start();
        const fraction = viewSize > 0 ? Math.max(0, Math.min(1, start / viewSize)) : 0;
        hintGroup = Math.round(fraction * Math.max(0, groupCount - 1));
      } catch {
      }
      const activationOrder = [];
      for (let dist = 0; dist < groupCount; dist++) {
        const left = hintGroup - dist;
        const right = hintGroup + dist;
        if (dist === 0) {
          activationOrder.push(hintGroup);
          continue;
        }
        if (left >= 0) activationOrder.push(left);
        if (right < groupCount) activationOrder.push(right);
      }
      let minActive = hintGroup;
      let maxActive = hintGroup;
      let snapshot = {
        visibleIds: [],
        minIndex: null,
        maxIndex: null
      };
      let observedThisCall = 0;
      for (let i2 = 0; i2 < activationOrder.length; i2++) {
        const groupIndex = activationOrder[i2];
        const group = this.#sentinelGroups[groupIndex];
        if (!group) continue;
        this.#activateSentinelGroup(group);
        observedThisCall += group.elements.length;
        this.#flushSentinelRecords(groupIndex, groupIndex);
        minActive = Math.min(minActive, groupIndex);
        maxActive = Math.max(maxActive, groupIndex);
        snapshot = this.#collectVisibleSentinelSnapshot();
        if (snapshot.visibleIds.length === 0) continue;
        const minGroup = Math.floor(snapshot.minIndex / this.#sentinelGroupSize);
        const maxGroup = Math.floor(snapshot.maxIndex / this.#sentinelGroupSize);
        const minOnEdge = snapshot.minIndex === (this.#sentinelGroups[minGroup]?.startIndex ?? snapshot.minIndex + 1);
        const maxOnEdge = snapshot.maxIndex === (this.#sentinelGroups[maxGroup]?.endIndex ?? snapshot.maxIndex - 1);
        if (!minOnEdge && !maxOnEdge) break;
      }
      this.#updateSentinelGroupActivation(minActive, maxActive);
      this.#flushSentinelRecords(minActive, maxActive);
      snapshot = this.#collectVisibleSentinelSnapshot();
      if (snapshot.visibleIds.length === 0 && this.#sentinelGroups.length > 0) {
        this.#updateSentinelGroupActivation(0, this.#sentinelGroups.length - 1);
        observedThisCall = sentinelElements.length;
        this.#flushSentinelRecords(0, this.#sentinelGroups.length - 1);
        snapshot = this.#collectVisibleSentinelSnapshot();
      }
      const { visibleIds, minIndex, maxIndex } = snapshot;
      applyVisibility("sentinel-visibility");
      const logStart = snapshot.visibleIds.length > 0 ? minActive : 0;
      const logEnd = snapshot.visibleIds.length > 0 ? maxActive : Math.max(0, groupCount - 1);
      this.#updateSentinelGroupActivation(null, null);
      this.#visibleSentinelElements.clear?.();
      logEBookPageNumLimited("bake:sentinels:snapshot", {
        sectionIndex: this.#index ?? null,
        visibleCount: visibleIds.length,
        minIndex,
        maxIndex,
        observedThisCall,
        totalGroups: this.#sentinelGroups?.length ?? null
      });
      return visibleIds;
    }
    #disconnectElementVisibilityObserver() {
      if (this.#elementVisibilityObserver) {
        this.#elementVisibilityObserver.disconnect();
        this.#elementVisibilityObserver = null;
      }
      if (this.#elementMutationObserver) {
        this.#elementMutationObserver.disconnect();
        this.#elementMutationObserver = null;
      }
    }
    #isSingleMediaElementWithoutText() {
      const container = this.#view.document.getElementById("reader-content");
      if (!container) return false;
      const mediaTags = ["img", "image", "svg", "video", "picture", "object", "iframe", "canvas", "embed"];
      const selector = mediaTags.join(",");
      const mediaElements = container.querySelectorAll(selector);
      if (mediaElements.length !== 1) return false;
      if (container.textContent.trim() !== "") return false;
      return true;
    }
    async #beforeRender({
      vertical,
      verticalRTL,
      rtl
      //        background
    }) {
      this.#vertical = vertical;
      this.#verticalRTL = verticalRTL;
      this.#rtl = typeof rtl === "boolean" ? rtl : this.bookDir === "rtl";
      this.#top.classList.toggle("vertical", vertical);
      this.#directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
      this.style.display = "block";
      const {
        width,
        height
      } = await this.sizes();
      const size = vertical ? height : width;
      const {
        fullWidthCharacterAdvancePx,
        fullWidthCharacterThreshold,
        columnizationThresholdPx
      } = resolveColumnizationThreshold({
        doc: this.#view.document,
        vertical
      });
      const shouldColumnizeForThreshold = size > columnizationThresholdPx;
      const {
        maxInlineSizePx,
        maxColumnCount,
        maxColumnCountPortrait,
        topMarginPx,
        bottomMarginPx,
        minGapPx,
        gapPct
      } = CSS_DEFAULTS;
      const maxInlineSize = maxInlineSizePx;
      const orientationPortrait = height > width;
      let maxColumnCountSpread;
      if (orientationPortrait) {
        maxColumnCountSpread = vertical ? maxColumnCount : maxColumnCountPortrait;
      } else {
        maxColumnCountSpread = vertical ? maxColumnCountPortrait : maxColumnCount;
      }
      const topMargin = topMarginPx;
      const bottomMargin = bottomMarginPx;
      this.#topMargin = topMargin;
      this.#bottomMargin = bottomMargin;
      this.#view.document.documentElement.style.setProperty("--_max-inline-size", maxInlineSize);
      const g2 = gapPct / 100;
      const rawGap = -g2 / (g2 - 1) * size;
      const gap = Math.max(rawGap, minGapPx);
      const flow = this.getAttribute("flow") || "paginated";
      const writingMode = vertical ? verticalRTL ? "vertical-rl" : "vertical-lr" : "horizontal-tb";
      const resolvedDir = this.bookDir || (rtl ? "rtl" : "ltr");
      this.#column = flow !== "scrolled";
      if (this.#sameDocumentMode) {
        this.#view?.element?.style?.setProperty?.("direction", "ltr");
        this.#view?.document?.documentElement?.style?.setProperty?.("direction", "ltr");
        this.#view?.document?.body?.style?.setProperty?.("direction", "ltr");
        this.#sameDocumentViewport?.style?.setProperty?.("direction", "ltr");
        this.#container?.style?.setProperty?.("direction", "ltr");
      }
      if (flow === "scrolled") {
        this.#top.style.padding = "0";
        const columnWidth2 = shouldColumnizeForThreshold ? columnizationThresholdPx : size;
        this.heads = null;
        this.feet = null;
        this.#header.replaceChildren();
        this.#footer.replaceChildren();
        return {
          flow,
          topMargin,
          bottomMargin,
          gap,
          columnWidth: columnWidth2,
          shouldColumnizeForThreshold,
          fullWidthCharacterAdvancePx,
          fullWidthCharacterThreshold,
          columnizationThresholdPx,
          usePaginate: false,
          writingMode,
          direction: resolvedDir
        };
      }
      let divisor, columnWidth;
      const isSingleMediaElementWithoutText = this.#isSingleMediaElementWithoutText();
      if (isSingleMediaElementWithoutText) {
        columnWidth = maxInlineSize;
        this.#view.document.body?.classList.add("reader-is-single-media-element-without-text");
      } else {
        this.#view.document.body?.classList.remove("reader-is-single-media-element-without-text");
        if (!shouldColumnizeForThreshold) {
          divisor = 1;
          columnWidth = size - gap;
        } else {
          const effectiveInlineSize = columnizationThresholdPx;
          divisor = Math.min(maxColumnCount, Math.ceil(size / effectiveInlineSize));
          columnWidth = size / divisor - gap;
        }
      }
      this.setAttribute("dir", rtl ? "rtl" : "ltr");
      const marginalDivisor = shouldColumnizeForThreshold ? vertical ? Math.min(2, Math.ceil(width / maxInlineSize)) : divisor : 1;
      const marginalStyle = {
        gridTemplateColumns: `repeat(${marginalDivisor}, 1fr)`,
        gap: `${gap}px`,
        direction: this.bookDir === "rtl" ? "rtl" : "ltr"
      };
      Object.assign(this.#header.style, marginalStyle);
      Object.assign(this.#footer.style, marginalStyle);
      const heads = makeMarginals(marginalDivisor, "head");
      const feet = makeMarginals(marginalDivisor, "foot");
      this.heads = heads.map((el) => el.children[0]);
      this.feet = feet.map((el) => el.children[0]);
      this.#header.replaceChildren(...heads);
      this.#footer.replaceChildren(...feet);
      return {
        height,
        width,
        topMargin,
        bottomMargin,
        gap,
        columnWidth,
        divisor,
        shouldColumnizeForThreshold,
        fullWidthCharacterAdvancePx,
        fullWidthCharacterThreshold,
        columnizationThresholdPx,
        usePaginate: false,
        writingMode,
        direction: resolvedDir
      };
    }
    async render() {
      if (!this.#view) {
        return;
      }
      await this.#view.render(await this.#beforeRender({
        vertical: this.#vertical,
        rtl: this.#rtl
      }));
    }
    get scrolled() {
      return this.getAttribute("flow") === "scrolled";
    }
    async scrollProp() {
      await this.#awaitDirection();
      const {
        scrolled
      } = this;
      return this.#vertical ? scrolled ? "scrollLeft" : "scrollTop" : scrolled ? "scrollTop" : "scrollLeft";
    }
    async sideProp() {
      await this.#awaitDirection();
      const {
        scrolled
      } = this;
      return this.#vertical ? scrolled ? "width" : "height" : scrolled ? "height" : "width";
    }
    async sizes() {
      const sizes = {
        width: this.#container.clientWidth,
        height: this.#container.clientHeight
      };
      this.#logSizesOnce({
        event: "sizes",
        sectionIndex: this.#index ?? null,
        width: sizes.width,
        height: sizes.height,
        scrollWidth: this.#container.scrollWidth,
        scrollHeight: this.#container.scrollHeight,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl,
        rect: this.#container.getBoundingClientRect ? {
          width: Math.round(this.#container.getBoundingClientRect().width),
          height: Math.round(this.#container.getBoundingClientRect().height),
          top: Math.round(this.#container.getBoundingClientRect().top),
          left: Math.round(this.#container.getBoundingClientRect().left)
        } : null,
        styleHeight: this.#container?.style?.height ?? null,
        overflow: typeof getComputedStyle === "function" ? getComputedStyle(this.#container).overflow : null,
        bakeReady: this.#trackingSizeBakeReady,
        pendingBakeReason: this.#pendingTrackingSizeBakeReason ?? null,
        bakeInFlight: !!this.#trackingSizeBakeInFlight,
        usingCache: false
      });
      return sizes;
    }
    async size() {
      const s2 = (await this.sizes())[await this.sideProp()];
      logEBookPageNumLimited("size", {
        sectionIndex: this.#index ?? null,
        size: s2,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl
      });
      const container = this.#container;
      const containerClientW = container?.clientWidth ?? null;
      const containerClientH = container?.clientHeight ?? null;
      if (!Number.isFinite(s2) || s2 === 0 || containerClientW === 0 || containerClientH === 0) {
        const rect = container?.getBoundingClientRect?.();
        logEBookPageNumLimited("size:anomaly", {
          sectionIndex: this.#index ?? null,
          size: s2,
          clientWidth: containerClientW,
          clientHeight: containerClientH,
          scrollWidth: container?.scrollWidth ?? null,
          scrollHeight: container?.scrollHeight ?? null,
          scrolled: this.scrolled,
          vertical: this.#vertical,
          rtl: this.#rtl,
          rect: rect ? {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            top: Math.round(rect.top),
            left: Math.round(rect.left)
          } : null
        });
      }
      return s2;
    }
    async viewSize() {
      if (this.#isCacheWarmer) return 0;
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        const [pageCount, size] = await Promise.all([
          this.#getSameDocumentResolvedPageCount(),
          this.size()
        ]);
        const val2 = pageCount * size;
        this.#logViewSizeOnce({
          event: "viewSize:same-document",
          sectionIndex: this.#index ?? null,
          side: await this.sideProp(),
          clientWidth: this.#container?.clientWidth ?? null,
          clientHeight: this.#container?.clientHeight ?? null,
          scrollWidth: this.#container?.scrollWidth ?? null,
          scrollHeight: this.#container?.scrollHeight ?? null,
          returned: val2,
          scrolled: this.scrolled,
          vertical: this.#vertical,
          rtl: this.#rtl,
          bakeReady: this.#trackingSizeBakeReady,
          pendingBakeReason: this.#pendingTrackingSizeBakeReason ?? null,
          bakeInFlight: !!this.#trackingSizeBakeInFlight,
          usingCache: false
        });
        return val2;
      }
      const view = this.#view;
      if (!view || !view.element) return 0;
      const element = view.element;
      const side = await this.sideProp();
      const scrollWidth = element.scrollWidth;
      const scrollHeight = element.scrollHeight;
      const val = !this.scrolled ? side === "width" ? scrollWidth : scrollHeight : side === "width" ? element.clientWidth : element.clientHeight;
      this.#logViewSizeOnce({
        event: "viewSize",
        sectionIndex: this.#index ?? null,
        side,
        clientWidth: element.clientWidth,
        clientHeight: element.clientHeight,
        scrollWidth,
        scrollHeight,
        returned: val,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl,
        elemRect: element.getBoundingClientRect ? {
          width: Math.round(element.getBoundingClientRect().width),
          height: Math.round(element.getBoundingClientRect().height),
          top: Math.round(element.getBoundingClientRect().top),
          left: Math.round(element.getBoundingClientRect().left)
        } : null,
        parentRect: this.#container?.getBoundingClientRect ? {
          width: Math.round(this.#container.getBoundingClientRect().width),
          height: Math.round(this.#container.getBoundingClientRect().height),
          top: Math.round(this.#container.getBoundingClientRect().top),
          left: Math.round(this.#container.getBoundingClientRect().left)
        } : null,
        elemStyleHeight: element?.style?.height ?? null,
        elemStyleDisplay: element?.style?.display ?? null,
        parentStyleHeight: this.#container?.style?.height ?? null,
        parentOverflow: typeof getComputedStyle === "function" ? getComputedStyle(this.#container).overflow : null,
        bakeReady: this.#trackingSizeBakeReady,
        pendingBakeReason: this.#pendingTrackingSizeBakeReason ?? null,
        bakeInFlight: !!this.#trackingSizeBakeInFlight,
        usingCache: false
      });
      return val;
    }
    #logSizesOnce(payload) {
      const key = JSON.stringify({
        width: payload.width,
        height: payload.height,
        scrolled: payload.scrolled,
        vertical: payload.vertical,
        rtl: payload.rtl,
        bakeReady: payload.bakeReady,
        usingCache: payload.usingCache,
        pending: payload.pendingBakeReason ?? null
      });
      if (this.#lastSizesSnapshot === key) return;
      this.#lastSizesSnapshot = key;
      logEBookPageNumLimited(payload.event, payload);
    }
    #logViewSizeOnce(payload) {
      const key = JSON.stringify({
        side: payload.side,
        width: payload.cachedWidth ?? payload.clientWidth,
        height: payload.cachedHeight ?? payload.clientHeight,
        scrolled: payload.scrolled,
        vertical: payload.vertical,
        rtl: payload.rtl,
        bakeReady: payload.bakeReady,
        usingCache: payload.usingCache,
        pending: payload.pendingBakeReason ?? null
      });
      if (this.#lastViewSizeSnapshot === key) return;
      this.#lastViewSizeSnapshot = key;
      logEBookPageNumLimited(payload.event, payload);
    }
    async start() {
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        const pageIndex = await this.#getSameDocumentClampedPageIndex();
        const size = await this.size();
        const start2 = pageIndex * size;
        logEBookPageNumLimited("start:same-document", {
          sectionIndex: this.#index ?? null,
          start: start2,
          size,
          pageIndex
        });
        return start2;
      }
      const scrollProp = await this.scrollProp();
      const raw = this.#container[scrollProp];
      const start = Math.abs(raw);
      logEBookPageNumLimited("start", {
        sectionIndex: this.#index ?? null,
        scrollProp,
        rawScrollValue: raw,
        start,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl
      });
      return start;
    }
    async end() {
      return await this.start() + await this.size();
    }
    async page() {
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        const page2 = await this.#getSameDocumentClampedPageIndex();
        logEBookPageNumLimited("page:same-document", {
          sectionIndex: this.#index ?? null,
          page: page2
        });
        return page2;
      }
      const start = await this.start();
      const end = await this.end();
      const size = await this.size();
      const raw = (start + end) / 2;
      const page = Math.floor(raw / size);
      logEBookPageNumLimited("page", {
        sectionIndex: this.#index ?? null,
        start,
        end,
        rawMidpoint: raw,
        size,
        page,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl
      });
      return page;
    }
    async pages() {
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        const livePageCount2 = await this.#getSameDocumentResolvedPageCount();
        logEBookPageNumLimited("pages:same-document", {
          sectionIndex: this.#index ?? null,
          pages: livePageCount2,
          scrolled: this.scrolled,
          vertical: this.#vertical,
          rtl: this.#rtl
        });
        return livePageCount2;
      }
      const livePageCount = this.#getLiveChunkPageCount();
      if (livePageCount != null && !this.scrolled) {
        logEBookPageNumLimited("pages:live-chunk", {
          sectionIndex: this.#index ?? null,
          pages: livePageCount,
          scrolled: this.scrolled,
          vertical: this.#vertical,
          rtl: this.#rtl
        });
        return livePageCount;
      }
      const viewSize = await this.viewSize();
      const size = await this.size();
      const pages = Math.round(viewSize / size);
      const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED && this.#hasSentinels && !this.scrolled && !this.#vertical && pages > 2;
      const textPages = sentinelAdjusted ? Math.max(1, pages - 2) : pages;
      logEBookPageNumLimited("pages", {
        sectionIndex: this.#index ?? null,
        viewSize,
        size,
        pages,
        textPages,
        sentinelAdjusted,
        scrolled: this.scrolled,
        vertical: this.#vertical,
        rtl: this.#rtl
      });
      if (pages === 1 && this.#index !== null) {
        logEBookPageNumLimited("pages:single-page", {
          sectionIndex: this.#index,
          viewSize,
          size,
          scrolled: this.scrolled,
          vertical: this.#vertical,
          rtl: this.#rtl,
          containerClientWidth: this.#container?.clientWidth ?? null,
          containerClientHeight: this.#container?.clientHeight ?? null,
          containerScrollHeight: this.#container?.scrollHeight ?? null,
          containerScrollWidth: this.#container?.scrollWidth ?? null,
          viewCachedWidth: this.#view?.cachedViewSize?.width ?? null,
          viewCachedHeight: this.#view?.cachedViewSize?.height ?? null,
          cachedSizes: this.#cachedSizes ? { ...this.#cachedSizes } : null,
          viewClientHeight: this.#view?.element?.clientHeight ?? null,
          viewScrollHeight: this.#view?.element?.scrollHeight ?? null,
          scrollHeightEqualsClientHeight: this.#view?.element ? this.#view.element.scrollHeight === this.#view.element.clientHeight : null
        });
      }
      return pages;
    }
    async scrollBy(dx, dy) {
      await new Promise((resolve) => {
        requestAnimationFrame(async () => {
          const delta = this.#vertical ? dy : dx;
          const element = this.#container;
          const scrollProp = await this.scrollProp();
          const [offset, a2, b2] = this.#scrollBounds;
          const rtl = this.#rtl;
          const min = rtl ? offset - b2 : offset - a2;
          const max = rtl ? offset + a2 : offset + b2;
          element[scrollProp] = Math.max(min, Math.min(
            max,
            element[scrollProp] + delta
          ));
          this.#cachedStart = null;
          resolve();
        });
      });
    }
    async snap(vx, vy) {
      const velocity = this.#vertical ? vy : vx;
      const [offset, a2, b2] = this.#scrollBounds;
      const start = await this.start();
      const end = await this.end();
      const pages = await this.pages();
      const size = await this.size();
      const min = Math.abs(offset) - a2;
      const max = Math.abs(offset) + b2;
      const d2 = velocity * (this.#rtl ? -size : size);
      const page = Math.floor(
        Math.max(min, Math.min(max, (start + end) / 2 + (isNaN(d2) ? 0 : d2))) / size
      );
      await this.#scrollToPage(page, "snap").then(async () => {
        const dir = page <= 0 ? -1 : page >= pages - 1 ? 1 : null;
        if (dir) return await this.#goTo({
          index: this.#adjacentIndex(dir),
          anchor: dir < 0 ? () => 1 : () => 0,
          reason: "page"
        });
      });
    }
    #onTouchStart(e2) {
      const touch = e2.changedTouches[0];
      const target = touch.target;
      const inHost = this.#container.contains(target);
      const inIframe = this.#view?.document && target.ownerDocument === this.#view.document;
      if (!inHost && !inIframe) {
        this.#touchState = null;
        return;
      }
      this.#clearPendingChevronReset();
      this.#touchHasShownChevron = false;
      this.#touchTriggeredNav = false;
      this.#maxChevronLeft = 0;
      this.#maxChevronRight = 0;
      this.#touchState = {
        startX: touch?.screenX,
        startY: touch?.screenY,
        x: touch?.screenX,
        y: touch?.screenY,
        t: e2.timeStamp,
        vx: 0,
        vy: 0,
        pinched: false,
        triggered: false
      };
      if (!this.scrolled) {
        const sel = this.#view?.document?.getSelection?.();
        if (sel && !sel.isCollapsed && sel.rangeCount) {
          const range = sel.getRangeAt(0);
          const rect = range.getBoundingClientRect();
          logEBookPerf("RECT.selection-range", {
            width: rect?.width ?? null,
            height: rect?.height ?? null,
            left: rect?.left ?? null,
            top: rect?.top ?? null
          });
          const x2 = touch.clientX, y2 = touch.clientY;
          const hitTolerance = 30;
          const nearStart = Math.abs(x2 - rect.left) <= hitTolerance && y2 >= rect.top - hitTolerance && y2 <= rect.bottom + hitTolerance;
          const nearEnd = Math.abs(x2 - rect.right) <= hitTolerance && y2 >= rect.top - hitTolerance && y2 <= rect.bottom + hitTolerance;
          if (nearStart || nearEnd) {
            this.#isAdjustingSelectionHandle = true;
            return;
          }
        }
      }
      this.#isAdjustingSelectionHandle = false;
    }
    async #onTouchMove(e2) {
      if (!this.#touchState) return;
      if (this.#isAdjustingSelectionHandle) return;
      e2.preventDefault();
      const touch = e2.changedTouches[0];
      const state = this.#touchState;
      if (state.triggered) return;
      state.x = touch.screenX;
      state.y = touch.screenY;
      const dx = state.x - state.startX;
      const dy = state.y - state.startY;
      const minSwipe = 36;
      if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
        state.triggered = true;
        const navDetail = dx < 0 ? {
          direction: this.bookDir === "rtl" ? "backward" : "forward",
          leftOpacity: this.bookDir === "rtl" ? 0 : 1,
          rightOpacity: this.bookDir === "rtl" ? 1 : 0,
          navigate: this.bookDir === "rtl" ? () => this.prev() : () => this.next()
        } : {
          direction: this.bookDir === "rtl" ? "forward" : "backward",
          leftOpacity: this.bookDir === "rtl" ? 1 : 0,
          rightOpacity: this.bookDir === "rtl" ? 0 : 1,
          navigate: this.bookDir === "rtl" ? () => this.next() : () => this.prev()
        };
        this.#lastSwipeNavAt = Date.now();
        this.#lastSwipeNavDirection = navDetail.direction;
        this.#touchTriggeredNav = true;
        this.#emitChevronOpacity({
          leftOpacity: navDetail.leftOpacity,
          rightOpacity: navDetail.rightOpacity,
          holdMs: this.#chevronTriggerHoldMs,
          fadeMs: this.#chevronFadeMs
        }, "swipe:navImmediate");
        this.#logChevronDispatch("swipeNav:trigger", {
          dx,
          dy,
          direction: navDetail.direction,
          bookDir: this.bookDir ?? null,
          rtl: this.#rtl
        });
        await navDetail.navigate();
        this.#scheduleChevronHide(this.#chevronTriggerHoldMs + 80);
        this.#logResetNeed("postSwipeNav");
        this.#emitChevronReset("reset:postSwipeNav");
      } else {
        if (CHEVRON_SWIPE_PREVIEW_ENABLED) {
          this.#updateSwipeChevron(dx, minSwipe, "swipe");
        }
      }
    }
    #onTouchEnd(e2) {
      const hadNav = this.#touchTriggeredNav;
      const hadChevron = this.#touchHasShownChevron;
      this.#touchState = null;
      if (this.#skipTouchEndOpacity && !hadNav) {
        this.#logChevronDispatch("sideNavChevronOpacity:touchEnd:skipReset", { reason: "skipTouchEndOpacity" });
        this.#skipTouchEndOpacity = false;
        this.#touchHasShownChevron = false;
        this.#touchTriggeredNav = false;
        this.#maxChevronLeft = 0;
        this.#maxChevronRight = 0;
        return;
      }
      this.#clearPendingChevronReset();
      if (hadNav) {
        this.#logResetNeed("touchEnd:nav");
        this.#emitChevronReset("reset:touchEndNav");
      } else if (hadChevron) {
        this.#logResetNeed("touchEnd:noNav");
        this.#scheduleChevronHide(0);
      }
      this.#touchHasShownChevron = false;
      this.#touchTriggeredNav = false;
      this.#maxChevronLeft = 0;
      this.#maxChevronRight = 0;
      this.#skipTouchEndOpacity = false;
    }
    #forceEndTouchGesture(source = "unknown") {
      this.#logResetNeed("forceEndTouchGesture", { source });
      this.#clearPendingChevronReset();
      this.#touchState = null;
      this.#touchHasShownChevron = false;
      this.#touchTriggeredNav = false;
      this.#maxChevronLeft = 0;
      this.#maxChevronRight = 0;
      this.#skipTouchEndOpacity = false;
      this.#emitChevronReset("reset:forceEndTouchGesture");
    }
    #onTouchCancel(e2) {
      const hadGesture = this.#touchHasShownChevron || this.#touchTriggeredNav;
      this.#touchState = null;
      this.#clearPendingChevronReset();
      if (hadGesture) {
        this.#logResetNeed("touchCancel");
        this.#emitChevronReset("reset:touchCancel");
      }
      this.#touchHasShownChevron = false;
      this.#touchTriggeredNav = false;
      this.#maxChevronLeft = 0;
      this.#maxChevronRight = 0;
      this.#skipTouchEndOpacity = false;
    }
    // allows one to process rects as if they were LTR and horizontal
    async #getRectMapper() {
      await this.#awaitDirection();
      if (this.scrolled) {
        const size = await this.viewSize();
        const topMargin = this.#topMargin;
        const bottomMargin = this.#bottomMargin;
        return this.#vertical ? ({
          left,
          right
        }) => ({
          left: size - right - topMargin,
          right: size - left - bottomMargin
        }) : ({
          top,
          bottom
        }) => ({
          left: top + topMargin,
          right: bottom + bottomMargin
        });
      }
      const pxSize = await this.pages() * await this.size();
      return this.#rtl ? ({
        left,
        right
      }) => ({
        left: pxSize - right,
        right: pxSize - left
      }) : this.#vertical ? ({
        top,
        bottom
      }) => ({
        left: top,
        right: bottom
      }) : (f2) => f2;
    }
    #wheelCooldown = false;
    #lastWheelDeltaX = 0;
    #lastSwipeNavAt = null;
    #lastSwipeNavDirection = null;
    // 'forward' | 'backward'
    #touchHasShownChevron = false;
    #touchTriggeredNav = false;
    #maxChevronLeft = 0;
    #maxChevronRight = 0;
    #lastChevronEmit = { left: null, right: null };
    #chevronTriggerHoldMs = 420;
    #chevronFadeMs = 180;
    #pendingChevronResetTimer = null;
    #resetLoopGuard = false;
    #logResetNeed(reason, extra = {}) {
      try {
        const line = `# EBOOK CHEVRESET NEED ${JSON.stringify({ reason, ...extra })}`;
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
        console.log(line);
      } catch (_err) {
      }
    }
    #handleChevronResetEvent = () => {
      if (this.#resetLoopGuard) return;
      this.#logResetNeed("external-resetSideNavChevrons");
      this.#emitChevronReset("reset:event");
    };
    #emitChevronReset(source = "reset:auto") {
      this.#clearPendingChevronReset();
      try {
        const line = `# EBOOK CHEVRESET ${JSON.stringify({ source })}`;
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
        console.log(line);
      } catch (_err) {
      }
      this.#lastChevronEmit = { left: null, right: null };
      this.dispatchEvent(new CustomEvent("sideNavChevronOpacity", {
        bubbles: true,
        composed: true,
        detail: {
          leftOpacity: "",
          rightOpacity: "",
          source
        }
      }));
      this.#resetLoopGuard = true;
      try {
        document.dispatchEvent(new CustomEvent("resetSideNavChevrons", { detail: { source } }));
      } finally {
        setTimeout(() => {
          this.#resetLoopGuard = false;
        }, 0);
      }
    }
    #clearPendingChevronReset() {
      if (!this.#pendingChevronResetTimer) return;
      clearTimeout(this.#pendingChevronResetTimer);
      this.#pendingChevronResetTimer = null;
    }
    #scheduleChevronHide(delayMs = this.#chevronTriggerHoldMs) {
      this.#clearPendingChevronReset();
      this.#logResetNeed("scheduleHide", { delayMs });
      this.#pendingChevronResetTimer = setTimeout(() => {
        this.#pendingChevronResetTimer = null;
        this.#emitChevronOpacity({
          leftOpacity: "",
          rightOpacity: "",
          fadeMs: this.#chevronFadeMs
        }, "chevron:autoHide");
        this.#emitChevronReset("reset:autoHide");
      }, delayMs);
    }
    async #onWheel(e2) {
      if (this.scrolled) return;
      e2.preventDefault();
      if (Math.abs(e2.deltaX) < Math.abs(e2.deltaY)) return;
      const TRIGGER_THRESHOLD = 12;
      const RESET_THRESHOLD = 3;
      const REVEAL_CHEVRON_THRESHOLD = 5;
      if (this.#wheelArmed && Math.abs(e2.deltaX) < Math.abs(this.#lastWheelDeltaX) && Math.abs(e2.deltaX) < TRIGGER_THRESHOLD) {
        this.#emitChevronOpacity({
          leftOpacity: "",
          rightOpacity: ""
        }, "wheel:momentumFalling");
        this.#lastWheelDeltaX = e2.deltaX;
        return;
      }
      if (this.#wheelArmed) {
        if (Math.abs(e2.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
          this.#updateSwipeChevron(-e2.deltaX, TRIGGER_THRESHOLD, "wheel:reveal");
        } else {
          this.#updateSwipeChevron(0, TRIGGER_THRESHOLD, "wheel:resetReveal");
        }
      }
      if (this.#wheelArmed && Math.abs(e2.deltaX) > TRIGGER_THRESHOLD) {
        this.#wheelArmed = false;
        this.#wheelCooldown = true;
        if (e2.deltaX > 0) {
          await this.prev();
        } else {
          await this.next();
        }
        this.#updateSwipeChevron(-e2.deltaX, TRIGGER_THRESHOLD, "wheel:triggered");
        setTimeout(() => {
          this.#wheelCooldown = false;
        }, 100);
      } else if (!this.#wheelArmed && !this.#wheelCooldown && Math.abs(e2.deltaX) < RESET_THRESHOLD) {
        this.#wheelArmed = true;
      }
      this.#lastWheelDeltaX = e2.deltaX;
    }
    async #scrollToRect(rect, reason) {
      if (this.scrolled) {
        const rectMapper2 = await this.#getRectMapper();
        const offset2 = rectMapper2(rect).left - this.#topMargin;
        return await this.#scrollTo(offset2, reason);
      }
      const rectMapper = await this.#getRectMapper();
      const offset = rectMapper(rect).left;
      return await this.#scrollToPage(Math.floor(offset / await this.size()) + (this.#rtl ? -1 : 1), reason);
    }
    async #scrollTo(offset, reason, smooth) {
      await this.#awaitDirection();
      const scroll = async () => {
        this.#cachedStart = null;
        const element = this.#container;
        const scrollProp = await this.scrollProp();
        const size = await this.size();
        const atStart = await this.atStart();
        const atEnd = await this.atEnd();
        if (element[scrollProp] === offset) {
          this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size];
          await this.#afterScroll(reason);
          return;
        }
        if (this.scrolled && this.#vertical) offset = -offset;
        if ((reason === "snap" || smooth) && this.hasAttribute("animated")) return animate(
          element[scrollProp],
          offset,
          300,
          easeOutQuad,
          (x2) => element[scrollProp] = x2
        ).then(async () => {
          this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size];
          await this.#afterScroll(reason);
        });
        else {
          element[scrollProp] = offset;
          this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size];
          await this.#afterScroll(reason);
        }
      };
      return new Promise((resolve) => {
        requestAnimationFrame(async () => {
          if (reason === "snap" || reason === "anchor" || reason === "selection" || reason === "navigation") {
            await scroll();
          } else {
            this.#container.classList.add("view-fade");
            await scroll();
            this.#container.classList.remove("view-faded");
            this.#container.classList.remove("view-fade");
          }
          resolve();
        });
      });
    }
    async #scrollToPage(page, reason, smooth) {
      const activeLayout = this.#getActiveEbookSectionLayout();
      if (activeLayout?.hasPendingWarmup?.()) {
        activeLayout.ensurePageBuilt?.(page, {
          reason: reason ?? "scrollToPage"
        });
      }
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        await this.#applySameDocumentPagePosition(page, {
          reason: reason ?? "scrollToPage",
          smooth: !!smooth
        });
        await this.#afterScroll(reason ?? "scrollToPage");
        return;
      }
      this.#view?.reconcileSameDocumentExpandedWidth?.();
      const size = await this.size();
      const shouldUsePositiveRTLPageOffset = this.#sameDocumentMode && !this.scrolled && !this.#vertical && this.#rtl;
      const offset = size * (shouldUsePositiveRTLPageOffset ? page : this.#rtl ? -page : page);
      const alternateRTLOffset = this.#rtl ? size * -page : offset;
      const scrollProp = await this.scrollProp();
      const beforePage = await this.page().catch(() => null);
      const beforeScrollValue = this.#container?.[scrollProp] ?? null;
      logEBookPageNumLimited("scrollToPage", {
        targetPage: page,
        reason,
        smooth: !!smooth,
        sectionIndex: this.#index ?? null,
        size,
        offset,
        positiveRTLPageOffset: shouldUsePositiveRTLPageOffset,
        rtl: this.#rtl,
        vertical: this.#vertical
      });
      await this.#scrollTo(offset, reason, smooth);
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical && this.#rtl && alternateRTLOffset !== offset) {
        this.#cachedStart = null;
        const afterPrimaryPage = await this.page().catch(() => null);
        const afterPrimaryScrollValue = this.#container?.[scrollProp] ?? null;
        const targetDidAdvance = Number.isFinite(afterPrimaryPage) && Number.isFinite(beforePage) ? afterPrimaryPage > beforePage : Number.isFinite(afterPrimaryPage) && afterPrimaryPage > 0;
        const shouldRetryWithAlternateOffset = !targetDidAdvance && afterPrimaryPage !== page && afterPrimaryScrollValue === beforeScrollValue;
        if (shouldRetryWithAlternateOffset) {
          logEBookPageNumLimited("scrollToPage:rtl-retry", {
            targetPage: page,
            reason,
            smooth: !!smooth,
            sectionIndex: this.#index ?? null,
            size,
            primaryOffset: offset,
            alternateOffset: alternateRTLOffset,
            beforePage,
            afterPrimaryPage,
            beforeScrollValue,
            afterPrimaryScrollValue
          });
          await this.#scrollTo(alternateRTLOffset, reason, smooth);
        }
      }
    }
    async scrollToAnchor(anchor, select, reasonOverride) {
      const reason = reasonOverride || (select ? "selection" : "navigation");
      await this.#scrollToAnchor(anchor, reason);
    }
    // TODO: Fix newer way and stop using this one that calculates getClientRects
    async #scrollToAnchor(anchor, reason = "anchor") {
      this.#anchor = anchor;
      try {
      } catch (_error) {
      }
      logEBookPageNumLimited("scrollToAnchor:start", {
        reason,
        sectionIndex: this.#index ?? null,
        anchorType: anchor?.nodeType ?? typeof anchor,
        containerHeight: this.#container?.clientHeight ?? null,
        containerWidth: this.#container?.clientWidth ?? null
      });
      const activeLayout = this.#getActiveEbookSectionLayout();
      const sourceDoc = activeLayout?.getSourceDocument();
      const anchorDoc = anchor?.startContainer?.getRootNode?.() ?? anchor?.ownerDocument ?? null;
      if (activeLayout && sourceDoc && anchorDoc === sourceDoc) {
        const pageIndex = activeLayout.pageIndexForAnchor(anchor);
        if (pageIndex != null) {
          await this.#scrollToPage(pageIndex, reason);
          return;
        }
      }
      const rects = uncollapse(anchor)?.getClientRects?.();
      if (rects) {
        const rect = Array.from(rects).find((r2) => r2.width > 0 && r2.height > 0) || rects[0];
        if (!rect) return;
        await this.#scrollToRect(rect, reason);
        return;
      }
      if (this.scrolled) {
        const viewSize = await this.viewSize();
        await this.#scrollTo(anchor * await this.viewSize(), reason);
        return;
      }
      const pageCount = await this.pages();
      if (!pageCount) return;
      const livePageCount = this.#getLiveChunkPageCount();
      const textPages = livePageCount != null ? livePageCount : pageCount - 2;
      const newPage = Math.max(0, Math.round(anchor * Math.max(0, textPages - 1)));
      logEBookPageNumLimited("scrollToAnchor:fraction", {
        reason,
        sectionIndex: this.#index ?? null,
        anchorFraction: anchor,
        textPages,
        targetPage: livePageCount != null ? newPage : newPage + 1,
        viewSize: await this.viewSize()
      });
      await this.#scrollToPage(livePageCount != null ? newPage : newPage + 1, reason);
    }
    async #NscrollToAnchor(anchor, reason = "anchor") {
      await this.#awaitDirection();
      return new Promise((resolve) => {
        requestAnimationFrame(async () => {
          this.#anchor = anchor;
          const anchorNode = uncollapse(anchor);
          let elNode = anchorNode;
          if (elNode && elNode.startContainer !== void 0) {
            elNode = elNode.startContainer;
          }
          if (elNode && (elNode.nodeType === Node.ELEMENT_NODE || elNode.nodeType === Node.TEXT_NODE)) {
            let el = elNode.nodeType === Node.TEXT_NODE ? elNode.parentElement : elNode;
            if (el && el.nodeType === Node.ELEMENT_NODE) {
              let left = el.offsetLeft, top = el.offsetTop;
              const width = el.offsetWidth, height = el.offsetHeight;
              let current = el;
              let doc = el.ownerDocument;
              while (current && current !== this.#container) {
                const parent = current.offsetParent;
                if (!parent) {
                  const frame = doc?.defaultView?.frameElement;
                  if (frame) {
                    left += frame.offsetLeft;
                    top += frame.offsetTop;
                    current = frame;
                    doc = current.ownerDocument;
                    continue;
                  }
                  break;
                }
                current = parent;
                if (current !== this.#container) {
                  left += current.offsetLeft;
                  top += current.offsetTop;
                }
              }
              const syntheticRect = {
                left,
                right: left + width,
                top,
                bottom: top + height,
                width,
                height
              };
              const rectMapper = await this.#getRectMapper();
              const mapped = rectMapper(syntheticRect);
              await this.#scrollToRect(syntheticRect, reason);
              resolve();
              return;
            }
          }
          if (this.scrolled) {
            await this.#scrollTo(anchor * await this.viewSize(), reason);
            resolve();
            return;
          }
          const _pages = await this.pages();
          if (!_pages) {
            resolve();
            return;
          }
          const textPages = _pages - 2;
          const newPage = Math.round(anchor * (textPages - 1));
          await this.#scrollToPage(newPage + 1, reason);
          resolve();
        });
      });
    }
    async #getVisibleRange() {
      await this.#awaitDirection();
      const activeLayout = this.#getActiveEbookSectionLayout();
      if (activeLayout) {
        const range2 = activeLayout.visibleSourceRange(await this.page());
        if (range2) {
          return range2;
        }
      }
      const visibleSentinelIDs = await this.#getSentinelVisibilities();
      const doc = this.#view.document;
      if (visibleSentinelIDs.length === 0) {
        const range2 = doc.createRange();
        range2.selectNodeContents(doc.body);
        range2.collapse(true);
        return range2;
      }
      const isValid = (node) => {
        return node && (node.nodeType === Node.TEXT_NODE || node.nodeType === Node.ELEMENT_NODE && node.tagName !== "reader-sentinel");
      };
      const visibleSentinels = doc.querySelectorAll(
        visibleSentinelIDs.map((id) => `#${CSS.escape(id)}`).join(",")
      );
      const firstSentinel = visibleSentinels[0];
      const lastSentinel = visibleSentinels[visibleSentinels.length - 1];
      const findNext = (el) => {
        let node = el?.nextSibling;
        while (node && !isValid(node)) node = node.nextSibling;
        return node;
      };
      const findPrev = (el) => {
        let node = el?.previousSibling;
        while (node && !isValid(node)) node = node.previousSibling;
        return node;
      };
      const startNode = firstSentinel ? findNext(firstSentinel) : null;
      const endNode = lastSentinel ? findPrev(lastSentinel) : null;
      const range = doc.createRange();
      if (startNode && endNode) {
        range.setStartBefore(startNode);
        range.setEndAfter(endNode);
      } else {
        range.selectNodeContents(doc.body);
        range.collapse(true);
      }
      return range;
    }
    async #dispatchSyntheticRelocate(reason = "display", originalError = null) {
      try {
        const index = this.#index;
        const detail = {
          reason,
          index,
          sectionIndex: index
        };
        let currentPage = null;
        let pageCount = null;
        try {
          [currentPage, pageCount] = await Promise.all([
            this.page(),
            this.pages()
          ]);
        } catch (_2) {
        }
        const normalizedPageCount = Number.isFinite(pageCount) && pageCount > 0 ? pageCount : null;
        const normalizedPageNumber = Number.isFinite(currentPage) && currentPage >= 0 ? currentPage + 1 : null;
        if (normalizedPageNumber != null) detail.pageNumber = normalizedPageNumber;
        if (normalizedPageCount != null) detail.pageCount = normalizedPageCount;
        if (normalizedPageCount != null) {
          detail.size = 1 / normalizedPageCount;
          detail.fraction = normalizedPageNumber != null ? Math.max(0, Math.min(1, (normalizedPageNumber - 1) / normalizedPageCount)) : 0;
        }
        try {
          const activeLayout = this.#getActiveEbookSectionLayout();
          const range = activeLayout?.visibleSourceRange?.(currentPage ?? 0) ?? null;
          if (range) detail.range = range;
        } catch (_2) {
        }
        logEBookPageNumLimited("relocate:detail", {
          reason,
          sectionIndex: index,
          scrolled: this.scrolled,
          fraction: detail.fraction ?? null,
          sizeFraction: detail.size ?? null,
          pageNumber: detail.pageNumber ?? null,
          pageCount: detail.pageCount ?? null,
          synthetic: true,
          originalError: originalError ? String(originalError) : null
        });
        this.#relocateGeneration += 1;
        this.dispatchEvent(new CustomEvent("relocate", {
          detail
        }));
        return true;
      } catch (_error) {
        return false;
      }
    }
    async #afterScroll(reason) {
      if (this.#isCacheWarmer) {
        return;
      }
      this.#cachedStart = null;
      const range = await this.#getVisibleRange();
      const activeLayout = this.#getActiveEbookSectionLayout();
      const index = this.#index;
      const detail = {
        reason,
        range,
        index,
        sectionIndex: index
      };
      let pageNumberForDetail = null;
      let pageCountForDetail = null;
      if (this.scrolled) {
        const [startOffset, totalScrollSize, pageSize] = await Promise.all([
          this.start(),
          this.viewSize(),
          this.size()
        ]);
        pageCountForDetail = Number.isFinite(totalScrollSize) && Number.isFinite(pageSize) && pageSize > 0 ? Math.max(1, Math.round(totalScrollSize / pageSize)) : null;
        detail.fraction = totalScrollSize ? startOffset / totalScrollSize : null;
        if (pageCountForDetail != null) {
          const frac = detail.fraction ?? 0;
          pageNumberForDetail = Math.max(1, Math.min(pageCountForDetail, Math.floor(frac * pageCountForDetail) + 1));
        }
      } else if (await this.pages() > 0) {
        const computePaginatedDetail = async () => {
          const [page, pages, pageSize, startOffset] = await Promise.all([
            this.page(),
            this.pages(),
            this.size(),
            this.start()
          ]);
          const livePageCount = this.#getLiveChunkPageCount();
          const adjustForSentinels = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED && livePageCount == null && this.#hasSentinels && !this.scrolled && !this.#vertical && pages > 2;
          const textPages = adjustForSentinels ? Math.max(1, pages - 2) : pages;
          const normalizedOffset = adjustForSentinels ? Math.max(0, startOffset - pageSize) : startOffset;
          const textPageNumber = textPages > 0 ? Math.min(textPages, Math.floor(normalizedOffset / pageSize) + 1) : 1;
          const fractionUsed = textPages > 0 ? normalizedOffset / (pageSize * textPages) : null;
          return {
            rawPage: page,
            rawPages: pages,
            pageSize,
            startOffset,
            normalizedOffset,
            textPages,
            textPageNumber: adjustForSentinels ? textPageNumber : Math.max(1, page + 1),
            fractionUsed,
            sizeFraction: textPages > 0 ? 1 / textPages : null,
            adjustForSentinels
          };
        };
        let pagedDetail = await computePaginatedDetail();
        this.#header.style.visibility = pagedDetail.rawPage > 1 ? "visible" : "hidden";
        if (!this.scrolled && pagedDetail.textPages <= 1) {
          if (this.#view) {
            this.#view.cachedViewSize = null;
          }
          await new Promise((resolve) => requestAnimationFrame(resolve));
          const retryDetail = await computePaginatedDetail();
          if (retryDetail.textPages > pagedDetail.textPages) {
            pagedDetail = retryDetail;
            logEBookPageNumLimited("relocate:detail:retry", {
              reason,
              sectionIndex: index,
              rawPage: pagedDetail.rawPage,
              rawPages: pagedDetail.rawPages,
              pageSize: pagedDetail.pageSize,
              startOffset: pagedDetail.startOffset,
              pageCountForDetail: pagedDetail.textPages,
              pageNumberForDetail: pagedDetail.textPageNumber,
              fractionUsed: pagedDetail.fractionUsed,
              sentinelAdjusted: pagedDetail.adjustForSentinels
            });
          }
        }
        pageCountForDetail = pagedDetail.textPages;
        pageNumberForDetail = pagedDetail.textPageNumber;
        detail.fraction = pagedDetail.fractionUsed;
        detail.size = pagedDetail.sizeFraction;
        logEBookPageNumLimited("relocate:detail:calc", {
          reason,
          sectionIndex: index,
          rawPage: pagedDetail.rawPage,
          rawPages: pagedDetail.rawPages,
          pageSize: pagedDetail.pageSize,
          startOffset: pagedDetail.startOffset,
          normalizedOffset: pagedDetail.normalizedOffset,
          pageCountForDetail,
          pageNumberForDetail,
          fractionUsed: detail.fraction,
          sentinelAdjusted: pagedDetail.adjustForSentinels
        });
      }
      if (pageNumberForDetail != null) detail.pageNumber = pageNumberForDetail;
      if (pageCountForDetail != null) detail.pageCount = pageCountForDetail;
      if (activeLayout) {
        activeLayout.setCurrentSourceAnchor?.(range);
        if (reason !== "selection" && reason !== "navigation" && reason !== "anchor") {
          this.#anchor = range;
        } else {
          this.#justAnchored = true;
        }
      } else if (reason !== "selection" && reason !== "navigation" && reason !== "anchor") {
        this.#anchor = range;
      } else {
        this.#justAnchored = true;
      }
      const detailForLog = {
        reason,
        sectionIndex: index,
        scrolled: this.scrolled,
        fraction: detail.fraction ?? null,
        sizeFraction: detail.size ?? null,
        pageNumber: pageNumberForDetail,
        pageCount: pageCountForDetail
      };
      logEBookPageNumLimited("relocate:detail", detailForLog);
      this.#relocateGeneration += 1;
      this.dispatchEvent(new CustomEvent("relocate", {
        detail
      }));
      try {
        const [pageNumberRaw, pageCountRaw, startOffset, pageSize, viewSize] = await Promise.all([
          this.page(),
          this.pages(),
          this.start(),
          this.size(),
          this.viewSize()
        ]);
        const livePageCount = this.#getLiveChunkPageCount();
        const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED && livePageCount == null && !this.scrolled && !this.#vertical && pageCountRaw > 2;
        const pageCountText = sentinelAdjusted ? Math.max(1, pageCountRaw - 2) : pageCountRaw;
        const pageNumberText = sentinelAdjusted ? Math.max(1, Math.min(pageCountText, pageNumberRaw)) : Math.max(1, pageNumberRaw);
        logEBookPageNumLimited("afterScroll:metrics", {
          ...detailForLog,
          pageNumber: pageNumberText,
          pageCount: pageCountText,
          pageNumberRaw,
          pageCountRaw,
          sentinelAdjusted,
          startOffset,
          pageSize,
          viewSize
        });
      } catch (_error) {
        logEBookPageNumLimited("afterScroll:metrics-error", {
          ...detailForLog,
          error: String(_error)
        });
      }
      if (await this.isAtSectionStart()) {
        if (this.#touchTriggeredNav) {
          this.#logChevronDispatch("sideNavChevronOpacity:startOfSection:skip", {
            reason: "navTriggered",
            bookDir: this.bookDir ?? null,
            rtl: this.#rtl
          });
        } else {
          this.#skipTouchEndOpacity = true;
          this.#emitChevronOpacity({
            leftOpacity: this.bookDir === "rtl" ? 0.999 : 0,
            rightOpacity: this.bookDir === "rtl" ? 0 : 0.999
          }, "afterScroll:startOfSection");
        }
      }
    }
    #updateSwipeChevron(dx, minSwipe, source = "swipe") {
      let leftOpacity = 0, rightOpacity = 0;
      if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
      else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
      if (leftOpacity > 0 || rightOpacity > 0) {
        this.#touchHasShownChevron = true;
      }
      this.#maxChevronLeft = Math.max(this.#maxChevronLeft, Number(leftOpacity) || 0);
      this.#maxChevronRight = Math.max(this.#maxChevronRight, Number(rightOpacity) || 0);
      this.#emitChevronOpacity({
        leftOpacity,
        rightOpacity,
        fadeMs: this.#chevronFadeMs
      }, source);
    }
    async #display(promise) {
      this.#setLoading(true, "display");
      const {
        index,
        src,
        sectionLocation,
        anchor,
        onLoad,
        select,
        reason
      } = await promise;
      this.#index = index;
      logBug?.("paginator:display:index", {
        index,
        src: src ?? null,
        sectionLocation: sectionLocation ?? null,
        reason: reason ?? null,
        anchor: summarizeAnchor(anchor)
      });
      if (src) {
        const afterLoad = async (doc) => {
          if (this.#isCacheWarmer) {
            await onLoad?.({
              location: sectionLocation ?? src
            });
          } else {
            hideDocumentContentForPreBake(doc);
            if (doc.head) {
              const existingStyles = this.#styleMap.get(doc);
              if (existingStyles) {
                for (const styleNode of existingStyles) styleNode?.remove?.();
              }
              const $styleBefore = doc.createElement("style");
              doc.head.prepend($styleBefore);
              const $style = doc.createElement("style");
              doc.head.append($style);
              this.#styleMap.set(doc, [$styleBefore, $style]);
              if (MANABI_TRACKING_SIZE_BAKE_ENABLED) ensureTrackingSizeBakeStyles(doc);
            }
            await onLoad?.({
              doc,
              location: sectionLocation ?? src,
              index
            });
            await this.#performTrackingSectionGeometryBake({
              reason: "initial-load",
              restoreLocation: false
            });
          }
        };
        if (this.#isCacheWarmer) {
          await fetch(src).then((r2) => r2.text());
          await afterLoad();
        } else {
          this.#skipTouchEndOpacity = true;
          const view = this.#createView();
          const beforeRender = this.#beforeRender.bind(this);
          this.#cachedSizes = null;
          this.#cachedStart = null;
          this.#scrolledToAnchorOnLoad = false;
          await view.load(src, afterLoad, beforeRender, index, sectionLocation);
          this.#view = view;
          document.dispatchEvent(new CustomEvent("resetSideNavChevrons"));
        }
      }
      const layoutSync = await this.#syncEbookSectionLayout({
        reason: reason ?? "display",
        anchor
      });
      const relocateGenerationBeforeScroll = this.#relocateGeneration;
      let scrollToAnchorError = null;
      try {
        await this.scrollToAnchor(
          layoutSync?.restoreAnchor ?? this.#resolveAnchorAgainstActiveLayout(anchor) ?? 0,
          select,
          reason
        );
      } catch (error) {
        scrollToAnchorError = error;
      }
      const shouldDispatchSyntheticRelocate = !this.#isCacheWarmer && this.#relocateGeneration === relocateGenerationBeforeScroll;
      const didDispatchSyntheticRelocate = shouldDispatchSyntheticRelocate ? await this.#dispatchSyntheticRelocate(reason ?? "display", scrollToAnchorError) : false;
      logBug?.("paginator:display:post-scroll", {
        index,
        reason: reason ?? null,
        relocateGenerationBeforeScroll,
        relocateGenerationAfterScroll: this.#relocateGeneration,
        shouldDispatchSyntheticRelocate,
        didDispatchSyntheticRelocate,
        scrollToAnchorError: scrollToAnchorError ? String(scrollToAnchorError) : null
      });
      if (scrollToAnchorError && !didDispatchSyntheticRelocate) {
        throw scrollToAnchorError;
      }
      let pageNumber = null;
      let pageCount = null;
      try {
        [pageNumber, pageCount] = await Promise.all([this.page(), this.pages()]);
        logEBookPageNumLimited("display:initial", {
          index,
          reason,
          pageNumber,
          pageCount
        });
      } catch (_error) {
        logEBookPageNumLimited("display:initial-error", {
          index,
          reason,
          error: String(_error)
        });
      }
      try {
        await Promise.all([
          this.start(),
          this.size(),
          this.viewSize()
        ]);
      } catch (_error) {
      }
      this.#scrolledToAnchorOnLoad = true;
      this.#setLoading(false, "display-complete");
      this.#forceEndTouchGesture("didDisplay");
      this.dispatchEvent(new CustomEvent("didDisplay", {}));
      return true;
    }
    #canGoToIndex(index) {
      return index >= 0 && index <= this.sections.length - 1;
    }
    async #goTo({
      index,
      anchor,
      select,
      reason
    }) {
      const navigationReason = reason ?? (select ? "selection" : "navigation");
      const willLoadNewIndex = index !== this.#index;
      logBug?.("paginator:goTo:start", {
        index,
        currentIndex: this.#index,
        willLoadNewIndex,
        reason: navigationReason,
        anchor: summarizeAnchor(anchor),
        hasSelect: !!select
      });
      this.dispatchEvent(new CustomEvent("goTo", {
        willLoadNewIndex
      }));
      if (!willLoadNewIndex) {
        await this.#display({
          index,
          anchor,
          select,
          reason: navigationReason
        });
      } else {
        this.style.display = "none";
        const oldIndex = this.#index;
        this.#vertical = this.#verticalRTL = this.#rtl = null;
        this.#directionReady = new Promise((r2) => this.#directionReadyResolve = r2);
        const onLoad = async (detail) => {
          this.sections[oldIndex]?.unload?.();
          if (!this.#isCacheWarmer) {
            this.setStyles(this.#styles);
          }
          this.dispatchEvent(new CustomEvent("load", {
            detail
          }));
        };
        let loadPromise;
        if (this.#prefetchCache.has(index)) {
          loadPromise = this.#prefetchCache.get(index);
        } else {
          loadPromise = this.sections[index].load();
          this.#prefetchCache.set(index, loadPromise);
        }
        await this.#display(Promise.resolve(loadPromise).then((src) => ({
          index,
          src,
          sectionLocation: this.sections[index]?.id ?? null,
          anchor,
          onLoad,
          select,
          reason: navigationReason
        })).catch((error) => {
          console.error(error);
          console.warn(new Error(`Failed to load section ${index}`));
          return {};
        }));
        clearTimeout(this.#prefetchTimer);
        this.#prefetchTimer = setTimeout(() => {
          if (this.#index !== index) return;
          const wanted = [index - 1, index + 1];
          const keep = new Set(wanted.filter((i2) => this.#prefetchCache.has(i2)));
          this.#prefetchCache = new Map(
            [...this.#prefetchCache].filter(([i2]) => keep.has(i2))
          );
          wanted.forEach((i2) => {
            if (i2 >= 0 && i2 < this.sections.length && this.sections[i2].linear !== "no" && !this.#prefetchCache.has(i2)) {
              this.#schedulePrefetchLoad(i2);
            }
          });
        }, 500);
      }
    }
    async goTo(target) {
      if (this.#locked) {
        const now = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
        const elapsed = now - this.#lockTimestamp;
        if (elapsed > 400) {
          this.#locked = false;
          logBug?.("paginator:watchdog-unlock-goTo", { elapsedMs: elapsed });
        } else {
          logBug?.("paginator:locked-goTo", { elapsedMs: elapsed });
          return false;
        }
      }
      const resolved = await target;
      if (this.#canGoToIndex(resolved.index)) return await this.#goTo(resolved);
      return false;
    }
    async #scrollPrev(distance) {
      if (!this.#view) return true;
      const livePageCount = this.#getLiveChunkPageCount();
      if (!this.scrolled && livePageCount != null && livePageCount <= 1 && this.#adjacentIndex(-1) != null) {
        return true;
      }
      if (this.scrolled) {
        const style = getComputedStyle(this.#container);
        const lineAdvance = this.#vertical ? parseFloat(style.fontSize) || 20 : parseFloat(style.lineHeight) || 20;
        const scrollDistance = distance ?? this.size - lineAdvance;
        if (await this.start() > 0) {
          return await this.#scrollTo(Math.max(0, this.start - scrollDistance), null, true);
        }
        return true;
      }
      if (await this.atStart()) return;
      const page = await this.page() - 1;
      return await this.#scrollToPage(page, "page", true).then(() => page <= 0);
    }
    async #scrollNext(distance) {
      if (!this.#view) return true;
      const livePageCount = this.#getLiveChunkPageCount();
      if (!this.scrolled && livePageCount != null && livePageCount <= 1 && this.#adjacentIndex(1) != null) {
        return true;
      }
      if (this.scrolled) {
        const style = getComputedStyle(this.#container);
        const lineAdvance = this.#vertical ? parseFloat(style.fontSize) || 20 : parseFloat(style.lineHeight) || 20;
        const scrollDistance = distance ?? this.size - lineAdvance;
        if (await this.viewSize() - await this.end() > 2) {
          return await this.#scrollTo(Math.min(await this.viewSize(), await this.start() + scrollDistance), null, true);
        }
        return true;
      }
      if (await this.atEnd()) return;
      const page = await this.page() + 1;
      const pages = await this.pages();
      return await this.#scrollToPage(page, "page", true).then(() => page >= pages - 1);
    }
    async atStart() {
      const livePageCount = this.#getLiveChunkPageCount();
      const edgePage = livePageCount != null ? 0 : 1;
      return this.#adjacentIndex(-1) == null && await this.page() <= edgePage;
    }
    async atEnd() {
      const livePageCount = this.#getLiveChunkPageCount();
      const edgeOffset = livePageCount != null ? 1 : 2;
      return this.#adjacentIndex(1) == null && await this.page() >= await this.pages() - edgeOffset;
    }
    #adjacentIndex(dir) {
      for (let index = this.#index + dir; this.#canGoToIndex(index); index += dir)
        if (this.sections[index]?.linear !== "no") return index;
    }
    async #turnPage(dir, distance) {
      if (this.#locked) {
        const now = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
        const elapsed = now - this.#lockTimestamp;
        if (elapsed > 400) {
          this.#locked = false;
          logBug?.("paginator:watchdog-unlock-turnPage", { dir, elapsedMs: elapsed });
        } else {
          logBug?.("paginator:locked-turnPage", { dir, elapsedMs: elapsed });
          return false;
        }
      }
      this.#locked = true;
      this.#lockTimestamp = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
      const beforeIndex = this.#index;
      const beforePage = await this.page().catch(() => null);
      const beforePages = await this.pages().catch(() => null);
      const adjacentIndex = this.#adjacentIndex(dir);
      logBug?.("paginator:turnPage:start", {
        dir,
        distance,
        currentIndex: beforeIndex,
        adjacentIndex,
        beforePage,
        beforePages
      });
      try {
        const prev = dir === -1;
        const shouldGo = await (prev ? await this.#scrollPrev(distance) : await this.#scrollNext(distance));
        logBug?.("paginator:turnPage:shouldGo", {
          dir,
          shouldGo,
          currentIndex: this.#index,
          adjacentIndex
        });
        let didNavigate = false;
        if (shouldGo) {
          logBug?.("paginator:turnPage:cross-section", {
            dir,
            currentIndex: this.#index,
            targetIndex: adjacentIndex
          });
          didNavigate = await this.#goTo({
            index: adjacentIndex,
            anchor: prev ? () => 1 : () => 0,
            reason: "page"
          });
        }
        if (shouldGo || !this.hasAttribute("animated")) {
          await wait(100);
        }
        const afterPage = await this.page().catch(() => null);
        const afterPages = await this.pages().catch(() => null);
        const resolved = didNavigate || this.#index !== beforeIndex || beforePage !== afterPage || beforePages !== afterPages;
        return resolved;
      } finally {
        this.#locked = false;
        const afterPage = await this.page().catch(() => null);
        const afterPages = await this.pages().catch(() => null);
        logBug?.("paginator:turnPage:end", {
          dir,
          currentIndex: this.#index,
          afterPage,
          afterPages
        });
      }
    }
    async prev(distance) {
      return await this.#turnPage(-1, distance);
    }
    async next(distance) {
      return await this.#turnPage(1, distance);
    }
    hostTurn(direction) {
      const dir = direction === "backward" ? -1 : 1;
      if (this.#sameDocumentMode && !this.scrolled && !this.#vertical) {
        const currentPage = this.#getSameDocumentClampedPageIndexSync();
        const pageCount = this.#getSameDocumentResolvedPageCountSync();
        const targetPage = currentPage + dir;
        setSameDocumentHostTurnDiagnostics({
          phase: "host-turn-begin",
          direction,
          currentPageIndex: currentPage,
          pageCount,
          targetPageIndex: targetPage
        });
        if (targetPage >= 0 && targetPage < pageCount) {
          this.#applySameDocumentPagePositionSync(targetPage, {
            reason: "host-turn",
            smooth: true
          });
          void Promise.resolve(this.#afterScroll("host-turn")).catch(() => {
          });
          setSameDocumentHostTurnDiagnostics({
            phase: "host-turn-complete",
            direction,
            currentPageIndex: currentPage,
            pageCount,
            targetPageIndex: targetPage,
            result: "page"
          });
          return true;
        }
        const adjacentIndex = this.#adjacentIndex(dir);
        if (adjacentIndex != null) {
          setSameDocumentHostTurnDiagnostics({
            phase: "host-turn-section",
            direction,
            currentPageIndex: currentPage,
            pageCount,
            adjacentSectionIndex: adjacentIndex,
            result: "section"
          });
          return this.#goTo({
            index: adjacentIndex,
            anchor: dir < 0 ? () => 1 : () => 0,
            reason: "page"
          });
        }
        setSameDocumentHostTurnDiagnostics({
          phase: "host-turn-unavailable",
          direction,
          currentPageIndex: currentPage,
          pageCount,
          targetPageIndex: targetPage,
          result: "unavailable"
        });
        return false;
      }
      return dir < 0 ? this.prev() : this.next();
    }
    async prevSection() {
      const targetIndex = this.#adjacentIndex(-1);
      logBug?.("paginator:prevSection", {
        currentIndex: this.#index,
        targetIndex
      });
      return await this.goTo({
        index: targetIndex,
        reason: "page"
      });
    }
    async nextSection() {
      const targetIndex = this.#adjacentIndex(1);
      logBug?.("paginator:nextSection", {
        currentIndex: this.#index,
        targetIndex
      });
      return await this.goTo({
        index: targetIndex,
        reason: "page"
      });
    }
    async firstSection() {
      const index = this.sections.findIndex((section) => section.linear !== "no");
      return await this.goTo({
        index
      });
    }
    async lastSection() {
      const index = this.sections.findLastIndex((section) => section.linear !== "no");
      return await this.goTo({
        index
      });
    }
    getContents() {
      if (this.#view) return [{
        index: this.#index,
        overlayer: this.#view.overlayer,
        doc: this.#view.document
      }];
      return [];
    }
    setStyles(styles) {
      this.#styles = styles;
      const $$styles = this.#styleMap.get(this.#view?.document);
      if (!$$styles) return;
      const [$beforeStyle, $style] = $$styles;
      if (Array.isArray(styles)) {
        const [beforeStyle, style] = styles;
        $beforeStyle.textContent = beforeStyle;
        $style.textContent = style;
      } else $style.textContent = styles;
      this.requestTrackingSectionSizeBake({ reason: "styles-applied" });
    }
    destroy() {
      this.#disconnectElementVisibilityObserver();
      this.#resizeObserver.unobserve(this);
      this.#resetTrackingSectionSizeState();
      this.#bindEbookLayoutEvents(null);
      this.#ebookSectionLayout.destroy();
      this.#view.destroy();
      this.#view = null;
      this.#teardownSameDocumentViewport();
      this.sections[this.#index]?.unload?.();
    }
    // Public navigation edge detection methods
    async canTurnPrev() {
      if (!this.#view) return false;
      if (this.scrolled) {
        return this.start > 0;
      }
      const livePageCount = this.#getLiveChunkPageCount();
      const edgePage = livePageCount != null ? 0 : 1;
      if (await this.page() <= edgePage && this.#adjacentIndex(-1) == null) return false;
      return true;
    }
    async canTurnNext() {
      if (!this.#view) return false;
      if (this.scrolled) {
        return this.viewSize - this.end > 2;
      }
      const livePageCount = this.#getLiveChunkPageCount();
      const edgeOffset = livePageCount != null ? 1 : 2;
      if (await this.page() >= await this.pages() - edgeOffset && this.#adjacentIndex(1) == null) return false;
      return true;
    }
    debugVisualDiagnostics() {
      const roundRect = (rect) => rect ? {
        top: Math.round(rect.top),
        left: Math.round(rect.left),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      } : null;
      const styleValue = (node, key) => {
        try {
          if (!node) return null;
          return getComputedStyle(node)?.[key] ?? null;
        } catch (_error) {
          return null;
        }
      };
      const infoFor = (node) => ({
        tag: node?.tagName?.toLowerCase?.() ?? null,
        id: node?.id ?? null,
        className: typeof node?.className === "string" ? node.className : null
      });
      const doc = this.#view?.document ?? null;
      const stage = document.getElementById("reader-stage");
      const viewport = document.getElementById("manabi-same-document-viewport");
      const viewportContainer = document.getElementById("manabi-same-document-container");
      const contentRoot = this.#view?.document ? this.#view.document.getElementById?.("reader-content") || this.#view.document.body || null : null;
      const liveRoot = contentRoot?.querySelector?.(".manabi-page-root") || null;
      const livePages = liveRoot ? Array.from(liveRoot.querySelectorAll(":scope > .manabi-page")) : [];
      const firstLivePage = livePages[0] || null;
      const secondLivePage = livePages[1] || null;
      const lastLivePage = livePages[livePages.length - 1] || null;
      const sumLivePageWidths = livePages.reduce((sum, node) => {
        try {
          return sum + (node?.getBoundingClientRect?.().width || 0);
        } catch (_error) {
          return sum;
        }
      }, 0);
      const elementCenter = (node) => {
        if (!node?.getBoundingClientRect) return null;
        try {
          const rect = node.getBoundingClientRect();
          const x2 = Math.round(rect.left + rect.width / 2);
          const y2 = Math.round(rect.top + rect.height / 2);
          return document.elementFromPoint(x2, y2);
        } catch (_error) {
          return null;
        }
      };
      return {
        sameDocumentMode: this.#sameDocumentMode,
        hostDisplay: styleValue(this, "display"),
        hostVisibility: styleValue(this, "visibility"),
        hostOpacity: styleValue(this, "opacity"),
        hostRect: roundRect(this.getBoundingClientRect?.()),
        topDisplay: styleValue(this.#top, "display"),
        topVisibility: styleValue(this.#top, "visibility"),
        topOpacity: styleValue(this.#top, "opacity"),
        topRect: roundRect(this.#top?.getBoundingClientRect?.()),
        containerDisplay: styleValue(this.#container, "display"),
        containerVisibility: styleValue(this.#container, "visibility"),
        containerOpacity: styleValue(this.#container, "opacity"),
        containerRect: roundRect(this.#container?.getBoundingClientRect?.()),
        containerClientWidth: this.#container?.clientWidth ?? null,
        containerClientHeight: this.#container?.clientHeight ?? null,
        containerScrollWidth: this.#container?.scrollWidth ?? null,
        containerScrollHeight: this.#container?.scrollHeight ?? null,
        sameDocumentViewportExists: !!viewport,
        sameDocumentViewportRect: roundRect(viewport?.getBoundingClientRect?.()),
        sameDocumentViewportDisplay: styleValue(viewport, "display"),
        sameDocumentViewportVisibility: styleValue(viewport, "visibility"),
        sameDocumentViewportOpacity: styleValue(viewport, "opacity"),
        sameDocumentViewportZIndex: styleValue(viewport, "zIndex"),
        sameDocumentViewportPointerEvents: styleValue(viewport, "pointerEvents"),
        sameDocumentViewportParentTag: viewport?.parentElement?.tagName?.toLowerCase?.() ?? null,
        sameDocumentViewportParentId: viewport?.parentElement?.id ?? null,
        sameDocumentContainerExists: !!viewportContainer,
        sameDocumentContainerRect: roundRect(viewportContainer?.getBoundingClientRect?.()),
        sameDocumentContainerDisplay: styleValue(viewportContainer, "display"),
        sameDocumentContainerVisibility: styleValue(viewportContainer, "visibility"),
        sameDocumentContainerOpacity: styleValue(viewportContainer, "opacity"),
        mountRect: roundRect(this.#view?.element?.getBoundingClientRect?.()),
        mountDisplay: styleValue(this.#view?.element, "display"),
        mountVisibility: styleValue(this.#view?.element, "visibility"),
        mountOpacity: styleValue(this.#view?.element, "opacity"),
        mountBackgroundColor: styleValue(this.#view?.element, "backgroundColor"),
        stageRect: roundRect(stage?.getBoundingClientRect?.()),
        stageDisplay: styleValue(stage, "display"),
        stageVisibility: styleValue(stage, "visibility"),
        stageOpacity: styleValue(stage, "opacity"),
        stageZIndex: styleValue(stage, "zIndex"),
        stageBackgroundColor: styleValue(stage, "backgroundColor"),
        shellCenterElementTag: infoFor(elementCenter(stage || viewport || this.#container)).tag,
        shellCenterElementId: infoFor(elementCenter(stage || viewport || this.#container)).id,
        shellCenterElementClassName: infoFor(elementCenter(stage || viewport || this.#container)).className,
        documentURL: doc?.URL ?? null,
        documentReadyState: doc?.readyState ?? null,
        documentBodyTextLength: doc?.body?.innerText?.trim?.().length ?? null,
        documentBodyColor: styleValue(doc?.body, "color"),
        documentBodyBackgroundColor: styleValue(doc?.body, "backgroundColor"),
        contentRootRect: roundRect(contentRoot?.getBoundingClientRect?.()),
        contentRootTextLength: contentRoot?.innerText?.trim?.().length ?? null,
        contentRootDisplay: styleValue(contentRoot, "display"),
        contentRootVisibility: styleValue(contentRoot, "visibility"),
        contentRootOpacity: styleValue(contentRoot, "opacity"),
        liveRootClientWidth: liveRoot?.clientWidth ?? null,
        liveRootClientHeight: liveRoot?.clientHeight ?? null,
        liveRootScrollWidth: liveRoot?.scrollWidth ?? null,
        liveRootScrollHeight: liveRoot?.scrollHeight ?? null,
        liveRootTransform: styleValue(liveRoot, "transform"),
        liveRootTransition: styleValue(liveRoot, "transition"),
        liveRootDatasetCurrentPageIndex: liveRoot?.dataset?.manabiCurrentPageIndex ?? null,
        sameDocumentHostTurnPhase: globalThis.manabiSameDocumentHostTurnDiagnostics?.phase ?? null,
        sameDocumentHostTurnDirection: globalThis.manabiSameDocumentHostTurnDiagnostics?.direction ?? null,
        sameDocumentHostTurnCurrentPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.currentPageIndex ?? null,
        sameDocumentHostTurnTargetPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.targetPageIndex ?? null,
        sameDocumentHostTurnPageCount: globalThis.manabiSameDocumentHostTurnDiagnostics?.pageCount ?? null,
        sameDocumentHostTurnTargetOffset: globalThis.manabiSameDocumentHostTurnDiagnostics?.targetOffset ?? null,
        sameDocumentHostTurnAppliedTransform: globalThis.manabiSameDocumentHostTurnDiagnostics?.appliedTransform ?? null,
        sameDocumentHostTurnDatasetCurrentPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.datasetCurrentPageIndex ?? null,
        sameDocumentHostTurnResult: globalThis.manabiSameDocumentHostTurnDiagnostics?.result ?? null,
        liveRootComputedWidth: styleValue(liveRoot, "width"),
        liveRootComputedMinWidth: styleValue(liveRoot, "minWidth"),
        liveRootComputedMaxWidth: styleValue(liveRoot, "maxWidth"),
        liveRootComputedInlineSize: styleValue(liveRoot, "inlineSize"),
        liveRootComputedMinInlineSize: styleValue(liveRoot, "minInlineSize"),
        liveRootComputedMaxInlineSize: styleValue(liveRoot, "maxInlineSize"),
        liveRootComputedOverflowX: styleValue(liveRoot, "overflowX"),
        livePageCountFromDOM: livePages.length,
        livePageWidthSum: Math.round(sumLivePageWidths),
        firstLivePageRect: roundRect(firstLivePage?.getBoundingClientRect?.()),
        secondLivePageRect: roundRect(secondLivePage?.getBoundingClientRect?.()),
        lastLivePageRect: roundRect(lastLivePage?.getBoundingClientRect?.()),
        firstLivePageOffsetLeft: firstLivePage?.offsetLeft ?? null,
        secondLivePageOffsetLeft: secondLivePage?.offsetLeft ?? null,
        lastLivePageOffsetLeft: lastLivePage?.offsetLeft ?? null,
        firstLivePageComputedWidth: styleValue(firstLivePage, "width"),
        lastLivePageComputedWidth: styleValue(lastLivePage, "width")
      };
    }
    // Public helpers for adjacent sections
    getHasPrevSection() {
      return this.#adjacentIndex(-1) != null;
    }
    getHasNextSection() {
      return this.#adjacentIndex(1) != null;
    }
    // Public: At first page of current section
    async isAtSectionStart() {
      const livePageCount = this.#getLiveChunkPageCount();
      return await this.page() <= (livePageCount != null ? 0 : 1);
    }
    // Public: At last page of current section
    async isAtSectionEnd() {
      const livePageCount = this.#getLiveChunkPageCount();
      const edgeOffset = livePageCount != null ? 1 : 2;
      return await this.page() >= await this.pages() - edgeOffset;
    }
  };
  customElements.define("foliate-paginator", Paginator);

  // progress.js
  var assignIDs = (toc) => {
    let id = 0;
    const assignID = (item) => {
      item.id = id++;
      if (item.subitems) for (const subitem of item.subitems) assignID(subitem);
    };
    for (const item of toc) assignID(item);
    return toc;
  };
  var flatten = (items) => items.map((item) => item.subitems?.length ? [item, flatten(item.subitems)].flat() : item).flat();
  var TOCProgress = class {
    constructor({ toc, ids, splitHref, getFragment }) {
      assignIDs(toc);
      const items = flatten(toc);
      const grouped = /* @__PURE__ */ new Map();
      for (const [i2, item] of items.entries()) {
        const [id, fragment] = splitHref(item?.href) ?? [];
        const value = { fragment, item };
        if (grouped.has(id)) grouped.get(id).items.push(value);
        else grouped.set(id, { prev: items[i2 - 1], items: [value] });
      }
      const map = /* @__PURE__ */ new Map();
      for (const [i2, id] of ids.entries()) {
        if (grouped.has(id)) map.set(id, grouped.get(id));
        else map.set(id, map.get(ids[i2 - 1]));
      }
      this.ids = ids;
      this.map = map;
      this.getFragment = getFragment;
    }
    getProgress(index, range) {
      const id = this.ids[index];
      const obj = this.map.get(id);
      if (!obj) return null;
      const { prev, items } = obj;
      if (!items) return prev;
      if (!range || items.length === 1 && !items[0].fragment) return items[0].item;
      const doc = range.startContainer.getRootNode();
      for (const [i2, { fragment }] of items.entries()) {
        const el = this.getFragment(doc, fragment);
        if (!el) continue;
        if (range.comparePoint(el, 0) > 0)
          return items[i2 - 1]?.item ?? prev;
      }
      return items[items.length - 1].item;
    }
  };
  var SectionProgress = class {
    constructor(sections, sizePerLoc, sizePerTimeUnit) {
      this.sizes = sections.map((s2) => s2.linear === "no" ? 0 : s2.size);
      this.sizePerLoc = sizePerLoc;
      this.sizePerTimeUnit = sizePerTimeUnit;
      this.sizeTotal = this.sizes.reduce((a2, b2) => a2 + b2, 0);
    }
    // get progress given index of and fractions within a section
    getProgress(index, fractionInSection, pageFraction = 0) {
      const { sizes, sizePerLoc, sizePerTimeUnit, sizeTotal } = this;
      const sizeInSection = sizes[index] ?? 0;
      const sizeBefore = sizes.slice(0, index).reduce((a2, b2) => a2 + b2, 0);
      const size = sizeBefore + fractionInSection * sizeInSection;
      const nextSize = size + pageFraction * sizeInSection;
      const remainingTotal = sizeTotal - size;
      const remainingSection = (1 - fractionInSection) * sizeInSection;
      return {
        fraction: nextSize / sizeTotal,
        section: {
          current: index,
          total: sizes.length
        },
        location: {
          current: Math.floor(size / sizePerLoc),
          next: Math.floor(nextSize / sizePerLoc),
          total: Math.ceil(sizeTotal / sizePerLoc)
        },
        time: {
          section: remainingSection / sizePerTimeUnit,
          total: remainingTotal / sizePerTimeUnit
        }
      };
    }
    // the inverse of `getProgress`
    // get index of and fraction in section based on total fraction
    getSection(fraction) {
      if (fraction === 0) return [0, 0];
      if (fraction === 1) return [this.sizes.length - 1, 1];
      const { sizes, sizeTotal } = this;
      const target = fraction * sizeTotal;
      let index = -1;
      let fractionInSection = 0;
      let sum = 0;
      for (const [i2, size] of sizes.entries()) {
        const newSum = sum + size;
        if (newSum > target) {
          index = i2;
          fractionInSection = (target - sum) / size;
          break;
        }
        sum = newSum;
      }
      return [index, fractionInSection];
    }
  };

  // view.js
  var SEARCH_PREFIX = "foliate-search:";
  var logBug2 = (event, detail = {}) => {
    try {
      return globalThis.logBug?.(event, detail);
    } catch (_error) {
      return void 0;
    }
  };
  var logNavHide = globalThis.logNavHide || ((event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
      try {
        console.log(line);
      } catch (_2) {
      }
    }
  });
  var postNavigationChromeVisibility = (shouldHide, { source, direction } = {}) => {
    const appliedHide = !!shouldHide;
    logNavHide("view:post-nav-visibility", {
      requested: !!shouldHide,
      applied: appliedHide,
      source: source ?? null,
      direction: direction ?? null
    });
    try {
      window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
        hideNavigationDueToScroll: appliedHide,
        source: source ?? null,
        direction: direction ?? null
      });
    } catch (error) {
      console.error("Failed to notify navigation chrome visibility", error);
    }
  };
  var History = class extends EventTarget {
    #arr = [];
    #index = -1;
    pushState(x2) {
      const last = this.#arr[this.#index];
      if (last === x2 || last?.fraction && last.fraction === x2.fraction) return;
      this.#arr[++this.#index] = x2;
      this.#arr.length = this.#index + 1;
      this.dispatchEvent(new Event("index-change"));
    }
    replaceState(x2) {
      const index = this.#index;
      this.#arr[index] = x2;
    }
    back() {
      const index = this.#index;
      if (index <= 0) return;
      const detail = { state: this.#arr[index - 1] };
      this.#index = index - 1;
      this.dispatchEvent(new CustomEvent("popstate", { detail }));
      this.dispatchEvent(new Event("index-change"));
    }
    forward() {
      const index = this.#index;
      if (index >= this.#arr.length - 1) return;
      const detail = { state: this.#arr[index + 1] };
      this.#index = index + 1;
      this.dispatchEvent(new CustomEvent("popstate", { detail }));
      this.dispatchEvent(new Event("index-change"));
    }
    get canGoBack() {
      return this.#index > 0;
    }
    get canGoForward() {
      return this.#index < this.#arr.length - 1;
    }
    clear() {
      this.#arr = [];
      this.#index = -1;
    }
  };
  var textWalker = function* (doc, func) {
    const filter = NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION;
    const { FILTER_ACCEPT: FILTER_ACCEPT2, FILTER_REJECT: FILTER_REJECT2, FILTER_SKIP: FILTER_SKIP2 } = NodeFilter;
    const acceptNode = (node) => {
      const name = node.localName?.toLowerCase();
      if (name === "script" || name === "style") return FILTER_REJECT2;
      if (node.nodeType === 1) return FILTER_SKIP2;
      return FILTER_ACCEPT2;
    };
    const walker = doc.createTreeWalker(doc.body, filter, { acceptNode });
    const nodes = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      nodes.push(node);
    const strs = nodes.map((node) => node.nodeValue);
    const makeRange = (startIndex, startOffset, endIndex, endOffset) => {
      const range = doc.createRange();
      range.setStart(nodes[startIndex], startOffset);
      range.setEnd(nodes[endIndex], endOffset);
      return range;
    };
    for (const match of func(strs, makeRange)) yield match;
  };
  var languageInfo = (lang) => {
    if (!lang) return {};
    try {
      const canonical = Intl.getCanonicalLocales(lang)[0];
      const locale = new Intl.Locale(canonical);
      const isCJK = ["zh", "ja", "kr"].includes(locale.language);
      const direction = (locale.getTextInfo?.() ?? locale.textInfo)?.direction;
      return { canonical, locale, isCJK, direction };
    } catch (e2) {
      console.warn(e2);
      return {};
    }
  };
  var View2 = class extends HTMLElement {
    #root = this.attachShadow({ mode: "closed" });
    #sectionProgress;
    #tocProgress;
    #pageProgress;
    #isCacheWarmer;
    #searchResults = /* @__PURE__ */ new Map();
    isFixedLayout = false;
    lastLocation;
    history = new History();
    constructor() {
      super();
      this.history.addEventListener("popstate", async ({ detail }) => {
        const resolved = this.resolveNavigation(detail.state);
        await this.renderer.goTo(resolved);
      });
    }
    async open(book, isCacheWarmer) {
      this.book = book;
      this.language = languageInfo(book.metadata?.language);
      this.#isCacheWarmer = isCacheWarmer;
      if (book.splitTOCHref && book.getTOCFragment) {
        const ids = book.sections.map((s2) => s2.id);
        this.#sectionProgress = new SectionProgress(book.sections, 1500, 1600);
        const splitHref = book.splitTOCHref.bind(book);
        const getFragment = book.getTOCFragment.bind(book);
        this.#tocProgress = new TOCProgress({
          toc: book.toc ?? [],
          ids,
          splitHref,
          getFragment
        });
        this.#pageProgress = new TOCProgress({
          toc: book.pageList ?? [],
          ids,
          splitHref,
          getFragment
        });
      }
      this.isFixedLayout = this.book.rendition?.layout === "pre-paginated";
      if (this.isFixedLayout) {
        globalThis.manabiLoadEBookLastState = "view-open-fixed-layout-import-ready";
        globalThis.manabiLoadEBookLastState = "view-open-fixed-layout-pre-create-renderer";
        this.renderer = document.createElement("foliate-fxl");
      } else {
        globalThis.manabiLoadEBookLastState = "view-open-paginator-import-ready";
        globalThis.manabiLoadEBookLastState = "view-open-paginator-pre-create-renderer";
        this.renderer = document.createElement("foliate-paginator");
      }
      globalThis.manabiLoadEBookLastState = "view-open-renderer-created";
      this.renderer.setAttribute("exportparts", "head,foot");
      this.renderer.addEventListener("load", (e2) => this.#onLoad(e2.detail));
      this.renderer.addEventListener("relocate", (e2) => this.#onRelocate(e2.detail));
      globalThis.manabiLoadEBookLastState = "view-open-renderer-open-called";
      this.renderer.open(book, isCacheWarmer);
      globalThis.manabiLoadEBookLastState = "view-open-renderer-pre-append";
      this.#root.append(this.renderer);
      globalThis.manabiLoadEBookLastState = "view-open-renderer-appended";
      const rendererLoadPromise = new Promise((resolve) => {
        const onLoad = () => {
          globalThis.manabiLoadEBookLastState = "view-open-renderer-load-event";
          resolve("load");
        };
        const onRelocate = () => {
          globalThis.manabiLoadEBookLastState = "view-open-renderer-relocate-event";
          resolve("relocate");
        };
        this.renderer.addEventListener("load", onLoad, { once: true });
        this.renderer.addEventListener("relocate", onRelocate, { once: true });
        setTimeout(() => resolve("timeout"), 15e3);
      });
      globalThis.manabiLoadEBookLastState = "view-open-awaiting-renderer-event";
      rendererLoadPromise.then((rendererReadyEvent) => {
        globalThis.manabiLoadEBookLastState = `view-open-renderer-event:${rendererReadyEvent}`;
      });
    }
    close() {
      this.renderer?.destroy();
      this.renderer?.remove();
      this.#sectionProgress = null;
      this.#tocProgress = null;
      this.#pageProgress = null;
      this.#searchResults = /* @__PURE__ */ new Map();
      this.lastLocation = null;
      this.history.clear();
    }
    async goToTextStart() {
      return await this.goTo(this.book.landmarks?.find((m2) => m2.type.includes("bodymatter") || m2.type.includes("text"))?.href ?? this.book.sections.findIndex((s2) => s2.linear !== "no"));
    }
    async init({ lastLocation, showTextStart }) {
      const resolved = lastLocation ? this.resolveNavigation(lastLocation) : null;
      if (resolved) {
        await this.renderer.goTo(resolved);
        this.history.pushState(lastLocation);
      } else if (showTextStart) {
        await this.goToTextStart();
      } else {
        this.history.pushState(0);
        await this.next();
      }
    }
    #emit(name, detail, cancelable) {
      return this.dispatchEvent(new CustomEvent(name, { detail, cancelable }));
    }
    #onRelocate(detail) {
      if (!detail) return;
      const {
        reason,
        range,
        index,
        fraction,
        size,
        pageNumber,
        pageCount,
        scrolled,
        sizeFraction,
        startOffset,
        pageSize,
        viewSize
      } = detail;
      const progress = this.#sectionProgress?.getProgress(index, fraction, size) ?? {};
      const tocItem = this.#tocProgress?.getProgress(index, range);
      const pageItem = this.#pageProgress?.getProgress(index, range);
      const cfi = this.getCFI(index, range);
      this.lastLocation = {
        ...progress,
        tocItem,
        pageItem,
        cfi,
        range,
        reason,
        fraction,
        size,
        pageNumber,
        pageCount,
        scrolled,
        sizeFraction,
        startOffset,
        pageSize,
        viewSize
      };
      if (reason === "snap" || reason === "page" || reason === "scroll") {
        this.history.replaceState(cfi);
      }
      this.#emit("relocate", this.lastLocation);
    }
    #onLoad({ doc, location, index }) {
      if (!this.#isCacheWarmer) {
        doc.documentElement.lang ||= this.language.canonical ?? "";
        if (!this.language.isCJK)
          doc.documentElement.dir ||= this.language.direction ?? "";
        this.#handleLinks(doc, index);
      }
      this.#emit("load", { doc, location, index });
    }
    #handleLinks(doc, index) {
      const { book } = this;
      const section = book.sections[index];
      const linkRoot = doc.getElementById?.("reader-content") || doc;
      for (const a2 of linkRoot.querySelectorAll("a[href]"))
        a2.addEventListener("click", (e2) => {
          e2.preventDefault();
          const href_ = a2.getAttribute("href");
          const href = section?.resolveHref?.(href_) ?? href_;
          if (book?.isExternal?.(href))
            Promise.resolve(this.#emit("external-link", { a: a2, href }, true)).then((x2) => x2 ? globalThis.open(href, "_blank") : null).catch((e3) => console.error(e3));
          else Promise.resolve(this.#emit("link", { a: a2, href }, true)).then(async (x2) => x2 ? await this.goTo(href) : null).catch((e3) => console.error(e3));
        });
    }
    async addAnnotation(annotation, _remove) {
      const { value } = annotation;
      const resolved = await this.resolveNavigation(value.startsWith?.(SEARCH_PREFIX) ? value.replace(SEARCH_PREFIX, "") : value);
      const index = resolved?.index;
      const label = typeof index === "number" ? this.#tocProgress?.getProgress(index)?.label ?? "" : "";
      return { index, label };
    }
    deleteAnnotation(annotation) {
      return this.addAnnotation(annotation, true);
    }
    #getOverlayer(_index) {
      return null;
    }
    #createOverlayer(_detail) {
      return null;
    }
    async showAnnotation(_annotation) {
      return;
    }
    getCFI(index, range) {
      const baseCFI = this.book.sections[index].cfi ?? fake.fromIndex(index);
      if (!range) return baseCFI;
      return joinIndir(baseCFI, fromRange(range));
    }
    resolveCFI(cfi) {
      if (this.book.resolveCFI)
        return this.book.resolveCFI(cfi);
      else {
        const parts = parse(cfi);
        const index = fake.toIndex((parts.parent ?? parts).shift());
        const anchor = (doc) => toRange(doc, parts);
        return { index, anchor };
      }
    }
    resolveNavigation(target) {
      try {
        if (typeof target === "number") {
          return { index: target };
        }
        if (typeof target.fraction === "number") {
          const [index, anchor] = this.#sectionProgress.getSection(target.fraction);
          return { index, anchor };
        }
        if (isCFI.test(target)) {
          return this.resolveCFI(target);
        }
        return this.book.resolveHref(target);
      } catch (e2) {
        console.error(e2);
        console.error(`Could not resolve target ${target}`);
      }
    }
    async goTo(target) {
      const resolved = this.resolveNavigation(target);
      try {
        await this.renderer.goTo(resolved);
        this.history.pushState(target);
        return resolved;
      } catch (e2) {
        console.error(e2);
        console.error(`Could not go to ${target}`);
        throw e2;
      }
    }
    async goToFraction(frac) {
      const [index, anchor] = this.#sectionProgress.getSection(frac);
      await this.renderer.goTo({ index, anchor });
      this.history.pushState({ fraction: frac });
    }
    async select(target) {
      try {
        const obj = await this.resolveNavigation(target);
        await this.renderer.goTo({ ...obj, select: true });
        this.history.pushState(target);
      } catch (e2) {
        console.error(e2);
        console.error(`Could not go to ${target}`);
      }
    }
    deselect() {
      for (const { doc } of this.renderer.getContents())
        doc.defaultView.getSelection().removeAllRanges();
    }
    async getTOCItemOf(target) {
      try {
        const { index, anchor } = await this.resolveNavigation(target);
        const doc = await this.book.sections[index].createDocument();
        const frag = anchor(doc);
        const isRange = frag instanceof Range;
        const range = isRange ? frag : doc.createRange();
        if (!isRange) range.selectNodeContents(frag);
        return this.#tocProgress.getProgress(index, range);
      } catch (e2) {
        console.error(e2);
        console.error(`Could not get ${target}`);
      }
    }
    async prev(distance) {
      const useSectionJump = distance == null && this.renderer?.getHasPrevSection?.() && await this.renderer?.isAtSectionStart?.();
      logBug2?.("view:prev", {
        distance: distance ?? null,
        useSectionJump,
        hasPrevSection: this.renderer?.getHasPrevSection?.() ?? null,
        bookDir: this.book?.dir ?? null
      });
      if (useSectionJump) {
        logBug2?.("view:prev:section-jump", {
          bookDir: this.book?.dir ?? null
        });
        return await this.renderer.prevSection();
      }
      logBug2?.("view:prev:intra-section", {
        distance: distance ?? null,
        bookDir: this.book?.dir ?? null
      });
      return await this.renderer.prev(distance);
    }
    async next(distance) {
      const useSectionJump = distance == null && this.renderer?.getHasNextSection?.() && await this.renderer?.isAtSectionEnd?.();
      logBug2?.("view:next", {
        distance: distance ?? null,
        useSectionJump,
        hasNextSection: this.renderer?.getHasNextSection?.() ?? null,
        bookDir: this.book?.dir ?? null
      });
      if (useSectionJump) {
        logBug2?.("view:next:section-jump", {
          bookDir: this.book?.dir ?? null
        });
        return await this.renderer.nextSection();
      }
      logBug2?.("view:next:intra-section", {
        distance: distance ?? null,
        bookDir: this.book?.dir ?? null
      });
      return await this.renderer.next(distance);
    }
    async goLeft() {
      const isForward = this.book.dir === "rtl";
      if (!this.#isCacheWarmer) {
        postNavigationChromeVisibility(isForward, {
          source: "swipe-left",
          direction: isForward ? "forward" : "backward"
        });
      }
      logNavHide("view:goLeft", {
        dir: this.book.dir,
        requestedHide: isForward,
        cacheWarmer: this.#isCacheWarmer,
        navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
      });
      logBug2?.("view:goLeft", {
        dir: this.book.dir,
        cacheWarmer: this.#isCacheWarmer
      });
      return this.book.dir === "rtl" ? await this.next() : await this.prev();
    }
    async goRight() {
      const isForward = this.book.dir !== "rtl";
      if (!this.#isCacheWarmer) {
        postNavigationChromeVisibility(isForward, {
          source: "swipe-right",
          direction: isForward ? "forward" : "backward"
        });
      }
      logNavHide("view:goRight", {
        dir: this.book.dir,
        requestedHide: isForward,
        cacheWarmer: this.#isCacheWarmer,
        navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
      });
      logBug2?.("view:goRight", {
        dir: this.book.dir,
        cacheWarmer: this.#isCacheWarmer
      });
      return this.book.dir === "rtl" ? await this.prev() : await this.next();
    }
    async *#searchSection(matcher, query, index) {
      const doc = await this.book.sections[index].createDocument();
      for (const { range, excerpt } of matcher(doc, query))
        yield { cfi: this.getCFI(index, range), excerpt };
    }
    async *#searchBook(matcher, query) {
      const { sections } = this.book;
      for (const [index, { createDocument }] of sections.entries()) {
        if (!createDocument) continue;
        const doc = await createDocument();
        const subitems = Array.from(matcher(doc, query), ({ range, excerpt }) => ({ cfi: this.getCFI(index, range), excerpt }));
        const progress = (index + 1) / sections.length;
        yield { progress };
        if (subitems.length) yield { index, subitems };
      }
    }
    async *search(opts) {
      this.clearSearch();
      const { searchMatcher: searchMatcher2 } = await Promise.resolve().then(() => (init_search(), search_exports));
      const { query, index } = opts;
      const matcher = searchMatcher2(
        textWalker,
        { defaultLocale: this.language, ...opts }
      );
      const iter = index != null ? this.#searchSection(matcher, query, index) : this.#searchBook(matcher, query);
      const list = [];
      this.#searchResults.set(index, list);
      for await (const result of iter) {
        if (result.subitems) {
          const list2 = result.subitems.map(({ cfi }) => ({ value: SEARCH_PREFIX + cfi }));
          this.#searchResults.set(result.index, list2);
          for (const item of list2) this.addAnnotation(item);
          yield {
            label: this.#tocProgress.getProgress(result.index)?.label ?? "",
            subitems: result.subitems
          };
        } else {
          if (result.cfi) {
            const item = { value: SEARCH_PREFIX + result.cfi };
            list.push(item);
            this.addAnnotation(item);
          }
          yield result;
        }
      }
      yield "done";
    }
    clearSearch() {
      for (const list of this.#searchResults.values())
        for (const item of list) this.deleteAnnotation(item);
      this.#searchResults.clear();
    }
  };
  customElements.define("foliate-view", View2);

  // ui/tree.js
  var createSVGElement = (tag) => document.createElementNS("http://www.w3.org/2000/svg", tag);
  var createExpanderIcon = () => {
    const svg = createSVGElement("svg");
    svg.setAttribute("viewBox", "0 0 13 10");
    svg.setAttribute("width", "13");
    svg.setAttribute("height", "13");
    const polygon = createSVGElement("polygon");
    polygon.setAttribute("points", "2 1, 12 1, 7 9");
    svg.append(polygon);
    return svg;
  };
  var createTOCItemElement = (list, map, onclick) => {
    let count = 0;
    const makeID = () => `toc-element-${count++}`;
    const createItem = ({ label, href, subitems }, depth = 0) => {
      const a2 = document.createElement(href ? "a" : "span");
      a2.innerText = label;
      a2.setAttribute("role", "treeitem");
      a2.tabIndex = -1;
      a2.style.paddingInlineStart = `${(depth + 1) * 24}px`;
      list.push(a2);
      if (href) {
        if (!map.has(href)) map.set(href, a2);
        a2.href = href;
        a2.onclick = (event) => {
          event.preventDefault();
          onclick(href);
        };
      } else a2.onclick = (event) => a2.firstElementChild?.onclick(event);
      const li = document.createElement("li");
      li.setAttribute("role", "none");
      li.append(a2);
      if (subitems?.length) {
        a2.setAttribute("aria-expanded", "false");
        const expander = createExpanderIcon();
        expander.onclick = (event) => {
          event.preventDefault();
          event.stopPropagation();
          const expanded = a2.getAttribute("aria-expanded");
          a2.setAttribute("aria-expanded", expanded === "true" ? "false" : "true");
        };
        a2.prepend(expander);
        const ol = document.createElement("ol");
        ol.id = makeID();
        ol.setAttribute("role", "group");
        a2.setAttribute("aria-owns", ol.id);
        ol.replaceChildren(...subitems.map((item) => createItem(item, depth + 1)));
        li.append(ol);
      }
      return li;
    };
    return createItem;
  };
  var createTOCView = (toc, onclick) => {
    const $toc = document.createElement("ol");
    $toc.setAttribute("role", "tree");
    const list = [];
    const map = /* @__PURE__ */ new Map();
    const createItem = createTOCItemElement(list, map, onclick);
    $toc.replaceChildren(...toc.map((item) => createItem(item)));
    const isTreeItem = (item) => item?.getAttribute("role") === "treeitem";
    const getParents = function* (el) {
      for (let parent = el.parentNode; parent !== $toc; parent = parent.parentNode) {
        const item = parent.previousElementSibling;
        if (isTreeItem(item)) yield item;
      }
    };
    let currentItem, currentVisibleParent;
    $toc.addEventListener("focusout", () => {
      if (!currentItem) return;
      if (currentVisibleParent) currentVisibleParent.tabIndex = -1;
      if (currentItem.offsetParent) {
        currentItem.tabIndex = 0;
        return;
      }
      for (const item of getParents(currentItem)) {
        if (item.offsetParent) {
          item.tabIndex = 0;
          currentVisibleParent = item;
          break;
        }
      }
    });
    const setCurrentHref = (href) => {
      if (currentItem) {
        currentItem.removeAttribute("aria-current");
        currentItem.tabIndex = -1;
      }
      const el = map.get(href);
      if (!el) {
        currentItem = list[0];
        currentItem.tabIndex = 0;
        return;
      }
      for (const item of getParents(el))
        item.setAttribute("aria-expanded", "true");
      el.setAttribute("aria-current", "page");
      el.tabIndex = 0;
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      currentItem = el;
    };
    const acceptNode = (node) => isTreeItem(node) && node.offsetParent ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
    const iter = document.createTreeWalker($toc, 1, { acceptNode });
    const getIter = (current) => (iter.currentNode = current, iter);
    for (const el of list) el.addEventListener("keydown", (event) => {
      let stop = false;
      const { currentTarget, key } = event;
      switch (key) {
        case " ":
        case "Enter":
          currentTarget.click();
          stop = true;
          break;
        case "ArrowDown":
          getIter(currentTarget).nextNode()?.focus();
          stop = true;
          break;
        case "ArrowUp":
          getIter(currentTarget).previousNode()?.focus();
          stop = true;
          break;
        case "ArrowLeft":
          if (currentTarget.getAttribute("aria-expanded") === "true")
            currentTarget.setAttribute("aria-expanded", "false");
          else getParents(currentTarget).next()?.value?.focus();
          stop = true;
          break;
        case "ArrowRight":
          if (currentTarget.getAttribute("aria-expanded") === "true")
            getIter(currentTarget).nextNode()?.focus();
          else if (currentTarget.getAttribute("aria-owns"))
            currentTarget.setAttribute("aria-expanded", "true");
          stop = true;
          break;
        case "Home":
          list[0].focus();
          stop = true;
          break;
        case "End": {
          const last = list[list.length - 1];
          if (last.offsetParent) last.focus();
          else getIter(last).previousNode()?.focus();
          stop = true;
          break;
        }
      }
      if (stop) {
        event.preventDefault();
        event.stopPropagation();
      }
    });
    return { element: $toc, setCurrentHref };
  };

  // ebook-viewer-nav.js
  var MAX_RELOCATE_STACK = 50;
  var FRACTION_EPSILON = 1e-6;
  var logEBookPageNumCounter2 = 0;
  var LOG_EBOOK_PAGE_NUM_LIMIT2 = 400;
  var MANABI_NAV_SENTINEL_ADJUST_ENABLED = true;
  var NAV_PAGE_NUM_WHITELIST = /* @__PURE__ */ new Set([
    "nav:set-page-targets",
    "nav:total-pages-source",
    "nav:page-metrics",
    "nav:relocate:input",
    "relocate",
    "relocate:label",
    "ui:primary-label",
    "ui:section-progress"
  ]);
  var logEBookPageNumLimited2 = (event, detail = {}) => {
    const verbose = !!globalThis.manabiPageNumVerbose;
    const allow = verbose || NAV_PAGE_NUM_WHITELIST.has(event);
    if (!allow) return;
    if (logEBookPageNumCounter2 >= LOG_EBOOK_PAGE_NUM_LIMIT2) return;
    logEBookPageNumCounter2 += 1;
    const payload = { event, count: logEBookPageNumCounter2, ...detail };
    const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
      try {
        console.log(line);
      } catch (_2) {
      }
    }
  };
  var logFix = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      window.webkit?.messageHandlers?.print?.postMessage?.(`# EBOOKFIX1 ${JSON.stringify(payload)}`);
    } catch (_err) {
      try {
        console.log("# EBOOKFIX1", event, detail);
      } catch (_2) {
      }
    }
  };
  var logBug3 = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      window.webkit?.messageHandlers?.print?.postMessage?.(`# BOOKBUG1 ${JSON.stringify(payload)}`);
    } catch (_err) {
      try {
        console.log("# BOOKBUG1", event, detail);
      } catch (_2) {
      }
    }
  };
  var logNavHide2 = (event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
      try {
        console.log(line);
      } catch (_2) {
      }
    }
  };
  var flattenPageTargets = (items, collector = []) => {
    if (!Array.isArray(items)) return collector;
    for (const item of items) {
      if (!item) continue;
      collector.push(item);
      if (Array.isArray(item.subitems) && item.subitems.length) {
        flattenPageTargets(item.subitems, collector);
      }
    }
    return collector;
  };
  var ensurePageKey = (item, fallbackIndex = 0) => {
    if (!item) return null;
    if (item.__manabiPageKey) return item.__manabiPageKey;
    const key = item.href ?? `${item.label ?? "page"}-${fallbackIndex}`;
    try {
      Object.defineProperty(item, "__manabiPageKey", {
        value: key,
        enumerable: false,
        configurable: false,
        writable: false
      });
    } catch (error) {
    }
    return key;
  };
  var NavigationHUD = class {
    constructor({ onJumpRequest, getRenderer, formatPercent } = {}) {
      this.onJumpRequest = onJumpRequest;
      this.getRenderer = getRenderer;
      this.formatPercent = formatPercent ?? ((value) => `${Math.round(value * 100)}%`);
      this.navBar = document.getElementById("nav-bar");
      this.navPrimaryText = document.getElementById("nav-primary-text");
      this.navPrimaryTextFull = document.getElementById("nav-primary-text-full");
      this.navPrimaryTextCompact = document.getElementById("nav-primary-text-compact");
      this.navPrimaryPercent = document.getElementById("nav-primary-percent");
      this.navHiddenOverlay = {
        text: document.getElementById("nav-hidden-primary-text"),
        percent: document.getElementById("nav-hidden-primary-percent")
      };
      this.navSectionProgress = {
        leading: document.getElementById("nav-section-progress-leading"),
        trailing: document.getElementById("nav-section-progress-trailing")
      };
      this.navRelocateButtons = {
        back: document.getElementById("nav-relocate-back"),
        forward: document.getElementById("nav-relocate-forward")
      };
      this.navRelocateLabels = {
        back: document.getElementById("nav-relocate-label-back"),
        forward: document.getElementById("nav-relocate-label-forward")
      };
      this.completionStack = document.getElementById("completion-stack");
      this.progressWrapper = document.getElementById("progress-wrapper");
      this.progressSlider = document.getElementById("progress-slider");
      this.hideNavigationDueToScroll = false;
      this.isRTL = false;
      this.navContext = null;
      this.totalPageCount = 0;
      this.pageTargets = [];
      this.pageTargetIndexByKey = /* @__PURE__ */ new Map();
      this.sectionPageCounts = /* @__PURE__ */ new Map();
      this.lastSectionIndexSeen = null;
      this.currentLocationDescriptor = null;
      this.lastRelocateDetail = null;
      this.isProcessingRelocateJump = false;
      this.relocateStacks = {
        back: [],
        forward: []
      };
      this.scrubSession = null;
      this.pendingRelocateJump = null;
      this.primaryLineRequestToken = 0;
      this.rendererPageSnapshot = null;
      this.latestPrimaryLabel = "";
      this.previousRelocateVisibility = {
        back: null,
        forward: null
      };
      this.lastPrimaryLabelDiagnostics = null;
      this.fallbackTotalPageCount = null;
      this.lastTotalSource = null;
      this.lastTotalPagesSnapshot = null;
      this.lastPageMetricsSnapshot = null;
      this.lastScrubberFraction = null;
      this.lastKnownLocationTotal = null;
      this.navHidden = false;
      this.#applyLabelVariant();
      if (this.pendingScrubCommit) {
        this.#logPageScrub("pending-commit-reset", {
          reason: "new-scrub"
        });
        this.pendingScrubCommit = null;
      }
      this.navRelocateButtons.back?.addEventListener("click", () => this.#handleRelocateJump("back"));
      this.navRelocateButtons.forward?.addEventListener("click", () => this.#handleRelocateJump("forward"));
      this.#updateRelocateButtons();
      this.#applyRelocateButtonEdges();
    }
    #logJumpBack(event, payload = {}) {
      const cleanedEntries = Object.entries(payload ?? {}).filter(([, value]) => value !== void 0);
      const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : "";
      const line = metadata ? `# JUMPBACK ${event} ${metadata}` : `# JUMPBACK ${event}`;
      try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
      } catch (_error) {
      }
      try {
        console.log(line);
      } catch (_error) {
      }
    }
    #logJumpButton(event, payload = {}) {
      const cleanedEntries = Object.entries(payload ?? {}).filter(([, value]) => value !== void 0);
      const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : "";
      const line = metadata ? `# JUMPTOBUTTON ${event} ${metadata}` : `# JUMPTOBUTTON ${event}`;
      try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
      } catch (_error) {
      }
      try {
        console.log(line);
      } catch (_error) {
      }
    }
    linearSectionCount = null;
    linearSectionIndexes = /* @__PURE__ */ new Set();
    setIsRTL(isRTL) {
      this.isRTL = !!isRTL;
      this.#applyRelocateButtonEdges();
      this.#updateSectionProgress();
    }
    setSectionPageCountsFromCache(counts) {
      if (!(counts instanceof Map) || counts.size === 0) return;
      const linearCount = Array.isArray(this.navContext?.sections) ? this.navContext.sections.filter((s2) => s2.linear !== "no").length : null;
      if (typeof linearCount === "number" && linearCount > 0 && counts.size < linearCount) {
        logBug3?.("pagecount:cachewarmer:skip-partial", {
          received: counts.size,
          linearCount
        });
        return;
      }
      logBug3?.("pagecount:cachewarmer:apply", {
        received: counts.size,
        linearCount,
        total: Array.from(counts.values()).reduce((a2, v2) => a2 + (Number.isFinite(v2) ? v2 : 0), 0)
      });
      this.sectionPageCounts = new Map(counts);
      const total = Array.from(counts.values()).reduce((acc, v2) => acc + (Number.isFinite(v2) && v2 > 0 ? v2 : 0), 0);
      if (total > 0) {
        this.fallbackTotalPageCount = total;
        this.lastTotalSource = "cachewarmer";
      }
      if (this.lastRelocateDetail) {
        this.#updateRendererSnapshotFromDetail(this.lastRelocateDetail);
        this.#updatePrimaryLine(this.lastRelocateDetail);
      }
      this.#updateSectionProgress({ refreshSnapshot: false });
      this.#updateRelocateButtons();
    }
    setPageTargets(pageList) {
      this.sectionPageCounts.clear?.();
      this.lastSectionIndexSeen = null;
      this.lastScrubberFraction = null;
      this.pageTargets = flattenPageTargets(pageList ?? []);
      this.pageTargetIndexByKey = /* @__PURE__ */ new Map();
      this.pageTargets.forEach((item, index) => {
        const key = ensurePageKey(item, index);
        if (key) {
          this.pageTargetIndexByKey.set(key, index);
        }
      });
      this.totalPageCount = this.pageTargets.length;
      if (this.totalPageCount > 0) {
        this.fallbackTotalPageCount = this.totalPageCount;
      }
      const pageKeyPreview = this.pageTargets.slice(0, 5).map((item, index) => ({
        idx: index,
        key: ensurePageKey(item, index),
        label: item?.label ?? null
      }));
      this.#logPageNumberDiagnostic("set-page-targets", {
        pageTargetCount: this.totalPageCount
      });
      logEBookPageNumLimited2("nav:set-page-targets", {
        pageTargetCount: this.totalPageCount,
        preview: pageKeyPreview,
        totalSource: this.lastTotalSource ?? null
      });
      if (this.lastRelocateDetail) {
        this.#updatePrimaryLine(this.lastRelocateDetail);
      }
    }
    setNavContext(context) {
      this.navContext = context ?? null;
      this.linearSectionIndexes = /* @__PURE__ */ new Set();
      if (Array.isArray(this.navContext?.sections)) {
        this.navContext.sections.forEach((section, idx) => {
          if (section?.linear !== "no") this.linearSectionIndexes.add(idx);
        });
      }
      this.linearSectionCount = this.linearSectionIndexes.size || null;
      this.#toggleCompletionStack();
      this.#updateSectionProgress();
      this.#updateRelocateButtons();
    }
    setHideNavigationDueToScroll(shouldHide, source = "unknown", context = null) {
      const previous = this.hideNavigationDueToScroll;
      this.hideNavigationDueToScroll = !!shouldHide;
      this.navBar?.classList.toggle("nav-hidden-due-to-scroll", this.hideNavigationDueToScroll);
      this.#applyLabelVariant();
      logNavHide2("hud:set-hide", {
        shouldHide: this.hideNavigationDueToScroll,
        previous,
        source,
        navHiddenClass: this.navBar?.classList?.contains?.("nav-hidden") ?? null,
        navHiddenScrollClass: this.navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? null,
        progressWrapperHidden: this.progressWrapper?.getAttribute?.("aria-hidden") ?? null,
        context
      });
      logBug3?.("navhud-hide", {
        shouldHide: this.hideNavigationDueToScroll,
        navHiddenClass: this.navBar?.classList?.contains?.("nav-hidden") ?? null,
        navHiddenScrollClass: this.navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? null
      });
      if (this.progressWrapper) {
        this.progressWrapper.setAttribute("aria-hidden", this.hideNavigationDueToScroll ? "true" : "false");
      }
      if (this.progressSlider) {
        if (this.hideNavigationDueToScroll) {
          this.progressSlider.setAttribute("tabindex", "-1");
        } else {
          this.progressSlider.removeAttribute("tabindex");
        }
      }
      if (this.lastRelocateDetail) {
        this.#updatePrimaryLine(this.lastRelocateDetail);
      }
      this.#updateRelocateButtons();
    }
    // External toggle for full nav hide (not the scroll HUD hide).
    setNavHiddenState(shouldHide) {
      this.navHidden = !!shouldHide;
      this.#applyLabelVariant();
      const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
      if (descriptor) {
        this.#updatePrimaryLine(descriptor);
      }
    }
    getCurrentDescriptor() {
      return this.#cloneDescriptor(this.currentLocationDescriptor);
    }
    beginProgressScrubSession(originDescriptor) {
      if (this.pendingScrubCommit) {
        const fallbackDescriptor = this.#cloneDescriptor(this.currentLocationDescriptor);
        if (fallbackDescriptor) {
          const flushed = this.#maybeCommitPendingScrub({
            reason: "scrub-begin-flush",
            liveScrollPhase: "settled"
          }, fallbackDescriptor);
          if (!flushed && this.pendingScrubCommit) {
            this.#logPageScrub("pending-commit-awaiting-detail", {
              reason: "scrub-begin",
              pendingOriginFraction: typeof this.pendingScrubCommit?.origin?.fraction === "number" ? Number(this.pendingScrubCommit.origin.fraction.toFixed(6)) : null
            });
          }
        } else if (this.pendingScrubCommit) {
          this.#logPageScrub("pending-commit-awaiting-detail", {
            reason: "scrub-begin-no-descriptor"
          });
        }
      }
      const baselineDescriptor = this.#cloneDescriptor(originDescriptor) || this.#cloneDescriptor(this.currentLocationDescriptor) || null;
      const originFraction = typeof baselineDescriptor?.fraction === "number" ? baselineDescriptor.fraction : null;
      const frozenLabel = this.getPrimaryDisplayLabel(baselineDescriptor) || this.navPrimaryText?.textContent || this.latestPrimaryLabel || "";
      this.scrubSession = {
        active: true,
        originDescriptor: baselineDescriptor,
        originFraction,
        hasMoved: false,
        frozenLabel
      };
      if (frozenLabel && this.navPrimaryText) {
        const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
        const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
        fullLabelTarget.textContent = frozenLabel;
        compactLabelTarget.textContent = frozenLabel;
      }
      this.#logPageScrub("begin", {
        originFraction,
        hasDescriptor: !!baselineDescriptor
      });
      this.#logJumpDiagnostic("scrub-begin", {
        hasOrigin: !!originDescriptor,
        backDepth: this.relocateStacks.back.length
      });
      this.#updateRelocateButtons();
    }
    endProgressScrubSession(finalDescriptor, { cancel, releaseFraction } = {}) {
      if (!this.scrubSession) return;
      const session = this.scrubSession;
      const comparisonDescriptor = this.#cloneDescriptor(finalDescriptor ?? this.currentLocationDescriptor);
      let committed = false;
      let returnedToOrigin = false;
      let deferredCommit = false;
      const releaseValue = typeof releaseFraction === "number" ? releaseFraction : comparisonDescriptor?.fraction ?? null;
      const releaseMoved = typeof releaseValue === "number" && typeof session.originFraction === "number" && Math.abs(releaseValue - session.originFraction) > FRACTION_EPSILON;
      if (!cancel && session.originDescriptor && session.hasMoved && releaseMoved) {
        this.pendingScrubCommit = {
          origin: this.#cloneDescriptor(session.originDescriptor),
          reason: "scrub-release",
          releaseFraction: releaseValue,
          scheduledAt: Date.now(),
          releaseDescriptor: comparisonDescriptor
        };
        deferredCommit = true;
        this.#logPageScrub("pending-commit", {
          originFraction: session.originFraction ?? null,
          releaseFraction: releaseValue
        });
      } else {
        this.pendingScrubCommit = null;
        if (!cancel) {
          returnedToOrigin = !session.hasMoved || !releaseMoved;
        }
      }
      const releaseDescriptor = this.#descriptorFromFraction(releaseValue) || comparisonDescriptor;
      if (this.pendingScrubCommit && releaseDescriptor) {
        const pushedNow = this.#maybeCommitPendingScrub({
          reason: "scrub-finalize",
          liveScrollPhase: "settled"
        }, releaseDescriptor, { updateButtons: false });
        if (pushedNow) {
          committed = true;
          deferredCommit = false;
          this.#updateRelocateButtons();
        } else {
          deferredCommit = !!this.pendingScrubCommit;
        }
      } else {
        deferredCommit = !!this.pendingScrubCommit;
      }
      this.#logPageScrub("end", {
        cancel,
        committed,
        returnedToOrigin,
        deferredCommit
      });
      this.scrubSession = null;
      this.#updateRelocateButtons();
      if (comparisonDescriptor || this.currentLocationDescriptor) {
        this.#updatePrimaryLine(comparisonDescriptor || this.currentLocationDescriptor);
      }
      this.#logJumpDiagnostic("scrub-end", {
        cancel,
        committed,
        returnedToOrigin,
        hadMovement: session.hasMoved,
        originFraction: session.originFraction ?? null,
        finalFraction: comparisonDescriptor?.fraction ?? null,
        backDepth: this.relocateStacks.back.length,
        forwardDepth: this.relocateStacks.forward.length
      });
    }
    async handleRelocate(detail) {
      if (!detail) return;
      const locCurrent = typeof detail?.location?.current === "number" ? detail.location.current : null;
      const locTotal = typeof detail?.location?.total === "number" ? detail.location.total : null;
      if (locTotal != null && locTotal > 0) {
        this.lastKnownLocationTotal = locTotal;
      }
      const rendererIndex = (() => {
        try {
          const r2 = this.getRenderer?.();
          return typeof r2?.currentIndex === "number" ? r2.currentIndex : null;
        } catch (_2) {
          return null;
        }
      })();
      const inferredSectionIndex = (() => {
        if (typeof detail.sectionIndex === "number") return detail.sectionIndex;
        if (typeof detail.index === "number") return detail.index;
        if (typeof rendererIndex === "number") return rendererIndex;
        if (typeof this.lastRelocateDetail?.sectionIndex === "number") return this.lastRelocateDetail.sectionIndex;
        if (typeof this.lastRelocateDetail?.index === "number") return this.lastRelocateDetail.index;
        if (typeof this.lastSectionIndexSeen === "number") return this.lastSectionIndexSeen;
        return null;
      })();
      if (typeof inferredSectionIndex === "number") {
        detail.sectionIndex = inferredSectionIndex;
        this.lastSectionIndexSeen = inferredSectionIndex;
      }
      if (typeof detail.sectionIndex === "number" && typeof detail.pageCount === "number" && detail.pageCount > 0) {
        this.sectionPageCounts.set(detail.sectionIndex, detail.pageCount);
      }
      logEBookPageNumLimited2("nav:relocate:input", {
        sectionIndex: typeof detail.sectionIndex === "number" ? detail.sectionIndex : null,
        index: typeof detail.index === "number" ? detail.index : null,
        pageNumber: typeof detail.pageNumber === "number" ? detail.pageNumber : null,
        pageCount: typeof detail.pageCount === "number" ? detail.pageCount : null,
        scrolled: detail.scrolled ?? null,
        sectionPageCountsSize: this.sectionPageCounts.size,
        rendererIndex
      });
      this.#updateRendererSnapshotFromDetail(detail);
      await this.#refreshRendererSnapshot();
      this.lastRelocateDetail = detail;
      this.#handleRelocateHistory(detail);
      this.#logJumpBack("relocate-detail", {
        reason: detail?.reason ?? null,
        phase: detail?.liveScrollPhase ?? null,
        fraction: typeof detail?.fraction === "number" ? Number(detail.fraction.toFixed(6)) : null,
        processingPending: this.isProcessingRelocateJump
      });
      this.#logRelocateDetail(detail);
      this.#updatePrimaryLine(detail);
      this.#toggleCompletionStack();
      await this.#updateSectionProgress({ refreshSnapshot: false });
      this.#updateRelocateButtons();
      this.#pruneBackStackIfReturnedToOrigin(detail);
      this.#logPageNumberDiagnostic("relocate", {
        reason: detail?.reason ?? null,
        liveScrollPhase: detail?.liveScrollPhase ?? null,
        fraction: typeof detail?.fraction === "number" ? detail.fraction : null,
        label: this.latestPrimaryLabel ?? "",
        ...this.lastPrimaryLabelDiagnostics ?? {}
      });
    }
    #updateRendererSnapshotFromDetail(detail) {
      const scrolled = detail?.scrolled;
      const pageNumber = typeof detail?.pageNumber === "number" ? detail.pageNumber : null;
      const pageCount = typeof detail?.pageCount === "number" ? detail.pageCount : null;
      if (scrolled === false && pageNumber != null && pageNumber > 0 && pageCount != null && pageCount > 0) {
        const normalized = {
          current: Math.min(pageCount, Math.max(1, Math.round(pageNumber))),
          total: Math.max(1, Math.round(pageCount)),
          rawCurrent: Math.round(pageNumber),
          rawTotal: Math.round(pageCount),
          scrolled
        };
        this.rendererPageSnapshot = normalized;
        this.#updateFallbackTotalPages(normalized.total);
        logEBookPageNumLimited2("nav:renderer-snapshot:detail", {
          detailPage: pageNumber,
          detailTotal: pageCount,
          normalizedCurrent: normalized.current,
          normalizedTotal: normalized.total,
          scrolled,
          totalPageCount: this.totalPageCount,
          totalSource: this.lastTotalSource ?? null
        });
      }
    }
    #updatePrimaryLine(detail) {
      const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
      const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
      const overlayLabelTarget = this.navHiddenOverlay?.text;
      if (!fullLabelTarget || !compactLabelTarget) return;
      this.#syncLabelVariantFromDOM();
      const scrubFrozenLabel = this.scrubSession?.active ? this.scrubSession.frozenLabel : null;
      const fullLabelCandidate = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
      const rawLabel = fullLabelCandidate || scrubFrozenLabel || "";
      const normalizedRaw = rawLabel ? rawLabel.replace(/^Page\\s+/i, "Page ") : "";
      const condensed = normalizedRaw ? this.#condensePrimaryLabel(normalizedRaw) : "";
      fullLabelTarget.textContent = normalizedRaw || condensed;
      compactLabelTarget.textContent = condensed || normalizedRaw;
      if (overlayLabelTarget) {
        overlayLabelTarget.textContent = condensed || normalizedRaw;
      }
      if (fullLabelCandidate) {
        this.latestPrimaryLabel = fullLabelCandidate;
      }
      this.#updateCompactPercent(detail);
      logEBookPageNumLimited2("ui:primary-label", {
        label: fullLabelTarget.textContent || "",
        compactLabel: compactLabelTarget.textContent || "",
        source: this.lastPrimaryLabelDiagnostics?.source ?? null,
        current: this.lastPrimaryLabelDiagnostics?.candidateIndex != null ? this.lastPrimaryLabelDiagnostics.candidateIndex + 1 : null,
        total: null,
        // never report totals to UI log to avoid confusion with Loc
        rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
        rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
        hideNavigationDueToScroll: this.hideNavigationDueToScroll
      });
    }
    #applyLabelVariant() {
      if (!this.navPrimaryText?.dataset) return;
      const hide = this.hideNavigationDueToScroll || this.navHidden;
      this.navPrimaryText.dataset.labelVariant = hide ? "compact" : "full";
    }
    #syncLabelVariantFromDOM() {
      const bodyHidden = typeof document !== "undefined" ? document.body?.classList?.contains?.("nav-hidden") : false;
      const barHidden = this.navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? false;
      const desiredHide = bodyHidden || barHidden || this.hideNavigationDueToScroll || this.navHidden;
      if (this.navPrimaryText?.dataset) {
        const next = desiredHide ? "compact" : "full";
        if (this.navPrimaryText.dataset.labelVariant !== next) {
          this.navPrimaryText.dataset.labelVariant = next;
        }
      }
    }
    #updateCompactPercent(detail) {
      if (!this.navPrimaryPercent) return;
      const isCompact = this.navPrimaryText?.dataset?.labelVariant === "compact";
      const fraction = this.#fractionForPercent(detail);
      const hasValue = isCompact && typeof fraction === "number" && isFinite(fraction);
      const primary = this.navPrimaryPercent;
      const overlay = this.navHiddenOverlay?.percent;
      if (hasValue) {
        const clamped = Math.max(0, Math.min(1, fraction));
        const text = this.formatPercent(clamped);
        primary.textContent = text;
        primary.hidden = false;
        primary.setAttribute("aria-hidden", "false");
        if (overlay) {
          overlay.textContent = text;
          overlay.hidden = false;
          overlay.setAttribute("aria-hidden", "false");
        }
      } else {
        primary.textContent = "";
        primary.hidden = true;
        primary.setAttribute("aria-hidden", "true");
        if (overlay) {
          overlay.textContent = "";
          overlay.hidden = true;
          overlay.setAttribute("aria-hidden", "true");
        }
      }
    }
    #fractionForPercent(detail) {
      if (detail && typeof detail.fraction === "number") return detail.fraction;
      if (typeof this.lastScrubberFraction === "number") return this.lastScrubberFraction;
      const descriptorFraction = typeof this.currentLocationDescriptor?.fraction === "number" ? this.currentLocationDescriptor.fraction : null;
      return descriptorFraction;
    }
    #applyRelocateButtonEdges() {
      const backEdge = this.isRTL ? "right" : "left";
      const forwardEdge = this.isRTL ? "left" : "right";
      this.#setButtonEdge(this.navRelocateButtons?.back, backEdge);
      this.#setButtonEdge(this.navRelocateButtons?.forward, forwardEdge);
    }
    #setButtonEdge(button, edge) {
      if (!button || edge !== "left" && edge !== "right") return;
      if (button.dataset.navEdge !== edge) {
        button.dataset.navEdge = edge;
      }
      const icon = button.querySelector(".nav-relocate-icon");
      const label = button.querySelector(".nav-relocate-page");
      if (!icon || !label) return;
      if (edge === "left") {
        if (icon.nextElementSibling !== label) {
          button.insertBefore(icon, label);
        }
      } else {
        if (label.nextElementSibling !== icon) {
          button.insertBefore(label, icon);
        }
      }
    }
    #descriptorForRelocateLabel(direction) {
      const stack = this.relocateStacks?.[direction];
      if (stack?.length) {
        return stack[stack.length - 1];
      }
      if (direction === "back" && this.scrubSession?.active && this.scrubSession.originDescriptor) {
        return this.scrubSession.originDescriptor;
      }
      return null;
    }
    formatPrimaryLabel(detail, { allowRendererFallback = false, condensedOnly = false } = {}) {
      const derived = this.#derivePrimaryLabel(detail);
      if (derived) {
        const label = condensedOnly ? this.#condensePrimaryLabel(derived) : derived;
        if (!condensedOnly) {
          this.latestPrimaryLabel = label;
        }
        return label;
      }
      return "";
    }
    getPrimaryDisplayLabel(detail) {
      const label = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
      return label ?? "";
    }
    getPageEstimate(detail) {
      const metrics = this.#computePageMetrics(detail);
      if (!metrics) return null;
      const current = typeof metrics.currentPageNumber === "number" ? metrics.currentPageNumber : null;
      const total = typeof metrics.totalPages === "number" ? metrics.totalPages : null;
      if (current == null && total == null) return null;
      return { current, total };
    }
    getLocationTotalHint() {
      return this.lastKnownLocationTotal ?? this.lastPrimaryLabelDiagnostics?.locationTotal ?? null;
    }
    getScrubberFraction(detail = null) {
      if (detail) {
        const metrics = this.#computePageMetrics(detail);
        const computed = this.lastScrubberFraction ?? this.#scrubberFractionFromMetrics({
          current: metrics?.currentPageNumber,
          total: metrics?.totalPages,
          fallbackFraction: typeof detail.fraction === "number" ? detail.fraction : null
        });
        if (computed != null) {
          this.lastScrubberFraction = computed;
        }
        return computed;
      }
      return this.lastScrubberFraction;
    }
    #scrubberFractionFromMetrics({ current, total, fallbackFraction }) {
      if (typeof total === "number" && total > 1 && typeof current === "number") {
        const clampedCurrent = Math.max(1, Math.min(total, current));
        const numerator = clampedCurrent - 1;
        return Math.max(0, Math.min(1, numerator / (total - 1)));
      }
      if (typeof fallbackFraction === "number" && isFinite(fallbackFraction)) {
        return Math.max(0, Math.min(1, fallbackFraction));
      }
      return null;
    }
    #derivePrimaryLabel(detail) {
      if (!detail) {
        this.lastPrimaryLabelDiagnostics = {
          source: "no-detail",
          label: "",
          totalPageCount: this.totalPageCount
        };
        return null;
      }
      const metrics = this.#computePageMetrics(detail);
      if (metrics?.currentPageNumber != null) {
        const currentPageNumber = metrics.currentPageNumber;
        const totalPages = metrics.totalPages;
        const label = totalPages != null ? `Page ${currentPageNumber} of ${totalPages}` : `Page ${currentPageNumber}`;
        this.lastPrimaryLabelDiagnostics = {
          source: "page-metrics",
          label,
          currentPageNumber,
          totalPages,
          totalPageCount: this.totalPageCount
        };
        this.latestPrimaryLabel = label;
        return label;
      }
      this.latestPrimaryLabel = "";
      this.lastPrimaryLabelDiagnostics = {
        source: "no-page-metrics",
        label: "",
        totalPageCount: this.totalPageCount
      };
      return null;
    }
    #condensePrimaryLabel(label) {
      if (typeof label !== "string") return "";
      const pageMatch = label.match(/\bPage\s*(\d+)/i);
      if (pageMatch) {
        return `Page ${pageMatch[1]}`.replace(/\s+/g, " ").trim();
      }
      const trimmed = label.replace(/\s*of\s+.*$/i, "").trim();
      return trimmed || label;
    }
    #computePageMetrics(detail) {
      if (!detail) return null;
      const fraction = typeof detail.fraction === "number" ? detail.fraction : null;
      const pageItem = detail.pageItem ?? null;
      const pageItemLabel = typeof pageItem?.label === "string" ? pageItem.label : null;
      const pageItemKey = pageItem ? ensurePageKey(pageItem) : null;
      const pageIndex = this.#resolvePageIndex(pageItem);
      const sectionIndex = typeof detail.sectionIndex === "number" ? detail.sectionIndex : typeof detail.index === "number" ? detail.index : null;
      const locationCurrent = typeof detail.location?.current === "number" ? detail.location.current : null;
      const locationTotal = typeof detail.location?.total === "number" ? detail.location.total : null;
      const detailPageNumber = typeof detail.pageNumber === "number" ? detail.pageNumber : null;
      const detailPageCount = typeof detail.pageCount === "number" ? detail.pageCount : null;
      const totalPagesRaw = this.#currentTotalPages(detail, detailPageCount);
      const approxIndexFromFraction = this.#pageIndexFromFraction(fraction, detailPageCount ?? totalPagesRaw);
      const locationIndex = locationCurrent != null ? locationCurrent : null;
      const rendererIndex = this.#rendererSnapshotIndex();
      const detailIndex = detailPageNumber != null ? detailPageNumber - 1 : null;
      const candidateIndex = [detailIndex, pageIndex, rendererIndex, approxIndexFromFraction, locationIndex].find((index) => typeof index === "number" && index >= 0);
      const sectionPageNumber = candidateIndex != null ? candidateIndex + 1 : null;
      if (sectionIndex != null && detailPageCount != null) {
        this.sectionPageCounts.set(sectionIndex, detailPageCount);
        logFix("pagecount:section:set", {
          sectionIndex,
          pageCount: detailPageCount,
          totalTracked: this.sectionPageCounts.size
        });
      }
      const sectionOffset = sectionIndex != null ? this.#sectionOffset(sectionIndex) : 0;
      const sectionsTotal = this.sectionPageCounts.size > 0 ? Array.from(this.sectionPageCounts.values()).reduce((acc, value) => acc + (typeof value === "number" && value > 0 ? value : 0), 0) : null;
      const adjustedCurrent = sectionPageNumber != null ? sectionPageNumber + sectionOffset : null;
      const adjustedTotal = totalPagesRaw != null ? totalPagesRaw : sectionOffset + (detailPageCount ?? 0) || null;
      logFix("pagemetrics", {
        sectionIndex,
        sectionOffset,
        sectionPageNumber,
        sectionPageCount: detailPageCount,
        detailPageNumber,
        detailPageCount,
        totalPagesRaw,
        adjustedCurrent,
        adjustedTotal,
        candidateIndex,
        fraction
      });
      const diag = {
        fraction,
        pageItemKey,
        pageItemLabel,
        pageIndexFromItem: pageIndex,
        approxIndexFromFraction,
        locationCurrent,
        locationTotal,
        candidateIndex,
        sectionIndex,
        sectionOffset,
        sectionPageNumber,
        sectionPageCount: detailPageCount,
        detailPageNumber,
        detailPageCount,
        totalPageCount: this.totalPageCount,
        fallbackTotalPageCount: this.fallbackTotalPageCount,
        hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
        rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
        effectiveTotalPages: adjustedTotal ?? null,
        totalSource: this.lastTotalSource ?? null,
        currentPageNumber: adjustedCurrent ?? null,
        totalPages: adjustedTotal ?? null
      };
      const scrubFraction = this.#scrubberFractionFromMetrics({
        current: adjustedCurrent,
        total: adjustedTotal,
        fallbackFraction: fraction
      });
      if (scrubFraction != null) {
        this.lastScrubberFraction = scrubFraction;
      }
      this.#logPageMetrics({
        fraction: fraction != null ? Number(fraction.toFixed(6)) : null,
        pageItemKey,
        pageItemLabel,
        pageIndexFromItem: pageIndex,
        approxIndexFromFraction,
        locationIndex: locationCurrent,
        rendererIndex,
        candidateIndex,
        sectionIndex,
        sectionOffset,
        currentPageNumber: adjustedCurrent,
        totalPages: adjustedTotal,
        totalPageCount: this.totalPageCount,
        rendererTotal: this.rendererPageSnapshot?.total ?? null,
        fallbackTotalPageCount: this.fallbackTotalPageCount,
        sectionsTotal,
        locationTotal,
        detailPageNumber,
        detailPageCount,
        totalSource: this.lastTotalSource ?? null,
        hideNavigationDueToScroll: this.hideNavigationDueToScroll
      });
      return {
        currentPageNumber: adjustedCurrent,
        totalPages: adjustedTotal,
        pageItemLabel,
        diag
      };
    }
    #toggleCompletionStack(forceShow) {
      const shouldShow = typeof forceShow === "boolean" ? forceShow : !!(this.navContext?.showingFinish || this.navContext?.showingRestart);
      if (this.completionStack) {
        this.completionStack.hidden = !shouldShow;
        this.completionStack.style.display = shouldShow ? "" : "none";
      }
      const fadeTargets = [
        this.navRelocateButtons?.back,
        this.navRelocateButtons?.forward,
        this.navSectionLabels?.leading,
        this.navSectionLabels?.trailing,
        this.navPrimaryText,
        this.navPrimaryPercent
      ].filter(Boolean);
      fadeTargets.forEach((el) => {
        if (shouldShow) {
          el.classList.add("nav-fade-out");
        } else {
          el.classList.remove("nav-fade-out");
        }
      });
      if (this.navPrimaryText) {
        this.navPrimaryText.hidden = shouldShow;
        if (shouldShow) {
          this.navPrimaryText.setAttribute("aria-hidden", "true");
        } else {
          this.navPrimaryText.removeAttribute("aria-hidden");
        }
      }
      if (this.navPrimaryPercent) {
        if (shouldShow) {
          this.navPrimaryPercent.hidden = true;
          this.navPrimaryPercent.setAttribute("aria-hidden", "true");
        } else {
          const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
          this.#updateCompactPercent(descriptor);
        }
      }
    }
    async #updateSectionProgress({ refreshSnapshot = true } = {}) {
      const leading = this.navSectionProgress?.leading;
      const trailing = this.navSectionProgress?.trailing;
      if (leading) leading.hidden = true;
      if (trailing) trailing.hidden = true;
      try {
        const pagesLeft = await this.#calculatePagesLeftInSection({ refreshSnapshot });
        const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
        if (this.hideNavigationDueToScroll || showingCompletion) return;
        const targetKey = this.isRTL ? "leading" : "trailing";
        const labelEdge = targetKey === "leading" ? "left" : "right";
        const forwardEdge = this.isRTL ? "left" : "right";
        const relocateDirection = labelEdge === forwardEdge ? "forward" : "back";
        if (this.#isRelocateButtonVisible(relocateDirection)) return;
        if (!pagesLeft || pagesLeft <= 0) return;
        const target = this.navSectionProgress?.[targetKey];
        if (!target) return;
        const label = pagesLeft === 1 ? "1 page left in chapter" : `${pagesLeft} pages left in chapter`;
        target.textContent = label;
        target.hidden = false;
        logEBookPageNumLimited2("ui:section-progress", {
          label,
          pagesLeft,
          target: targetKey,
          rendererCurrent: this.rendererPageSnapshot?.current ?? null,
          rendererTotal: this.rendererPageSnapshot?.total ?? null,
          hideNavigationDueToScroll: this.hideNavigationDueToScroll
        });
      } catch (error) {
        console.error("Failed to update section progress", error);
      }
    }
    async #calculatePagesLeftInSection({ refreshSnapshot = true } = {}) {
      const detail = this.lastRelocateDetail;
      if (detail?.scrolled === false) {
        const current = typeof detail.pageNumber === "number" ? detail.pageNumber : null;
        const total = typeof detail.pageCount === "number" ? detail.pageCount : null;
        if (current != null && current > 0 && total != null && total > 0) {
          return Math.max(0, total - current);
        }
      }
      if (refreshSnapshot) {
        await this.#refreshRendererSnapshot();
      }
      if (!this.rendererPageSnapshot || !this.rendererPageSnapshot.total || this.rendererPageSnapshot.total <= 0) return null;
      return Math.max(0, this.rendererPageSnapshot.total - this.rendererPageSnapshot.current);
    }
    #handleRelocateHistory(detail) {
      const descriptor = this.#makeLocationDescriptor(detail);
      if (!descriptor) return;
      const lastOrigin = this.scrubSession?.originDescriptor;
      if (this.scrubSession?.pendingCommit && lastOrigin && this.#isSameDescriptor(lastOrigin, descriptor)) {
        logFix("jumpback:skip-origin-relocate", {
          reason: detail?.reason ?? null,
          fraction: descriptor?.fraction ?? null
        });
        this.scrubSession.pendingCommit = false;
        this.currentLocationDescriptor = descriptor;
        return;
      }
      if (this.isProcessingRelocateJump) {
        this.currentLocationDescriptor = descriptor;
        this.#finalizePendingRelocateJump(descriptor);
        if (this.isProcessingRelocateJump || this.pendingRelocateJump) {
          this.#logJumpBack("relocate-finalize-pending", {
            pending: !!this.pendingRelocateJump,
            descriptorFraction: typeof descriptor?.fraction === "number" ? Number(descriptor.fraction.toFixed(6)) : null
          });
          return;
        }
      }
      const reason = (detail?.reason || "").toLowerCase();
      const liveScrollPhase = detail?.liveScrollPhase ?? null;
      const isLiveScrollReason = reason === "live-scroll";
      const isJumpReason = isLiveScrollReason || reason === "navigation";
      const isPageTurn = reason === "page";
      const previousDescriptor = this.currentLocationDescriptor;
      let descriptorChanged = previousDescriptor && !this.#isSameDescriptor(previousDescriptor, descriptor);
      const isScrubbing = !!this.scrubSession?.active;
      const originDescriptor = this.scrubSession?.originDescriptor;
      const originFraction = typeof this.scrubSession?.originFraction === "number" ? this.scrubSession.originFraction : null;
      const detailFraction = typeof detail?.fraction === "number" ? detail.fraction : null;
      const fractionMoved = originFraction != null && detailFraction != null && Math.abs(detailFraction - originFraction) > FRACTION_EPSILON;
      const descriptorDiffersFromOrigin = !!(isScrubbing && originDescriptor && descriptor && !this.#isSameDescriptor(originDescriptor, descriptor));
      const movedFromOrigin = isScrubbing && (fractionMoved || descriptorDiffersFromOrigin);
      if (!descriptorChanged && movedFromOrigin && previousDescriptor && descriptor) {
        descriptorChanged = true;
      }
      if (isScrubbing) {
        this.#trackScrubMovement({ descriptor, movedFromOrigin, detailFraction });
      }
      if (isJumpReason && descriptorChanged && !isLiveScrollReason) {
        if (!isScrubbing && previousDescriptor) {
          this.#pushBackStack(previousDescriptor);
          logFix("jumpback:push", {
            reason,
            liveScrollPhase,
            backDepth: this.relocateStacks.back.length,
            descriptorFraction: descriptor?.fraction ?? null,
            prevFraction: previousDescriptor?.fraction ?? null
          });
          logBug3("EBOOKJUMP", {
            event: "push",
            reason,
            backDepth: this.relocateStacks.back.length,
            forwardDepth: this.relocateStacks.forward.length,
            prevFraction: previousDescriptor?.fraction ?? null,
            newFraction: descriptor?.fraction ?? null
          });
        }
      } else if (isPageTurn && descriptorChanged && !isScrubbing && previousDescriptor) {
        this.#pushBackStack(previousDescriptor);
        logFix("jumpback:push:pageturn", {
          reason,
          backDepth: this.relocateStacks.back.length,
          descriptorFraction: descriptor?.fraction ?? null,
          prevFraction: previousDescriptor?.fraction ?? null,
          sectionIndex: detail?.sectionIndex ?? null
        });
        logBug3("EBOOKJUMP", {
          event: "push-pageturn",
          reason,
          backDepth: this.relocateStacks.back.length,
          forwardDepth: this.relocateStacks.forward.length,
          prevFraction: previousDescriptor?.fraction ?? null,
          newFraction: descriptor?.fraction ?? null,
          sectionIndex: detail?.sectionIndex ?? null
        });
      } else if (!isScrubbing && descriptorChanged) {
        this.relocateStacks.forward.length = 0;
        this.#logStackSnapshot("forward-clear");
      }
      this.#logJumpDiagnostic("relocate-history", {
        reason,
        isJumpReason,
        descriptorChanged,
        backDepth: this.relocateStacks.back.length,
        forwardDepth: this.relocateStacks.forward.length,
        scrubbing: isScrubbing,
        movedFromOrigin,
        hiddenDueToScroll: this.hideNavigationDueToScroll,
        liveScrollPhase
      });
      this.currentLocationDescriptor = descriptor;
      this.#maybeCommitPendingScrub(detail, descriptor);
    }
    #trackScrubMovement({ descriptor, movedFromOrigin, detailFraction }) {
      const session = this.scrubSession;
      if (!session || !session.active) return;
      if (!session.originDescriptor && descriptor) {
        session.originDescriptor = this.#cloneDescriptor(descriptor);
        if (session.originFraction == null && typeof descriptor?.fraction === "number") {
          session.originFraction = descriptor.fraction;
        }
        logFix("scrub:origin-set", {
          originFraction: session.originFraction ?? null,
          descriptorFraction: descriptor?.fraction ?? null
        });
      }
      const fractionFromDescriptor = typeof descriptor?.fraction === "number" ? descriptor.fraction : null;
      const previewFraction = fractionFromDescriptor ?? detailFraction ?? null;
      if (movedFromOrigin) {
        session.hasMoved = true;
        this.#logPageScrub("update", {
          fraction: previewFraction,
          originFraction: session.originFraction ?? null,
          movedFromOrigin
        });
      }
    }
    #pushBackStack(descriptor, { stripCFI = false } = {}) {
      if (!descriptor) return null;
      const entry = this.#cloneDescriptor(descriptor);
      if (!entry) return null;
      if (stripCFI) {
        entry.cfi = null;
      }
      const backStack = this.relocateStacks.back;
      backStack.push(entry);
      const index = backStack.length - 1;
      if (backStack.length > MAX_RELOCATE_STACK) {
        backStack.shift();
        this.#logPageScrub("pop", { index: 0, reason: "truncate" });
      }
      this.relocateStacks.forward.length = 0;
      this.#logPageScrub("stack", {
        action: "push",
        index,
        fraction: entry.fraction ?? null
      });
      this.#logJumpDiagnostic("relocate-stack-push", {
        backDepth: backStack.length,
        forwardDepth: this.relocateStacks.forward.length,
        hiddenDueToScroll: this.hideNavigationDueToScroll
      });
      logBug3("EBOOKJUMP", {
        event: "stack-push",
        index,
        backDepth: backStack.length,
        forwardDepth: this.relocateStacks.forward.length,
        fraction: entry.fraction ?? null
      });
      this.#logStackSnapshot("push");
      return { entry, index };
    }
    #makeLocationDescriptor(detail) {
      if (!detail) return null;
      const locCurrent = typeof detail?.location?.current === "number" ? detail.location.current : null;
      const locTotal = typeof detail?.location?.total === "number" ? detail.location.total : null;
      const location = locCurrent != null || locTotal != null ? { current: locCurrent, total: locTotal } : null;
      const locationTotalHint = locTotal != null ? locTotal : this.lastKnownLocationTotal ?? null;
      return {
        cfi: detail.cfi ?? null,
        fraction: typeof detail.fraction === "number" ? detail.fraction : null,
        pageItemKey: detail.pageItem ? ensurePageKey(detail.pageItem) : null,
        pageLabel: typeof detail.pageItem?.label === "string" ? detail.pageItem.label : null,
        location,
        locationTotalHint
      };
    }
    #descriptorFromFraction(fraction) {
      if (typeof fraction !== "number" || !isFinite(fraction)) return null;
      const locTotal = this.lastKnownLocationTotal ?? this.lastPrimaryLabelDiagnostics?.locationTotal ?? null;
      const hasTotal = typeof locTotal === "number" && locTotal > 0;
      const clampedTotal = hasTotal ? Math.max(1, locTotal) : null;
      const location = hasTotal ? {
        total: clampedTotal,
        current: Math.round(Math.max(0, Math.min(1, fraction)) * (clampedTotal - 1))
      } : null;
      return {
        cfi: null,
        fraction,
        pageItemKey: null,
        pageLabel: null,
        location,
        locationTotalHint: hasTotal ? clampedTotal : null
      };
    }
    #cloneDescriptor(descriptor) {
      if (!descriptor) return null;
      return {
        cfi: descriptor.cfi ?? null,
        fraction: typeof descriptor.fraction === "number" ? descriptor.fraction : null,
        pageItemKey: descriptor.pageItemKey ?? null,
        pageLabel: descriptor.pageLabel ?? null,
        location: descriptor.location ? { ...descriptor.location } : null,
        locationTotalHint: typeof descriptor.locationTotalHint === "number" ? descriptor.locationTotalHint : null
      };
    }
    #requestRendererPrimaryLine() {
      return;
    }
    #normalizeRendererPageInfo(rawPage, rawTotal, renderer) {
      if (rawPage == null && rawTotal == null) return null;
      const numericPage = Number(rawPage);
      const numericTotal = Number(rawTotal);
      let total = Number.isFinite(numericTotal) ? Math.max(1, Math.round(numericTotal)) : null;
      const currentBase = Number.isFinite(numericPage) ? Math.max(1, Math.round(numericPage)) : 1;
      const current = total ? Math.max(1, Math.min(total, currentBase)) : currentBase;
      if (!Number.isFinite(current)) return null;
      const scrolled = renderer?.scrolled ?? null;
      const isPaginated = renderer && scrolled === false;
      const snapshotBeforeAdjust = {
        rawPage,
        rawTotal,
        numericPage,
        numericTotal,
        totalBase: total,
        currentBase,
        clampedCurrent: current,
        scrolled,
        rtl: renderer?.isRTL ?? renderer?.bookDir === "rtl" ?? null
      };
      const shouldAdjustForSentinels = MANABI_NAV_SENTINEL_ADJUST_ENABLED && isPaginated && total && total > 2;
      if (shouldAdjustForSentinels) {
        const textTotal = Math.max(1, total - 2);
        const textCurrent = Math.max(1, Math.min(textTotal, current));
        logEBookPageNumLimited2("nav:normalize:calc", {
          ...snapshotBeforeAdjust,
          mode: "text-only",
          textCurrent,
          textTotal,
          returnedCurrent: textCurrent,
          returnedTotal: textTotal
        });
        return {
          current: textCurrent,
          total: textTotal,
          rawCurrent: current,
          rawTotal: total,
          scrolled
        };
      }
      logEBookPageNumLimited2("nav:normalize:calc", {
        ...snapshotBeforeAdjust,
        mode: "raw",
        returnedCurrent: current,
        returnedTotal: total
      });
      return {
        current,
        total,
        rawCurrent: current,
        rawTotal: total,
        scrolled
      };
    }
    #formatRendererPageLabel(info) {
      if (!info) return "";
      if (info.total && info.total > 0) {
        return `${info.current} of ${info.total}`;
      }
      return "";
    }
    async #refreshRendererSnapshot() {
      const renderer = this.getRenderer?.();
      if (!renderer || typeof renderer.page !== "function" || typeof renderer.pages !== "function") {
        return null;
      }
      try {
        const [pageResult, pagesResult] = await Promise.allSettled([renderer.page(), renderer.pages()]);
        if (pageResult.status !== "fulfilled" || pagesResult.status !== "fulfilled") {
          return null;
        }
        const normalized = this.#normalizeRendererPageInfo(pageResult.value, pagesResult.value, renderer);
        if (!normalized) return null;
        this.rendererPageSnapshot = normalized;
        this.#updateFallbackTotalPages(normalized.total);
        logEBookPageNumLimited2("nav:renderer-snapshot:inputs", {
          rawPage: pageResult.value,
          rawTotal: pagesResult.value,
          normalizedCurrent: normalized.current,
          normalizedTotal: normalized.total,
          rawCurrent: normalized.rawCurrent,
          rawTotal: normalized.rawTotal,
          isPaginated: renderer?.scrolled === false,
          scrolled: renderer?.scrolled ?? null,
          rtl: renderer?.isRTL ?? renderer?.bookDir === "rtl" ?? null,
          currentBase: normalized.rawCurrent,
          totalBase: normalized.rawTotal
        });
        this.#logPageNumberDiagnostic("renderer-snapshot", {
          rendererCurrent: normalized.current,
          rendererTotal: normalized.total,
          rawRendererCurrent: normalized.rawCurrent,
          rawRendererTotal: normalized.rawTotal
        });
        logEBookPageNumLimited2("nav:renderer-snapshot", {
          rawPage: pageResult.value,
          rawTotal: pagesResult.value,
          normalizedCurrent: normalized.current,
          normalizedTotal: normalized.total,
          rawCurrent: normalized.rawCurrent,
          rawTotal: normalized.rawTotal,
          scrolled: renderer?.scrolled ?? null,
          rtl: renderer?.isRTL ?? renderer?.bookDir === "rtl" ?? null,
          totalPageCount: this.totalPageCount,
          totalSource: this.lastTotalSource ?? null
        });
        return normalized;
      } catch (_error) {
        return null;
      }
    }
    #logPageNumberDiagnostic(event, payload = {}) {
      const base = {
        event,
        totalPageCount: this.totalPageCount,
        totalSource: this.lastTotalSource ?? null,
        ...payload
      };
      const cleaned = Object.fromEntries(Object.entries(base).filter(([, value]) => value !== void 0));
      const line = `# EBOOKPAGE ${JSON.stringify(cleaned)}`;
      try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
      } catch (_error) {
      }
      try {
        console.log(line);
      } catch (_error) {
      }
    }
    #logPageScrub(_event, _payload = {}) {
    }
    #logJumpDiagnostic(event, payload = {}) {
      const pageNumber = typeof this.lastPrimaryLabelDiagnostics?.currentPageNumber === "number" ? this.lastPrimaryLabelDiagnostics.currentPageNumber : null;
      const pageTotal = typeof this.lastPrimaryLabelDiagnostics?.totalPages === "number" ? this.lastPrimaryLabelDiagnostics.totalPages : null;
      const context = {
        timestamp: Date.now(),
        pageNumber,
        pageTotal,
        ...payload
      };
      const cleanedEntries = Object.entries(context).filter(([, value]) => value !== void 0 && value !== null);
      const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : "";
      const line = metadata ? `# EBOOKJUMP ${event} ${metadata}` : `# EBOOKJUMP ${event}`;
      try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
      } catch (error) {
      }
      try {
        console.log(line);
      } catch (error) {
      }
    }
    #isSameDescriptor(a2, b2) {
      if (!a2 || !b2) return false;
      if (a2.cfi && b2.cfi) return a2.cfi === b2.cfi;
      if (typeof a2.fraction === "number" && typeof b2.fraction === "number") {
        return Math.abs(a2.fraction - b2.fraction) < FRACTION_EPSILON;
      }
      return false;
    }
    #resolvePageIndex(pageItem) {
      if (!pageItem || !this.pageTargetIndexByKey) return null;
      const key = ensurePageKey(pageItem);
      if (!key) return null;
      return this.pageTargetIndexByKey.get(key) ?? null;
    }
    #pageIndexFromFraction(fraction, totalOverride) {
      const total = typeof totalOverride === "number" && totalOverride > 0 ? totalOverride : this.totalPageCount > 0 ? this.totalPageCount : null;
      if (typeof fraction !== "number" || !total) return null;
      const approx = Math.floor(fraction * total);
      return Math.max(0, Math.min(total - 1, approx));
    }
    #sanitizePageLabel(label) {
      if (typeof label !== "string") return "";
      const trimmed = label.trim();
      if (!trimmed) return "";
      if (trimmed.toLowerCase().startsWith("page ")) {
        const remainder = trimmed.slice(5).trim();
        if (remainder) return remainder;
      }
      return trimmed;
    }
    #pageNumberFromLabel(label) {
      if (typeof label !== "string") return "";
      const match = label.match(/(\d+)/);
      if (!match) return "";
      const normalized = match[1]?.replace(/^0+/, "") ?? "";
      return normalized || "0";
    }
    #rendererSnapshotIndex() {
      const scrolled = this.rendererPageSnapshot?.scrolled;
      if (scrolled !== false) return null;
      const current = this.rendererPageSnapshot?.current;
      if (typeof current !== "number") return null;
      return Math.max(0, current - 1);
    }
    #sectionOffset(sectionIndex) {
      if (sectionIndex == null || sectionIndex <= 0) return 0;
      let sum = 0;
      for (let i2 = 0; i2 < sectionIndex; i2 += 1) {
        const count = this.sectionPageCounts.get(i2);
        if (typeof count === "number" && count > 0) {
          sum += count;
        } else {
          break;
        }
      }
      return sum;
    }
    #hasCompleteSectionCounts() {
      if (!this.linearSectionCount || this.linearSectionCount <= 0) return false;
      let filled = 0;
      for (const idx of this.linearSectionIndexes) {
        if (this.sectionPageCounts.has(idx)) filled += 1;
      }
      return filled === this.linearSectionCount;
    }
    #currentTotalPages(detail, detailPageCount) {
      const candidates = [];
      if (this.totalPageCount > 0) {
        candidates.push({ source: "page-targets", total: this.totalPageCount });
      }
      if (this.sectionPageCounts.size > 0 && this.#hasCompleteSectionCounts()) {
        const sectionSum = Array.from(this.sectionPageCounts.values()).reduce((acc, value) => acc + (typeof value === "number" && value > 0 ? value : 0), 0);
        if (sectionSum > 0) {
          candidates.push({ source: "sections", total: sectionSum });
        }
      }
      if (typeof detailPageCount === "number" && detailPageCount > 0) {
        candidates.push({ source: "detail", total: detailPageCount });
      }
      const rendererTotal = typeof this.rendererPageSnapshot?.total === "number" ? this.rendererPageSnapshot.total : null;
      const rendererScrolled = this.rendererPageSnapshot?.scrolled ?? null;
      if (rendererTotal && rendererTotal > 0 && rendererScrolled === false) {
        candidates.push({ source: "renderer", total: rendererTotal });
      }
      const locationTotal = typeof detail?.location?.total === "number" ? detail.location.total : null;
      if (locationTotal && locationTotal > 0) {
        candidates.push({ source: "location", total: locationTotal });
      }
      if (typeof this.fallbackTotalPageCount === "number" && this.fallbackTotalPageCount > 0) {
        candidates.push({ source: "fallback", total: this.fallbackTotalPageCount });
      }
      if (!candidates.length) {
        this.lastTotalSource = null;
        return null;
      }
      const locationCandidate = candidates.find((candidate) => candidate.source === "location") ?? null;
      const pageBasedPrecedence = ["page-targets", "sections", "renderer", "detail", "fallback"];
      const bestPageBased = candidates.filter((candidate) => candidate.source !== "location").sort((a2, b2) => {
        const pa = pageBasedPrecedence.indexOf(a2.source);
        const pb = pageBasedPrecedence.indexOf(b2.source);
        if (pa !== pb) return pa - pb;
        return (b2.total ?? 0) - (a2.total ?? 0);
      })[0] ?? null;
      let best = bestPageBased ?? locationCandidate;
      const hasStructuredTotals = this.totalPageCount > 0 || this.#hasCompleteSectionCounts();
      const locationClearlyBeatsWeakPageTotals = !!locationCandidate && locationCandidate.total > 1 && (!bestPageBased || bestPageBased.total <= 1 || !hasStructuredTotals && bestPageBased.source === "fallback" && locationCandidate.total > bestPageBased.total);
      if (locationClearlyBeatsWeakPageTotals) {
        best = locationCandidate;
      }
      this.lastTotalSource = best?.source ?? null;
      if (best?.total && best.source !== "page-targets") {
        this.#updateFallbackTotalPages(best.total);
      }
      logBug3("total-pages-choice", {
        chosenSource: best?.source ?? null,
        chosenTotal: best?.total ?? null,
        candidates: candidates.map(({ source, total }) => ({ source, total })),
        sectionsComplete: this.#hasCompleteSectionCounts(),
        linearSectionCount: this.linearSectionCount ?? null
      });
      const summary = candidates.map(({ source, total }) => ({ source, total }));
      const changed = !this.lastTotalPagesSnapshot || this.lastTotalPagesSnapshot.source !== (best?.source ?? null) || this.lastTotalPagesSnapshot.total !== (best?.total ?? null) || this.lastTotalPagesSnapshot.candidateCount !== summary.length;
      if (changed) {
        logEBookPageNumLimited2("nav:total-pages-source", {
          chosenSource: best?.source ?? null,
          chosenTotal: best?.total ?? null,
          candidates: summary
        });
        this.lastTotalPagesSnapshot = {
          source: best?.source ?? null,
          total: best?.total ?? null,
          candidateCount: summary.length
        };
      }
      return best?.total ?? null;
    }
    #logPageMetrics(payload) {
      const epsilon = 1e-5;
      const prev = this.lastPageMetricsSnapshot;
      const hasChanged = !prev || prev.currentPageNumber !== payload.currentPageNumber || prev.totalPages !== payload.totalPages || prev.candidateIndex !== payload.candidateIndex || prev.totalSource !== payload.totalSource || prev.sectionOffset !== payload.sectionOffset || prev.sectionIndex !== payload.sectionIndex || (typeof payload.fraction === "number" && typeof prev?.fraction === "number" ? Math.abs(payload.fraction - prev.fraction) > epsilon : payload.fraction !== prev?.fraction);
      if (!hasChanged) return;
      this.lastPageMetricsSnapshot = {
        currentPageNumber: payload.currentPageNumber,
        totalPages: payload.totalPages,
        candidateIndex: payload.candidateIndex,
        totalSource: payload.totalSource ?? null,
        sectionOffset: payload.sectionOffset ?? null,
        sectionIndex: payload.sectionIndex ?? null,
        fraction: payload.fraction ?? null
      };
      logEBookPageNumLimited2("nav:page-metrics", payload);
    }
    #updateFallbackTotalPages(total) {
      if (typeof total !== "number" || total <= 0) return;
      if (!this.fallbackTotalPageCount || total > this.fallbackTotalPageCount) {
        this.fallbackTotalPageCount = total;
      }
    }
    // Public wrapper so external callers (e.g., scrubber live updates) can format labels without accessing private fields.
    labelForDescriptor(descriptor) {
      return this.#labelForDescriptor(descriptor);
    }
    #labelForDescriptor(descriptor) {
      if (!descriptor) return "";
      const derivedTotal = this.lastPrimaryLabelDiagnostics?.totalPages ?? this.lastPageMetricsSnapshot?.totalPages ?? this.fallbackTotalPageCount ?? (this.totalPageCount > 0 ? this.totalPageCount : null);
      if (typeof descriptor.fraction === "number" && derivedTotal && derivedTotal > 0) {
        const clampedTotal = Math.max(1, derivedTotal);
        const idx = Math.round(Math.max(0, Math.min(1, descriptor.fraction)) * (clampedTotal - 1));
        return `${idx + 1}`;
      }
      const currentPageNumber = this.lastPrimaryLabelDiagnostics?.currentPageNumber ?? this.lastPageMetricsSnapshot?.currentPageNumber ?? null;
      if (typeof currentPageNumber === "number" && currentPageNumber > 0) {
        return `${currentPageNumber}`;
      }
      return "";
    }
    #isRelocateButtonVisible(direction) {
      if (!direction) return false;
      const button = this.navRelocateButtons?.[direction];
      return !!(button && !button.hidden && !button.disabled);
    }
    #updateRelocateButtons() {
      const backStack = this.relocateStacks.back;
      const forwardStack = this.relocateStacks.forward;
      const backBtn = this.navRelocateButtons?.back;
      const forwardBtn = this.navRelocateButtons?.forward;
      const scrubbing = !!this.scrubSession?.active;
      const busy = !!this.isProcessingRelocateJump;
      const showBack = !this.hideNavigationDueToScroll && backStack.length > 0;
      const showForward = !this.hideNavigationDueToScroll && forwardStack.length > 0;
      const disableBack = busy || !showBack;
      const disableForward = busy || !showForward;
      if (backBtn) {
        backBtn.hidden = !showBack;
        backBtn.disabled = disableBack;
        if (disableBack) {
          backBtn.setAttribute("aria-disabled", "true");
        } else {
          backBtn.removeAttribute("aria-disabled");
        }
        if (!showBack) backBtn.setAttribute("aria-hidden", "true");
        else backBtn.removeAttribute("aria-hidden");
      }
      if (forwardBtn) {
        forwardBtn.hidden = !showForward;
        forwardBtn.disabled = disableForward;
        if (disableForward) {
          forwardBtn.setAttribute("aria-disabled", "true");
        } else {
          forwardBtn.removeAttribute("aria-disabled");
        }
        if (!showForward) forwardBtn.setAttribute("aria-hidden", "true");
        else forwardBtn.removeAttribute("aria-hidden");
      }
      const backLabelDescriptor = this.#descriptorForRelocateLabel("back");
      const forwardLabelDescriptor = this.#descriptorForRelocateLabel("forward");
      if (this.navRelocateLabels?.back) {
        this.navRelocateLabels.back.textContent = showBack ? this.#labelForDescriptor(backLabelDescriptor) : "";
      }
      if (this.navRelocateLabels?.forward) {
        this.navRelocateLabels.forward.textContent = showForward ? this.#labelForDescriptor(forwardLabelDescriptor) : "";
      }
      this.#updateSectionProgress();
      if (this.previousRelocateVisibility.back !== showBack) {
        this.previousRelocateVisibility.back = showBack;
        this.#logJumpDiagnostic("relocate-visibility", {
          direction: "back",
          visible: showBack,
          backDepth: backStack.length,
          hiddenDueToScroll: this.hideNavigationDueToScroll
        });
      }
      if (this.previousRelocateVisibility.forward !== showForward) {
        this.previousRelocateVisibility.forward = showForward;
        this.#logJumpDiagnostic("relocate-visibility", {
          direction: "forward",
          visible: showForward,
          forwardDepth: forwardStack.length,
          hiddenDueToScroll: this.hideNavigationDueToScroll
        });
      }
    }
    #serializeStack(stack) {
      if (!Array.isArray(stack) || !stack.length) {
        return [];
      }
      const LIMIT = 5;
      const total = stack.length;
      const tail = stack.slice(-LIMIT);
      return tail.map((entry, offset) => {
        const index = total - tail.length + offset;
        return {
          index,
          fraction: typeof entry?.fraction === "number" ? Number(entry.fraction.toFixed(6)) : null,
          pageKey: entry?.pageItemKey ?? null
        };
      });
    }
    #logStackSnapshot(reason, extra = {}) {
      this.#logJumpDiagnostic("relocate-stack-snapshot", {
        reason,
        backDepth: this.relocateStacks?.back?.length ?? 0,
        forwardDepth: this.relocateStacks?.forward?.length ?? 0,
        backStack: this.#serializeStack(this.relocateStacks?.back),
        forwardStack: this.#serializeStack(this.relocateStacks?.forward),
        scrubActive: !!this.scrubSession?.active,
        pendingCommit: !!this.pendingScrubCommit,
        ...extra
      });
    }
    #logRelocateDetail(_detail) {
    }
    #pruneBackStackIfReturnedToOrigin(detail) {
      if (!detail) return;
      const descriptor = this.#makeLocationDescriptor(detail);
      if (!descriptor) return;
      const reason = (detail.reason || "").toLowerCase();
      const isLiveScroll = reason === "live-scroll";
      const canPrune = !isLiveScroll && !this.scrubSession?.active;
      if (!canPrune) return;
      const backStack = this.relocateStacks.back;
      if (!backStack?.length) return;
      const lastEntry = backStack[backStack.length - 1];
      if (!lastEntry) return;
      if (!this.#isSameDescriptor(lastEntry, descriptor)) {
        return;
      }
      backStack.pop();
      this.#logPageScrub("pop", {
        index: backStack.length,
        reason: "returned-to-origin-after-scrub",
        descriptorFraction: typeof descriptor.fraction === "number" ? Number(descriptor.fraction.toFixed(6)) : null
      });
      this.#logStackSnapshot("returned-to-origin");
      this.#updateRelocateButtons();
    }
    #maybeCommitPendingScrub(detail, descriptor, { updateButtons = true } = {}) {
      if (!this.pendingScrubCommit) return false;
      const { origin, reason, scheduledAt, releaseDescriptor, releaseFraction } = this.pendingScrubCommit;
      const phase = detail?.liveScrollPhase ?? null;
      const canCommit = !detail || detail.reason !== "live-scroll" || phase === "settled";
      if (!canCommit) return false;
      let effectiveDescriptor = descriptor || releaseDescriptor || null;
      if (!origin || !effectiveDescriptor) {
        this.pendingScrubCommit = null;
        this.#logPageScrub("pending-commit-skipped", {
          reason: "missing-descriptor",
          releaseReason: reason ?? null
        });
        return false;
      }
      const shouldSkipForOrigin = this.#isSameDescriptor(origin, effectiveDescriptor) && !(typeof releaseFraction === "number" && typeof origin.fraction === "number" && Math.abs(releaseFraction - origin.fraction) > FRACTION_EPSILON);
      if (shouldSkipForOrigin) {
        this.pendingScrubCommit = null;
        this.#logPageScrub("pending-commit-skipped", {
          reason: "returned-to-origin",
          releaseReason: reason ?? null,
          descriptorFraction: typeof effectiveDescriptor?.fraction === "number" ? Number(effectiveDescriptor.fraction.toFixed(6)) : null
        });
        return false;
      }
      const result = this.#pushBackStack(origin, { stripCFI: true });
      if (result?.entry) {
        this.#logPageScrub("push", {
          index: result.index,
          fraction: result.entry?.fraction ?? null,
          reason: reason ?? "pending-commit",
          commitPhase: phase ?? null,
          elapsedMs: scheduledAt ? Date.now() - scheduledAt : null,
          stackDepth: this.relocateStacks?.back?.length ?? null
        });
        this.#logStackSnapshot("pending-commit", {
          commitReason: reason ?? "pending-commit"
        });
      }
      this.pendingScrubCommit = null;
      if (updateButtons) {
        this.#updateRelocateButtons();
      }
      return !!result?.entry;
    }
    #finalizePendingRelocateJump(descriptor) {
      const pending = this.pendingRelocateJump;
      if (!pending) {
        this.isProcessingRelocateJump = false;
        return;
      }
      const direction = pending.direction;
      if (!direction) {
        this.pendingRelocateJump = null;
        this.isProcessingRelocateJump = false;
        return;
      }
      const targetFraction = typeof descriptor?.fraction === "number" ? Number(descriptor.fraction.toFixed(6)) : null;
      const stack = this.relocateStacks?.[direction];
      if (stack?.length) {
        stack.pop();
      }
      const opposite = direction === "back" ? "forward" : "back";
      if (pending.preJumpDescriptor) {
        const entry = this.#cloneDescriptor(pending.preJumpDescriptor);
        if (entry) {
          entry.cfi = null;
          const oppStack = this.relocateStacks?.[opposite];
          if (oppStack) {
            oppStack.push(entry);
            if (oppStack.length > MAX_RELOCATE_STACK) {
              oppStack.shift();
            }
          }
        }
      }
      this.pendingRelocateJump = null;
      this.isProcessingRelocateJump = false;
      this.#logJumpBack("jump-finalized", {
        direction,
        targetFraction,
        backDepth: this.relocateStacks?.back?.length ?? 0,
        forwardDepth: this.relocateStacks?.forward?.length ?? 0
      });
      this.#logStackSnapshot("jump-finalized", {
        direction,
        targetFraction,
        backDepth: this.relocateStacks?.back?.length ?? 0,
        forwardDepth: this.relocateStacks?.forward?.length ?? 0
      });
      logBug3("EBOOKJUMP", {
        event: "jump-finalized",
        direction,
        targetFraction,
        backDepth: this.relocateStacks?.back?.length ?? 0,
        forwardDepth: this.relocateStacks?.forward?.length ?? 0
      });
      this.#updateRelocateButtons();
    }
    async #handleRelocateJump(direction) {
      this.#logJumpButton("tap", {
        direction,
        backDepth: this.relocateStacks?.back?.length ?? 0,
        forwardDepth: this.relocateStacks?.forward?.length ?? 0,
        hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        navHiddenClass: this.navBar?.classList?.contains?.("nav-hidden") ?? null,
        navHiddenScrollClass: this.navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? null,
        isProcessingRelocateJump: !!this.isProcessingRelocateJump
      });
      const stack = this.relocateStacks?.[direction];
      if (!stack?.length) {
        this.#logJumpBack("tap-ignored-empty", { direction });
        this.#logJumpButton("tap-ignored-empty", { direction });
        logBug3("EBOOKJUMP", { event: "tap-empty", direction });
        return;
      }
      if (this.hideNavigationDueToScroll) {
        this.#logJumpBack("tap-ignored-hidden", { direction });
        this.#logJumpButton("tap-ignored-hidden", { direction });
        logBug3("EBOOKJUMP", { event: "tap-hidden", direction });
        return;
      }
      if (this.pendingRelocateJump) {
        this.#logJumpBack("tap-ignored-pending", { direction });
        this.#logJumpButton("tap-ignored-pending", { direction });
        return;
      }
      const descriptor = this.#cloneDescriptor(stack[stack.length - 1]);
      if (!descriptor) {
        this.#logJumpBack("tap-ignored-nodescriptor", { direction });
        this.#logJumpButton("tap-ignored-nodescriptor", { direction });
        return;
      }
      const preJumpDescriptor = this.lastRelocateDetail ? this.#makeLocationDescriptor(this.lastRelocateDetail) : this.#cloneDescriptor(this.currentLocationDescriptor);
      const opposite = direction === "back" ? "forward" : "back";
      const oppositeStack = this.relocateStacks?.[opposite];
      this.pendingRelocateJump = {
        direction,
        targetDescriptor: descriptor,
        preJumpDescriptor
      };
      this.isProcessingRelocateJump = true;
      this.#updateRelocateButtons();
      const targetFraction = typeof descriptor?.fraction === "number" ? Number(descriptor.fraction.toFixed(6)) : null;
      this.#logJumpBack("tap", {
        direction,
        stackDepth: stack.length,
        targetFraction,
        oppositeDepth: oppositeStack?.length ?? 0,
        hiddenDueToScroll: this.hideNavigationDueToScroll
      });
      this.#logJumpButton("tap-valid", {
        direction,
        stackDepth: stack.length,
        targetFraction,
        oppositeDepth: oppositeStack?.length ?? 0,
        hiddenDueToScroll: this.hideNavigationDueToScroll
      });
      this.#logJumpDiagnostic("relocate-button", {
        direction,
        stackDepth: stack.length,
        hiddenDueToScroll: this.hideNavigationDueToScroll,
        targetFraction,
        oppositeDepth: oppositeStack?.length ?? 0
      });
      this.#logStackSnapshot("button-prejump", {
        direction,
        targetFraction
      });
      try {
        this.#logJumpBack("request", {
          direction,
          targetFraction,
          stackDepth: stack.length
        });
        this.#logJumpButton("request", {
          direction,
          targetFraction,
          stackDepth: stack.length
        });
        await this.onJumpRequest?.(descriptor);
        this.#logJumpBack("request-complete", {
          direction,
          targetFraction
        });
        this.#logJumpButton("request-complete", {
          direction,
          targetFraction
        });
      } catch (error) {
        console.error("Failed to navigate to saved location", error);
        this.#logJumpBack("error", {
          direction,
          message: error?.message ?? String(error)
        });
        this.#logJumpButton("error", {
          direction,
          message: error?.message ?? String(error)
        });
        this.pendingRelocateJump = null;
        this.isProcessingRelocateJump = false;
        this.#logStackSnapshot("button-error", { direction });
        this.#updateRelocateButtons();
      } finally {
        this.#logJumpBack("postjump", {
          direction,
          pending: !!this.pendingRelocateJump,
          processing: !!this.isProcessingRelocateJump
        });
        this.#logJumpButton("postjump", {
          direction,
          pending: !!this.pendingRelocateJump,
          processing: !!this.isProcessingRelocateJump
        });
        this.#logStackSnapshot("button-postjump", { direction });
      }
    }
  };

  // ebook-viewer.js
  var DEFAULT_RUBY_FONT_STACK = `'Hiragino Kaku Gothic ProN', 'Hiragino Sans', system-ui`;
  var logEBookPerf2 = (event, detail = {}) => ({ event, ...detail });
  var VIEWER_PAGE_NUM_WHITELIST = /* @__PURE__ */ new Set([
    "relocate",
    "relocate:label",
    "nav:set-page-targets"
  ]);
  var logFix2 = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      window.webkit?.messageHandlers?.print?.postMessage?.(`# EBOOKFIX1 ${JSON.stringify(payload)}`);
    } catch (_err) {
      try {
        console.log("# EBOOKFIX1", event, detail);
      } catch (_2) {
      }
    }
  };
  var logBug4 = (event, detail = {}) => {
    try {
      const payload = { event, ...detail };
      window.webkit?.messageHandlers?.print?.postMessage?.(`# BOOKBUG1 ${JSON.stringify(payload)}`);
    } catch (_err) {
      try {
        console.log("# BOOKBUG1", event, detail);
      } catch (_2) {
      }
    }
  };
  var EBOOK_HTML_MARKER = "\u82A5\u5DDD\u8CDE";
  var EBOOK_HTML_TARGET_HREFS = [
    "item/xhtml/title.xhtml",
    "item/xhtml/0001.xhtml"
  ];
  var EBOOK_HTML_VERBOSE_DUMP = false;
  var logEBookHTMLLine = (line) => {
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
      try {
        console.log(line);
      } catch (_2) {
      }
    }
  };
  var maybeLogEBookHTML = (stage, {
    href = null,
    mediaType = null,
    isCacheWarmer = null,
    html = null,
    force = false
  } = {}) => {
    if (typeof html !== "string") return false;
    const normalizedHref = typeof href === "string" ? href : "";
    const isTargetHref = EBOOK_HTML_TARGET_HREFS.some((fragment) => normalizedHref.includes(fragment));
    const hasMarker = html.includes(EBOOK_HTML_MARKER);
    if (!force && !hasMarker && !isTargetHref) return false;
    logEBookHTMLLine(`# EBOOKHTML ${JSON.stringify({
      stage,
      href,
      mediaType,
      isCacheWarmer,
      length: html.length,
      segmentCount: (html.match(/<manabi-segment(\s|>)/g) || []).length,
      hasMarker,
      isTargetHref,
      force
    })}`);
    if (EBOOK_HTML_VERBOSE_DUMP) {
      logEBookHTMLLine(`# EBOOKHTML stage=${stage} verboseDumpDisabled=false`);
      logEBookHTMLLine(html);
    }
    return true;
  };
  globalThis.manabiMaybeLogEBookHTML = maybeLogEBookHTML;
  var logNavHide3 = (event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
      try {
        console.log(line);
      } catch (_2) {
      }
    }
  };
  var MANABI_TRACKING_CACHE_HANDLER2 = globalThis.MANABI_TRACKING_CACHE_HANDLER || "trackingSizeCache";
  globalThis.MANABI_TRACKING_CACHE_HANDLER = MANABI_TRACKING_CACHE_HANDLER2;
  var getBookCacheKey = () => {
    try {
      return globalThis.reader?.view?.book?.id || new URL(globalThis.reader?.view?.ownerDocument?.defaultView?.location?.href || "").pathname || globalThis.reader?.view?.book?.dir || null;
    } catch (_2) {
      return null;
    }
  };
  var logEBookPageNum2 = (event, detail = {}) => {
    const verbose = !!globalThis.manabiPageNumVerbose;
    const allow = verbose || VIEWER_PAGE_NUM_WHITELIST.has(event);
    if (!allow) return;
    try {
      const payload = { event, ...detail };
      const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
      globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
      try {
        console.log("# EBOOKK PAGENUM fallback", event, detail, error);
      } catch (_2) {
      }
    }
  };
  var resolveSharedFontStylesheetURL = (doc, familyName) => {
    const targetFamily = familyName || "YuKyokasho";
    const referenceURL = doc?.location?.href || doc?.baseURI || globalThis.location?.href || "";
    if (!referenceURL) return null;
    try {
      const parsed = new URL(referenceURL);
      if (parsed.protocol !== "ebook:") return null;
      return `${parsed.protocol}//${parsed.host}/load/manabi-fonts.css?family=${encodeURIComponent(targetFamily)}`;
    } catch (_error) {
      return null;
    }
  };
  var ensureCustomFontsForDoc = async (doc) => {
    try {
      const root = doc?.documentElement;
      if (globalThis.manabiDisableCustomFonts === true) {
        if (root) {
          delete root.dataset.manabiFontPending;
          root.dataset.manabiFontReady = "skipped";
        }
        return false;
      }
      if (!doc?.head) return false;
      const horizontalFamily = globalThis.manabiHorizontalFontFamilyName || "YuKyokasho Yoko";
      const verticalFamily = globalThis.manabiVerticalFontFamilyName || "YuKyokasho";
      const writingDirection = globalThis.manabiEbookWritingDirection || "original";
      const shouldUseVertical = writingDirection === "vertical" || writingDirection === "original" && globalThis.manabiTrackingVertical === true;
      const targetFamily = shouldUseVertical ? verticalFamily : horizontalFamily;
      const stylesheetURL = resolveSharedFontStylesheetURL(doc, targetFamily);
      if (!stylesheetURL) return false;
      if (root) {
        root.dataset.manabiFontPending = "1";
        root.dataset.manabiFontReady = "0";
      }
      let style = doc.getElementById("manabi-custom-fonts-inline");
      if (!style) {
        style = doc.createElement("link");
        style.id = "manabi-custom-fonts-inline";
        style.rel = "stylesheet";
        doc.head.appendChild(style);
        logEBookPerf2("font-inline-insert", { family: targetFamily, mode: "same-scheme-link" });
      }
      if (style.dataset.manabiInjectedFontFamily !== targetFamily || style.href !== stylesheetURL) {
        style.href = stylesheetURL;
        style.dataset.manabiInjectedFontFamily = targetFamily;
      }
      const fontSet = doc.fonts;
      if (fontSet) {
        try {
          if (typeof fontSet.load === "function") {
            await fontSet.load("1em '" + targetFamily + "'");
          }
        } catch (_error) {
        }
        try {
          if (typeof fontSet.ready === "object" && fontSet.ready && typeof fontSet.ready.then === "function") {
            await fontSet.ready;
          }
        } catch (_error) {
        }
        const size = fontSet?.size ?? null;
        logEBookPerf2("fontset-ready-iframe", {
          status: fontSet?.status ?? "unknown",
          size,
          family: targetFamily
        });
      }
      if (root) {
        delete root.dataset.manabiFontPending;
        root.dataset.manabiFontReady = "1";
      }
      return true;
    } catch (_err) {
      try {
        const root = doc?.documentElement;
        if (root) {
          delete root.dataset.manabiFontPending;
          root.dataset.manabiFontReady = "0";
        }
      } catch (__error) {
      }
      return false;
    }
  };
  globalThis.manabiWaitForFontCSS = waitForFontCSSReady;
  globalThis.manabiEnsureCustomFonts = ensureCustomFontsForDoc;
  var MAX_ERROR_LENGTH = 4e3;
  var ERROR_TRUNCATION_SUFFIX = "...(truncated)";
  var clampErrorString = (value) => {
    if (value === null || value === void 0) return null;
    const text = String(value);
    if (text.length <= MAX_ERROR_LENGTH) return text;
    const headLength = Math.max(0, MAX_ERROR_LENGTH - ERROR_TRUNCATION_SUFFIX.length);
    return text.slice(0, headLength) + ERROR_TRUNCATION_SUFFIX;
  };
  var sanitizeErrorValue = (value) => {
    if (value === null || value === void 0) return null;
    const t2 = typeof value;
    if (t2 === "string" || t2 === "number" || t2 === "boolean") return clampErrorString(value);
    try {
      if (value instanceof Error) {
        return clampErrorString(value.stack || value.message || String(value));
      }
    } catch (_2) {
    }
    try {
      const name = value?.name;
      const message = value?.message;
      const code = value?.code;
      const stack = value?.stack;
      const parts = [];
      if (name) parts.push(String(name));
      if (message) parts.push(String(message));
      if (code !== void 0 && code !== null) parts.push(`code=${code}`);
      if (stack) parts.push(String(stack));
      if (parts.length) return clampErrorString(parts.join(" | "));
    } catch (_2) {
    }
    try {
      return clampErrorString(String(value));
    } catch (_2) {
      return "unknown-error";
    }
  };
  var postReaderOnError = (payload) => {
    try {
      window.webkit?.messageHandlers?.readerOnError?.postMessage?.(payload);
    } catch (_error) {
    }
  };
  window.onerror = function(msg, source, lineno, colno, error) {
    const safeMessage = sanitizeErrorValue(msg) ?? "Unknown error";
    const safeSource = sanitizeErrorValue(source);
    const safeError = sanitizeErrorValue(error);
    postReaderOnError({
      message: safeMessage,
      source: safeSource,
      lineno,
      colno,
      error: safeError
    });
  };
  window.onunhandledrejection = function(event) {
    const safeMessage = sanitizeErrorValue(event.reason?.message) ?? "Unhandled rejection";
    const safeError = sanitizeErrorValue(event.reason?.stack ?? event.reason);
    postReaderOnError({
      message: safeMessage,
      source: window.location.href,
      lineno: null,
      colno: null,
      error: safeError
    });
  };
  function forwardShadowErrors(root) {
    if (!root) return;
    root.addEventListener("error", (e2) => {
      const safeMessage = sanitizeErrorValue(e2.message || e2.error?.message) ?? "Shadow-DOM error";
      const safeError = sanitizeErrorValue(e2.error || e2);
      postReaderOnError({
        message: safeMessage,
        source: window.location.href,
        lineno: e2.lineno || 0,
        colno: e2.colno || 0,
        error: safeError
      });
    });
    root.addEventListener("unhandledrejection", (e2) => {
      const safeMessage = sanitizeErrorValue(e2.reason?.message) ?? "Shadow-DOM unhandled rejection";
      const safeError = sanitizeErrorValue(e2.reason?.stack ?? e2.reason);
      postReaderOnError({
        message: safeMessage,
        source: window.location.href,
        lineno: 0,
        colno: 0,
        error: safeError
      });
    });
  }
  var installFontDiagnostics = () => {
    try {
      const fontSet = document?.fonts;
      if (!fontSet?.addEventListener) return;
      const serializeFace = (face) => ({
        family: face?.family || null,
        weight: face?.weight || null,
        style: face?.style || null,
        stretch: face?.stretch || null,
        status: face?.status || null,
        display: face?.display || null
      });
      const logFaces = (event, faces) => {
        const arr = Array.from(faces ?? []).map(serializeFace);
        logEBookPerf2(event, {
          count: arr.length,
          status: fontSet.status,
          faces: arr
        });
      };
      fontSet.addEventListener("loading", (e2) => logFaces("fontset-loading", e2?.fontfaces));
      fontSet.addEventListener("loadingdone", (e2) => logFaces("fontset-loadingdone", e2?.fontfaces));
      fontSet.addEventListener("loadingerror", (e2) => logFaces("fontset-loadingerror", e2?.fontfaces));
      fontSet.ready?.then?.(() => {
        logEBookPerf2("fontset-ready", { status: fontSet.status, size: fontSet.size });
      }).catch(() => {
      });
    } catch (_error) {
    }
  };
  installFontDiagnostics();
  var pendingHideNavigationState = null;
  var navHideLock = false;
  var applyLocalHideNavigationDueToScroll = (shouldHide, source = "unknown") => {
    const appliedHide = !!shouldHide;
    pendingHideNavigationState = appliedHide;
    logNavHide3("apply-local", {
      requested: !!shouldHide,
      applied: appliedHide,
      source,
      hasReader: !!globalThis.reader
    });
    if (globalThis.reader?.setHideNavigationDueToScroll) {
      globalThis.reader.setHideNavigationDueToScroll(appliedHide, source);
      pendingHideNavigationState = null;
    }
  };
  globalThis.manabiSetHideNavigationDueToScroll = applyLocalHideNavigationDueToScroll;
  globalThis.manabiToggleReaderTableOfContents = () => {
    try {
      if (globalThis.reader?.toggleTableOfContents) {
        globalThis.reader.toggleTableOfContents();
      }
    } catch (error) {
      console.error("Failed to toggle table of contents", error);
    }
  };
  var updateNavHiddenClass = (shouldHide) => {
    try {
      const hide = !!shouldHide;
      document?.body?.classList.toggle("nav-hidden", hide);
      globalThis.reader?.navHUD?.setNavHiddenState?.(hide);
      const navPrimaryText = document.getElementById("nav-primary-text");
      if (navPrimaryText?.dataset) {
        navPrimaryText.dataset.labelVariant = hide ? "compact" : "full";
      }
    } catch (_error) {
    }
  };
  var postNavigationChromeVisibility2 = (shouldHide, { source, direction, scrubbing = false, ctx = null } = {}) => {
    navHideLock = false;
    const appliedHide = !!shouldHide;
    const payload = { requested: !!shouldHide, applied: appliedHide, source, direction, scrubbing, navHideLock };
    if (ctx && typeof ctx === "object") {
      payload.sectionIndex = ctx.sectionIndex ?? null;
      payload.fraction = ctx.fraction ?? null;
      payload.previousFraction = ctx.previousFraction ?? null;
      payload.reason = ctx.reason ?? null;
    }
    logNavHide3("nav-visibility", payload);
    logBug4("nav-visibility", payload);
    applyLocalHideNavigationDueToScroll(appliedHide, source ?? "nav-visibility");
    try {
      window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
        hideNavigationDueToScroll: appliedHide,
        source: source ?? null,
        direction: direction ?? null
      });
    } catch (error) {
      console.error("Failed to notify native navigation chrome visibility", error);
    }
    updateNavHiddenClass(appliedHide);
  };
  var makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    if (mediaType !== "application/xhtml+xml" && mediaType !== "text/html") {
      return text;
    }
    const shouldForceHTMLLogging = maybeLogEBookHTML("js.replaceText.requestRaw", {
      href,
      mediaType,
      isCacheWarmer,
      html: text
    });
    const contentLocation = globalThis.reader?.view?.ownerDocument?.defaultView?.top?.location?.href || globalThis.location?.href || "";
    const shouldFailOpenFast = contentLocation.includes("ui-test-page-turn.epub") || globalThis.manabiPageTurnInteractionDiagnostic === true;
    if (shouldFailOpenFast) {
      globalThis.manabiLoadEBookLastState = `replace-text-skip-original:${href}`;
      logEBookPerf2("replace-text-skip-original", {
        href,
        isCacheWarmer,
        mediaType,
        bodyLength: text?.length ?? 0
      });
      return text;
    }
    const replaceTextTimeoutMs = shouldFailOpenFast ? 1200 : 5e3;
    const headers = {
      "Content-Type": mediaType,
      "X-Replaced-Text-Location": href,
      "X-Content-Location": contentLocation
    };
    if (isCacheWarmer) {
      headers["X-Is-Cache-Warmer"] = "true";
    }
    const perfStart = typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : Date.now();
    logEBookPerf2("replace-text-request", {
      href,
      isCacheWarmer,
      mediaType,
      bodyLength: text?.length ?? 0
    });
    globalThis.manabiLoadEBookLastState = `replace-text-awaiting-response:${href}`;
    const response = await Promise.race([
      fetch("ebook://ebook/process-text", {
        method: "POST",
        mode: "cors",
        cache: "no-cache",
        headers,
        body: text
      }),
      timeoutPromise(replaceTextTimeoutMs, `replace-text-timeout:${href}`)
    ]);
    try {
      if (!response.ok) {
        throw new Error(`HTTP error, status = ${response.status}`);
      }
      globalThis.manabiLoadEBookLastState = `replace-text-response-ready:${href}`;
      const durationMs = typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() - perfStart : null;
      logEBookPerf2("replace-text-response", {
        href,
        isCacheWarmer,
        status: response.status,
        durationMs
      });
      globalThis.manabiLoadEBookLastState = `replace-text-decoding-response:${href}`;
      let html = await Promise.race([
        response.text(),
        timeoutPromise(5e3, `replace-text-response-body-timeout:${href}`)
      ]);
      globalThis.manabiLoadEBookLastState = `replace-text-response-decoded:${href}`;
      maybeLogEBookHTML("js.replaceText.responseProcessed", {
        href,
        mediaType,
        isCacheWarmer,
        html,
        force: shouldForceHTMLLogging
      });
      if (isCacheWarmer && html.replace) {
        html = html.replace(/<body\s/i, "<body data-is-cache-warmer='true' ");
      }
      return html;
    } catch (error) {
      const durationMs = typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() - perfStart : null;
      logEBookPerf2("replace-text-error", {
        href,
        isCacheWarmer,
        message: error?.message || String(error),
        durationMs
      });
      if (shouldFailOpenFast && String(error?.message || error).startsWith("replace-text-timeout:")) {
        globalThis.manabiLoadEBookLastState = `replace-text-fallback-original:${href}`;
        return text;
      }
      console.error("Error replacing text:", error);
      return text;
    }
  };
  var debounce2 = (fn2, delay) => {
    let timeout;
    let isLeadingInvoked = false;
    return function(...args) {
      const context = this;
      if (!timeout) {
        fn2.apply(context, args);
        isLeadingInvoked = true;
        timeout = setTimeout(() => {
          timeout = null;
          if (!isLeadingInvoked) {
            fn2.apply(context, args);
          }
        }, delay);
      } else {
        isLeadingInvoked = false;
      }
    };
  };
  var isZip = async (file) => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer());
    return arr[0] === 80 && arr[1] === 75 && arr[2] === 3 && arr[3] === 4;
  };
  var makeNativeSource = (url) => ({ kind: "native", url });
  var timeoutPromise = (ms, message) => new Promise((_2, reject) => {
    setTimeout(() => reject(new Error(message)), ms);
  });
  var makeNativeSourceURLQuery = (sourceURL) => `sourceURL=${encodeURIComponent(sourceURL)}`;
  var fetchNativeEntries = async (sourceURL) => {
    const response = await Promise.race([
      fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
          "X-Ebook-Source-URL": sourceURL
        }
      }),
      timeoutPromise(4e3, "native-entries-timeout")
    ]);
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(
        `# EBOOKFETCH entries status=${response.status} ok=${response.ok} source=${sourceURL}`
      );
    } catch (_err) {
    }
    if (!response.ok) {
      throw new Error(`Failed to load native EPUB entries: ${response.status}`);
    }
    const payload = await response.json();
    try {
      const count = Array.isArray(payload?.entries) ? payload.entries.length : -1;
      window.webkit?.messageHandlers?.print?.postMessage?.(
        `# EBOOKFETCH entries.json count=${count} source=${sourceURL}`
      );
    } catch (_err) {
    }
    return payload;
  };
  var fetchNativeEntryResponse = async (sourceURL, subpath) => {
    const response = await Promise.race([
      fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
          "X-Ebook-Source-URL": sourceURL
        }
      }),
      timeoutPromise(4e3, `native-entry-timeout:${subpath}`)
    ]);
    try {
      window.webkit?.messageHandlers?.print?.postMessage?.(
        `# EBOOKFETCH entry status=${response.status} ok=${response.ok} subpath=${subpath} source=${sourceURL}`
      );
    } catch (_err) {
    }
    if (!response.ok) {
      return null;
    }
    return response;
  };
  var readNativeEntryText = async (response, name) => {
    if (!response) return null;
    globalThis.manabiLoadEBookLastState = `native-loader-decoding-text:${name}`;
    const arrayBuffer = await Promise.race([
      response.arrayBuffer(),
      timeoutPromise(4e3, `native-entry-arraybuffer-timeout:${name}`)
    ]);
    globalThis.manabiLoadEBookLastState = `native-loader-arraybuffer-ready:${name}`;
    const charset = response.headers?.get?.("content-type")?.match(/charset=([^;]+)/i)?.[1]?.trim() || "utf-8";
    let decoder;
    try {
      decoder = new TextDecoder(charset);
    } catch (_err) {
      decoder = new TextDecoder("utf-8");
    }
    const text = decoder.decode(arrayBuffer);
    globalThis.manabiLoadEBookLastState = `native-loader-text-decoded:${name}`;
    return text;
  };
  var readNativeEntryBlob = async (response, name) => {
    if (!response) return null;
    globalThis.manabiLoadEBookLastState = `native-loader-decoding-blob:${name}`;
    const arrayBuffer = await Promise.race([
      response.arrayBuffer(),
      timeoutPromise(4e3, `native-entry-arraybuffer-timeout:${name}`)
    ]);
    globalThis.manabiLoadEBookLastState = `native-loader-arraybuffer-ready:${name}`;
    const mimeType = response.headers?.get?.("content-type") || "";
    const blob = new Blob([arrayBuffer], mimeType ? { type: mimeType } : void 0);
    globalThis.manabiLoadEBookLastState = `native-loader-blob-decoded:${name}`;
    return blob;
  };
  var makeNativeEpubLoader = async (url, isCacheWarmer) => {
    logFix2("nativeLoader:begin", {
      sourceURL: url,
      isCacheWarmer: !!isCacheWarmer
    });
    const { entries: rawEntries = [] } = await fetchNativeEntries(url);
    logFix2("nativeLoader:entries", {
      sourceURL: url,
      isCacheWarmer: !!isCacheWarmer,
      count: rawEntries.length
    });
    const entries = rawEntries.map((entry) => ({
      filename: entry.path,
      uncompressedSize: entry.size ?? 0
    }));
    const sizeMap = new Map(entries.map((entry) => [entry.filename, entry.uncompressedSize]));
    const entryNames = new Set(entries.map((entry) => entry.filename));
    const replaceText = makeReplaceText(isCacheWarmer);
    return {
      entries,
      loadText: async (name) => {
        if (!entryNames.has(name)) {
          logFix2("nativeLoader:missing-text-entry", {
            sourceURL: url,
            isCacheWarmer: !!isCacheWarmer,
            name
          });
          return null;
        }
        globalThis.manabiLoadEBookLastState = `native-loader-awaiting-text:${name}`;
        const response = await fetchNativeEntryResponse(url, name);
        globalThis.manabiLoadEBookLastState = `native-loader-text-ready:${name}`;
        return readNativeEntryText(response, name);
      },
      loadBlob: async (name) => {
        if (!entryNames.has(name)) {
          logFix2("nativeLoader:missing-blob-entry", {
            sourceURL: url,
            isCacheWarmer: !!isCacheWarmer,
            name
          });
          return null;
        }
        globalThis.manabiLoadEBookLastState = `native-loader-awaiting-blob:${name}`;
        const response = await fetchNativeEntryResponse(url, name);
        globalThis.manabiLoadEBookLastState = `native-loader-blob-ready:${name}`;
        return readNativeEntryBlob(response, name);
      },
      getSize: (name) => sizeMap.get(name) ?? 0,
      replaceText,
      sourceURL: url
    };
  };
  var makeZipLoader = async (file, isCacheWarmer) => {
    const {
      configure,
      ZipReader,
      BlobReader,
      TextWriter,
      BlobWriter
    } = await Promise.resolve().then(() => (init_zip(), zip_exports));
    configure({
      useWebWorkers: false
    });
    const reader = new ZipReader(new BlobReader(file));
    const entries = await reader.getEntries();
    const map = new Map(entries.map((entry) => [entry.filename, entry]));
    const load = (f2) => (name, ...args) => map.has(name) ? f2(map.get(name), ...args) : null;
    const loadText = load((entry) => entry.getData(new TextWriter()));
    const loadBlob = load((entry, type) => entry.getData(new BlobWriter(type)));
    const getSize = (name) => map.get(name)?.uncompressedSize ?? 0;
    const replaceText = makeReplaceText(isCacheWarmer);
    return {
      entries,
      loadText,
      loadBlob,
      getSize,
      replaceText
    };
  };
  var nextAnimationFrame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
  var waitForViewHostLayout = async (view, { timeoutMs = 2e3, requireNonZeroSize = true } = {}) => {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      const rect = view?.getBoundingClientRect?.() ?? null;
      const width = Number(rect?.width ?? 0);
      const height = Number(rect?.height ?? 0);
      const connected = !!view?.isConnected;
      if (connected && (!requireNonZeroSize || width > 0 && height > 0)) {
        return {
          ready: true,
          connected,
          width,
          height,
          waitedMs: Date.now() - startedAt
        };
      }
      await nextAnimationFrame();
    }
    const finalRect = view?.getBoundingClientRect?.() ?? null;
    return {
      ready: false,
      connected: !!view?.isConnected,
      width: Number(finalRect?.width ?? 0),
      height: Number(finalRect?.height ?? 0),
      waitedMs: Date.now() - startedAt
    };
  };
  var isCBZ = ({
    name,
    type
  }) => type === "application/vnd.comicbook+zip" || name.endsWith(".cbz");
  var isFBZ = ({
    name,
    type
  }) => type === "application/x-zip-compressed-fb2" || name.endsWith(".fb2.zip") || name.endsWith(".fbz");
  var setLoadStateForOwner = (owner, state) => {
    if (!owner || globalThis.reader === owner) {
      globalThis.manabiLoadEBookLastState = state;
    }
    return state;
  };
  var getView = async (source, isCacheWarmer, owner = null) => {
    let book;
    if (source?.kind === "native") {
      setLoadStateForOwner(owner, "getView-native-source");
      logFix2("getView:native-source", {
        sourceURL: source.url ?? null,
        isCacheWarmer: !!isCacheWarmer
      });
      setLoadStateForOwner(owner, "getView-native-importing-epub");
      const {
        EPUB: EPUB2
      } = await Promise.resolve().then(() => (init_epub(), epub_exports));
      setLoadStateForOwner(owner, "getView-native-awaiting-loader");
      const loader = await Promise.race([
        makeNativeEpubLoader(source.url, isCacheWarmer),
        new Promise((_2, reject) => {
          setTimeout(() => reject(new Error("native-loader-timeout")), 15e3);
        })
      ]);
      setLoadStateForOwner(owner, "getView-native-loader-ready");
      setLoadStateForOwner(owner, "getView-native-awaiting-book-init");
      book = await Promise.race([
        new EPUB2(loader).init(),
        new Promise((_2, reject) => {
          setTimeout(() => reject(new Error("native-book-init-timeout")), 15e3);
        })
      ]);
      setLoadStateForOwner(owner, "getView-native-book-ready");
      logFix2("getView:native-book-ready", {
        sourceURL: source.url ?? null,
        isCacheWarmer: !!isCacheWarmer,
        bookDir: book?.dir ?? null,
        hasPageList: Array.isArray(book?.pageList) && book.pageList.length > 0
      });
    } else if (source?.kind === "file" && source.file?.size) {
      const file = source.file;
      if (await isZip(file)) {
        const loader = await makeZipLoader(file, isCacheWarmer);
        if (isCBZ(file)) {
          throw new Error("File format not yet supported");
        } else if (isFBZ(file)) {
          throw new Error("File format not yet supported");
        } else {
          const {
            EPUB: EPUB2
          } = await Promise.resolve().then(() => (init_epub(), epub_exports));
          book = await new EPUB2(loader).init();
        }
      } else {
        throw new Error("File format not yet supported");
      }
    } else {
      throw new Error("File not found");
    }
    if (!book) throw new Error("File type not supported");
    setLoadStateForOwner(owner, "getView-native-pre-create-view");
    const view = document.createElement("foliate-view");
    setLoadStateForOwner(owner, "getView-native-view-created");
    logFix2("getView:view-created", {
      isCacheWarmer: !!isCacheWarmer,
      tagName: view?.tagName ?? null
    });
    view.dataset.isCache = isCacheWarmer;
    const readerStage = document.getElementById("reader-stage");
    setLoadStateForOwner(owner, "getView-native-pre-append-view");
    (isCacheWarmer ? document.body : readerStage || document.body).append(view);
    setLoadStateForOwner(owner, "getView-native-view-appended");
    logFix2("getView:view-appended", {
      isCacheWarmer: !!isCacheWarmer,
      parentTag: view.parentElement?.tagName ?? null,
      hasShadowRoot: !!view.shadowRoot
    });
    forwardShadowErrors(view.shadowRoot);
    if (isCacheWarmer) {
      view.style.display = "none";
      view.style.contain = "strict";
      view.style.position = "absolute";
      view.style.left = "-9001px";
      view.style.width = 0;
      view.style.height = 0;
      view.style.pointerEvents = "none";
    }
    await customElements.whenDefined("foliate-view");
    setLoadStateForOwner(owner, "getView-native-awaiting-layout");
    const layoutState = isCacheWarmer ? await waitForViewHostLayout(view, { timeoutMs: 500, requireNonZeroSize: false }) : await waitForViewHostLayout(view, { timeoutMs: 2500, requireNonZeroSize: true });
    logFix2("getView:view-layout-ready", {
      isCacheWarmer: !!isCacheWarmer,
      ready: layoutState.ready,
      connected: layoutState.connected,
      width: layoutState.width,
      height: layoutState.height,
      waitedMs: layoutState.waitedMs,
      parentTag: view.parentElement?.tagName ?? null,
      parentWidth: Number(view.parentElement?.getBoundingClientRect?.()?.width ?? 0),
      parentHeight: Number(view.parentElement?.getBoundingClientRect?.()?.height ?? 0)
    });
    setLoadStateForOwner(owner, "getView-native-pre-open-view");
    logFix2("getView:view-open-begin", {
      isCacheWarmer: !!isCacheWarmer,
      bookDir: book?.dir ?? null
    });
    try {
      await Promise.race([
        Promise.resolve(view.open(book, isCacheWarmer)),
        new Promise((_2, reject) => {
          setTimeout(() => reject(new Error("view-open-timeout")), 5e3);
        })
      ]);
    } catch (error) {
      logFix2("getView:view-open-error", {
        isCacheWarmer: !!isCacheWarmer,
        message: error?.message ?? String(error),
        hasRenderer: !!view?.renderer,
        hasDocument: !!view?.document
      });
      try {
        view.close?.();
      } catch (_error) {
      }
      try {
        view.remove?.();
      } catch (_error) {
      }
      throw error;
    }
    logFix2("getView:view-open-resolved", {
      isCacheWarmer: !!isCacheWarmer,
      hasRenderer: !!view?.renderer,
      hasDocument: !!view?.document,
      currentIndex: Number.isFinite(view?.renderer?.currentIndex) ? view.renderer.currentIndex : null
    });
    const paginator = view.shadowRoot?.querySelector("foliate-paginator");
    if (paginator?.shadowRoot) {
      const style = document.createElement("style");
      style.textContent = `
        #container {
        scrollbar-width: none !important;         /* Firefox */
        -ms-overflow-style: none !important;      /* IE/Edge */
        }
        #container::-webkit-scrollbar {
        display: none !important;                 /* WebKit (macOS/iOS) */
        width: 0 !important;
        height: 0 !important;
        }
        `;
      paginator.shadowRoot.appendChild(style);
      const sideNavWidth = 32;
      document.documentElement.style.setProperty("--side-nav-width", `${sideNavWidth}px`);
      const syncSideNavWidth = () => {
        const width = getComputedStyle(document.body).getPropertyValue("--side-nav-width").trim();
        if (view) {
          view.style.setProperty("--side-nav-width", width);
          if (view.renderer && typeof view.renderer.setSideNavWidth === "function") {
            view.renderer.setSideNavWidth(width);
          }
        }
      };
      window.addEventListener("resize", syncSideNavWidth);
      syncSideNavWidth();
    }
    return view;
  };
  var getCSSForBookContent = ({
    spacing,
    justify,
    hyphenate
  }) => `
@namespace epub "http://www.idpf.org/2007/ops";
html {
color-scheme: light dark;
cursor: inherit;
}
/* https://github.com/whatwg/html/issues/5426 */
@media (prefers-color-scheme: dark) {
a:link {
color: lightblue;
}
}
p, li, blockquote, dd {
line-height: ${spacing};
text-align: ${justify ? "justify" : "start"};
-webkit-hyphens: ${hyphenate ? "auto" : "manual"};
hyphens: ${hyphenate ? "auto" : "manual"};
-webkit-hyphenate-limit-before: 3;
-webkit-hyphenate-limit-after: 2;
-webkit-hyphenate-limit-lines: 2;
hanging-punctuation: allow-end last;
widows: 2;
}
/* prevent the above from overriding the align attribute */
[align="left"] { text-align: left; }
[align="right"] { text-align: right; }
[align="center"] { text-align: center; }
[align="justify"] { text-align: justify; }

pre {
white-space: pre-wrap !important;
}
aside[epub|type~="endnote"],
aside[epub|type~="footnote"],
aside[epub|type~="note"],
aside[epub|type~="rearnote"] {
display: none;
}

.manabi-tracking-section {
/*contain: initial !important;*/
contain: style layout !important;
}

body *:not([class^="manabi-"]):not(manabi-segment, manabi-segment *):not(manabi-container):not(manabi-sentence, manabi-sentence *):not(#manabi-tracking-section-subscription-preview-inline-notice) {
    font-family: inherit !important;
    font-weight: inherit !important;
    background: inherit !important;
    color: inherit !important;
    /* prevent height: 100% type values from breaking getBoundingClientRect layout in paginator */
    height: inherit !important;
}
body.reader-is-single-media-element-without-text *:not(.manabi-tracking-container *):not(manabi-segment *) {
max-height: 99vh;
}
/*
 reader-sentinel {
 position: relative;
 display: inline; /*-block;*/
 width: 4px !important;
 height: 4px !important;
 opacity: 1 !important;
 pointer-events: none !important;
 contain: strict;
 background: red !important;
 }
 */
reader-sentinel {
position: relative !important;
display: inline-block !important;
width: 0 !important;
height: 0 !important;
padding: 0 !important;
contain: strict !important;
pointer-events: none !important;
opacity: 0 !important;
vertical-align: bottom !important;
break-before: avoid !important;
break-after: avoid !important;
break-inside: avoid !important;
}
`;
  var $2 = document.querySelector.bind(document);
  var locales = "en";
  var percentFormat = new Intl.NumberFormat(locales, {
    style: "percent"
  });
  var SideNavChevronAnimator = class {
    #icons = {
      l: null,
      r: null
    };
    #hideTimers = {
      l: null,
      r: null
    };
    constructor() {
      this.#icons = {
        l: document.querySelector("#btn-scroll-left .icon"),
        r: document.querySelector("#btn-scroll-right .icon")
      };
    }
    #normalizeKey(key) {
      if (key === "l" || key === "left") return "l";
      if (key === "r" || key === "right") return "r";
      return null;
    }
    isHolding(key) {
      const k2 = this.#normalizeKey(key);
      if (!k2) return false;
      return !!this.#hideTimers[k2];
    }
    set({ leftOpacity = null, rightOpacity = null, holdMs = 0, fadeMs = 200 } = {}) {
      this.#apply("l", leftOpacity, holdMs, fadeMs);
      this.#apply("r", rightOpacity, holdMs, fadeMs);
    }
    flash(direction, { holdMs = 280, fadeMs = 200 } = {}) {
      const isLeft = direction === "left";
      this.set({
        leftOpacity: isLeft ? 1 : 0,
        rightOpacity: isLeft ? 0 : 1,
        holdMs,
        fadeMs
      });
    }
    reset() {
      ["l", "r"].forEach((key) => this.#fadeIcon(key, 0));
    }
    #apply(key, value, holdMs, fadeMs) {
      if (value == null) return;
      const icon = this.#icons[key];
      if (!icon) return;
      clearTimeout(this.#hideTimers[key]);
      this.#hideTimers[key] = null;
      const numeric = Number(value);
      const shouldHide = value === "" || !Number.isNaN(numeric) && numeric <= 0;
      if (shouldHide) {
        this.#fadeIcon(key, fadeMs);
        return;
      }
      const targetOpacity = Number.isNaN(numeric) ? 0 : Math.min(1, numeric);
      icon.style.transitionDuration = `${fadeMs}ms`;
      if (targetOpacity >= 1) {
        icon.classList.add("chevron-visible");
        icon.style.removeProperty("opacity");
      } else {
        icon.classList.remove("chevron-visible");
        icon.style.opacity = targetOpacity;
      }
      if (holdMs > 0) {
        this.#hideTimers[key] = setTimeout(() => this.#fadeIcon(key, fadeMs), holdMs);
      }
    }
    #fadeIcon(key, fadeMs = 200) {
      const icon = this.#icons[key];
      if (!icon) return;
      clearTimeout(this.#hideTimers[key]);
      this.#hideTimers[key] = null;
      icon.style.transitionDuration = `${fadeMs}ms`;
      icon.classList.remove("chevron-visible");
      icon.style.opacity = "0";
    }
  };
  var Reader = class {
    #allowForwardNavHide = false;
    #logScrubDiagnostic(_event, _payload = {}) {
    }
    #logChevronDiagnostic(_event, _payload = {}) {
    }
    #loadingTimeoutId = null;
    #show(btn, show = true) {
      if (show) {
        btn.hidden = false;
        btn.style.visibility = "visible";
        btn.style.display = "";
      } else {
        btn.hidden = true;
        btn.style.visibility = "hidden";
        btn.style.display = "none";
      }
    }
    setLoadingIndicator(visible) {
      logBug4("loading-indicator:set", {
        visible: !!visible,
        bodyHasLoading: document?.body?.classList?.contains?.("loading") ?? null
      });
      const indicator = document.getElementById("loading-indicator");
      if (indicator) indicator.classList.toggle("show", !!visible);
    }
    #tocView;
    #chevronAnimator = null;
    #progressSlider = null;
    #tickContainer = null;
    #progressScrubState = null;
    #handleProgressSliderPointerDown = (event) => {
      if (!this.#progressSlider) return;
      if (event.pointerType === "mouse" && event.button !== 0) return;
      if (this.#progressScrubState) {
        this.#finalizeProgressScrubSession({ cancel: true });
      }
      const originDescriptor = this.navHUD?.getCurrentDescriptor();
      const originFraction = originDescriptor?.fraction ?? Number(this.#progressSlider?.value ?? NaN);
      this.#progressSlider.setPointerCapture?.(event.pointerId);
      this.#progressScrubState = {
        pointerId: event.pointerId,
        pendingEnd: false,
        cancelRequested: false,
        timeoutId: null,
        releaseFraction: null,
        originDescriptor,
        originFraction: Number.isFinite(originFraction) ? originFraction : null
      };
      this.navHUD?.beginProgressScrubSession(originDescriptor);
      this.#logScrubDiagnostic("pointer-down", {
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        sliderValue: Number(this.#progressSlider?.value ?? NaN)
      });
    };
    #handleProgressSliderPointerUp = (event) => {
      if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
      this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
      this.#progressSlider?.releasePointerCapture?.(event.pointerId);
      this.#logScrubDiagnostic("pointer-up", {
        pointerId: event.pointerId,
        sliderValue: Number(this.#progressSlider?.value ?? NaN)
      });
      this.#requestProgressScrubEnd(false);
    };
    #handleProgressSliderPointerCancel = (event) => {
      if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
      this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
      this.#progressSlider?.releasePointerCapture?.(event.pointerId);
      this.#logScrubDiagnostic("pointer-cancel", {
        pointerId: event.pointerId,
        sliderValue: Number(this.#progressSlider?.value ?? NaN)
      });
      this.#requestProgressScrubEnd(true);
    };
    hasLoadedLastPosition = false;
    markedAsFinished = false;
    lastPercentValue = null;
    lastPageEstimate = null;
    lastKnownFraction = 0;
    jumpUnit = "percent";
    #jumpInput = null;
    #jumpButton = null;
    #jumpUnitSelect = null;
    style = {
      spacing: 1.4,
      justify: true,
      hyphenate: true
    };
    annotations = /* @__PURE__ */ new Map();
    annotationsByValue = /* @__PURE__ */ new Map();
    openSideBar() {
      $2("#dimming-overlay").classList.add("show");
      $2("#side-bar").classList.add("show");
      if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
        this.#tocView.setCurrentHref(this.view.renderer.tocItem.href);
      }
    }
    closeSideBar() {
      $2("#dimming-overlay").classList.remove("show");
      $2("#side-bar").classList.remove("show");
    }
    toggleTableOfContents() {
      const sideBar = document.getElementById("side-bar");
      if (!sideBar) return;
      if (sideBar.classList.contains("show")) {
        this.closeSideBar();
      } else {
        this.openSideBar();
      }
    }
    setHideNavigationDueToScroll(shouldHide, source = "unknown") {
      const allowSource = (/* @__PURE__ */ new Set([
        "scroll-toggle",
        "nav-visibility",
        "relocate",
        "relocate-force",
        "swipe-left",
        "swipe-right",
        "keyboard",
        "arrow",
        "side-nav",
        "tap",
        "unknown"
      ])).has(source);
      const canHide = !shouldHide || this.#allowForwardNavHide || allowSource;
      if (!canHide) {
        logNavHide3("reader:set-hide-blocked", {
          requested: !!shouldHide,
          source,
          allowForwardNavHide: this.#allowForwardNavHide,
          navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
        });
        logBug4("nav-hide-blocked", { reason: "gate", requestedHide: shouldHide, source });
        return;
      }
      if (shouldHide && this.#allowForwardNavHide) {
        this.#allowForwardNavHide = false;
      }
      if (!shouldHide) {
        this.#allowForwardNavHide = true;
        logNavHide3("reader:reset-hide-gate", {
          source,
          navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
        });
      }
      logNavHide3("reader:set-hide", {
        requested: !!shouldHide,
        applied: !!shouldHide,
        source,
        gateConsumed: shouldHide ? !this.#allowForwardNavHide : null,
        navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
      });
      logBug4("nav-hide-apply", { shouldHide, source, gateConsumed: !this.#allowForwardNavHide });
      this.navHUD?.setHideNavigationDueToScroll(shouldHide, source, this._lastRelocateContext ?? null);
      updateNavHiddenClass(shouldHide);
    }
    setNavHiddenState(shouldHide) {
      this.navHUD?.setNavHiddenState?.(shouldHide);
    }
    constructor() {
      this.navHUD = new NavigationHUD({
        formatPercent: (value) => percentFormat.format(value),
        getRenderer: () => this.view?.renderer,
        onJumpRequest: (descriptor) => this.#goToDescriptor(descriptor)
      });
      this.allowForwardNavHide = () => {
        this.#allowForwardNavHide = true;
      };
      this.#chevronAnimator = new SideNavChevronAnimator();
      this._lastRelocateSectionIndex = null;
      $2("#side-bar-close-button").addEventListener("click", () => {
        this.closeSideBar();
      });
      $2("#dimming-overlay").addEventListener("click", () => this.closeSideBar());
    }
    async open(source) {
      logFix2("reader.open:begin", {
        hasSource: !!source,
        pageURL: window.location.href
      });
      setLoadStateForOwner(this, "reader-open-begin");
      this.setLoadingIndicator(true);
      this.hasLoadedLastPosition = false;
      this.source = source;
      setLoadStateForOwner(this, "reader-open-awaiting-view");
      this.view = await getView(source, false, this);
      setLoadStateForOwner(this, "reader-open-view-ready");
      logFix2("reader.open:view-ready", {
        hasView: !!this.view,
        hasRenderer: !!this.view?.renderer,
        tagName: this.view?.tagName ?? null
      });
      if (typeof window.initialLayoutMode !== "undefined") {
        this.view.renderer.setAttribute("flow", window.initialLayoutMode);
        logFix2("reader.open:flow-set", {
          layoutMode: window.initialLayoutMode ?? null
        });
      }
      this.view.renderer.addEventListener("goTo", this.#onGoTo.bind(this));
      this.view.renderer.addEventListener("didDisplay", this.#onDidDisplay.bind(this));
      this.view.renderer.addEventListener("relocate", this.#onRendererRelocate.bind(this));
      this.view.addEventListener("load", this.#onLoad.bind(this));
      this.view.addEventListener("relocate", this.#onRelocate.bind(this));
      this._sideNavCooldownUntil = 0;
      const {
        book
      } = this.view;
      this.bookDir = book.dir || "ltr";
      this.isRTL = this.bookDir === "rtl";
      try {
        const line = `# EBOOKCHEVRON_VIEW bookDir=${this.bookDir} isRTL=${this.isRTL}`;
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
        console.log(line);
      } catch (_err) {
      }
      document.body.dir = this.bookDir;
      this.navHUD?.setIsRTL(this.isRTL);
      this.navHUD?.setPageTargets(book.pageList ?? []);
      this.view.renderer.setStyles?.(getCSSForBookContent(this.style));
      setLoadStateForOwner(this, "reader-open-configured");
      logFix2("reader.open:configured", {
        bookDir: this.bookDir ?? null,
        isRTL: !!this.isRTL,
        hasPageList: Array.isArray(book.pageList) && book.pageList.length > 0
      });
      $2("#nav-bar").style.visibility = "visible";
      this.buttons = {
        prev: document.getElementById("btn-prev-chapter"),
        next: document.getElementById("btn-next-chapter"),
        finish: document.getElementById("btn-finish"),
        restart: document.getElementById("btn-restart")
      };
      for (const btn of Object.values(this.buttons)) {
        btn && (btn.hidden = true);
      }
      if (this.isRTL) {
        const flipChevron = (btn, leftArrow) => {
          const path = btn.querySelector("path");
          if (path) {
            path.setAttribute("d", leftArrow ? "M 15 6 L 9 12 L 15 18" : "M 9 6 L 15 12 L 9 18");
          }
        };
        flipChevron(this.buttons.prev, false);
        flipChevron(this.buttons.next, true);
        const nextBtn = this.buttons.next;
        const nextLabel = nextBtn.querySelector(".button-label");
        const nextIcon = nextBtn.querySelector("svg");
        if (nextIcon && nextLabel && nextIcon !== nextLabel.previousSibling) {
          nextBtn.insertBefore(nextIcon, nextLabel);
        }
        const prevBtn = this.buttons.prev;
        const prevLabel = prevBtn.querySelector(".button-label");
        const prevIcon = prevBtn.querySelector("svg");
        if (prevIcon && prevLabel && prevLabel !== prevIcon.previousSibling) {
          prevBtn.insertBefore(prevLabel, prevIcon);
        }
        if (this.buttons.prev) {
          this.buttons.prev._spinnerAfterLabel = true;
        }
        if (this.buttons.next) {
          this.buttons.next._spinnerAfterLabel = false;
        }
      } else {
        if (this.buttons.prev) {
          this.buttons.prev._spinnerAfterLabel = false;
        }
        if (this.buttons.next) {
          this.buttons.next._spinnerAfterLabel = false;
        }
      }
      Object.values(this.buttons).forEach(
        (btn) => btn.addEventListener("click", this.#onNavButtonClick.bind(this))
      );
      const leftSideBtn = document.getElementById("btn-scroll-left");
      if (leftSideBtn) {
        const triggerNavLeft = async () => {
          const now = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
          if (now < this._sideNavCooldownUntil) return;
          this._sideNavCooldownUntil = now + 180;
          await this.view.goLeft();
        };
        leftSideBtn.addEventListener("click", async () => {
          logBug4("side-nav:click", { direction: "left" });
          logNavHide3("side-nav:click", {
            direction: "left",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          await triggerNavLeft();
        });
        leftSideBtn.addEventListener("pointerdown", async (e2) => {
          logBug4("side-nav:pointerdown", { direction: "left" });
          logNavHide3("side-nav:pointerdown", {
            direction: "left",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          e2.preventDefault();
          await triggerNavLeft();
        });
        leftSideBtn.addEventListener("pointerup", async () => {
          logBug4("side-nav:pointerup", { direction: "left" });
          logNavHide3("side-nav:pointerup", {
            direction: "left",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          await triggerNavLeft();
        });
      }
      const rightSideBtn = document.getElementById("btn-scroll-right");
      if (rightSideBtn) {
        const triggerNavRight = async () => {
          const now = typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
          if (now < this._sideNavCooldownUntil) return;
          this._sideNavCooldownUntil = now + 180;
          await this.view.goRight();
        };
        rightSideBtn.addEventListener("click", async () => {
          logBug4("side-nav:click", { direction: "right" });
          logNavHide3("side-nav:click", {
            direction: "right",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          await triggerNavRight();
        });
        rightSideBtn.addEventListener("pointerdown", async (e2) => {
          logBug4("side-nav:pointerdown", { direction: "right" });
          logNavHide3("side-nav:pointerdown", {
            direction: "right",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          e2.preventDefault();
          await triggerNavRight();
        });
        rightSideBtn.addEventListener("pointerup", async () => {
          logBug4("side-nav:pointerup", { direction: "right" });
          logNavHide3("side-nav:pointerup", {
            direction: "right",
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null
          });
          await triggerNavRight();
        });
      }
      const flashSideNav = (direction) => {
        this.view?.dispatchEvent(new CustomEvent("sideNavChevronOpacity", {
          detail: {
            leftOpacity: direction === "left" ? 1 : 0,
            rightOpacity: direction === "right" ? 1 : 0,
            holdMs: 180,
            fadeMs: 180,
            source: "button:pointer"
          }
        }));
      };
      leftSideBtn?.addEventListener("pointerdown", () => flashSideNav("left"));
      rightSideBtn?.addEventListener("pointerdown", () => flashSideNav("right"));
      document.querySelectorAll(".side-nav").forEach((nav) => {
        nav.addEventListener("touchstart", () => {
          nav.classList.add("pressed");
        }, {
          passive: true
        });
        nav.addEventListener("touchend", () => {
          nav.classList.remove("pressed");
        });
        nav.addEventListener("touchcancel", () => {
          nav.classList.remove("pressed");
        });
      });
      this.view.addEventListener("sideNavChevronOpacity", (e2) => {
        const detail = e2?.detail ?? {};
        const holdMs = typeof detail.holdMs === "number" ? detail.holdMs : 0;
        const fadeMs = typeof detail.fadeMs === "number" ? detail.fadeMs : 200;
        this.#chevronAnimator?.set({
          leftOpacity: detail.leftOpacity,
          rightOpacity: detail.rightOpacity,
          holdMs,
          fadeMs
        });
        this.#logChevronDiagnostic("chevron:event", {
          source: detail?.source ?? null,
          holdMs,
          fadeMs,
          left: detail.leftOpacity ?? null,
          right: detail.rightOpacity ?? null
        });
      });
      document.addEventListener("resetSideNavChevrons", () => this.#resetSideNavChevrons());
      const navBar = document.getElementById("nav-bar");
      const leftStack = document.getElementById("left-stack");
      const rightStack = document.getElementById("right-stack");
      const progressWrapper = document.getElementById("progress-wrapper");
      if (navBar && leftStack && rightStack && progressWrapper) {
        navBar.innerHTML = "";
        if (this.isRTL) {
          navBar.append(rightStack, progressWrapper, leftStack);
        } else {
          navBar.append(leftStack, progressWrapper, rightStack);
        }
      }
      const slider = $2("#progress-slider");
      this.#progressSlider = slider;
      this.#tickContainer = document.getElementById("progress-ticks");
      slider.dir = book.dir;
      const goToFractionImmediate = (e2) => {
        this.view.goToFraction(parseFloat(e2.target.value));
      };
      slider.addEventListener("input", goToFractionImmediate);
      slider.addEventListener("pointerdown", this.#handleProgressSliderPointerDown);
      slider.addEventListener("pointerup", this.#handleProgressSliderPointerUp);
      slider.addEventListener("pointercancel", this.#handleProgressSliderPointerCancel);
      this.book = book;
      const initialCounts = null;
      slider.style.setProperty("--value", slider.value);
      slider.style.setProperty("--min", slider.min == "" ? "0" : slider.min);
      slider.style.setProperty("--max", slider.max == "" ? "100" : slider.max);
      slider.addEventListener("input", () => slider.style.setProperty("--value", slider.value));
      const tickFractions = this.#computeSectionTicks(initialCounts);
      this.#renderSectionTicks(initialCounts, tickFractions);
      const percentInput = document.getElementById("percent-jump-input");
      const percentButton = document.getElementById("percent-jump-button");
      const jumpUnitSelect = document.getElementById("jump-unit-select");
      this.#jumpInput = percentInput;
      this.#jumpButton = percentButton;
      this.#jumpUnitSelect = jumpUnitSelect;
      this.jumpUnit = "percent";
      this.lastPageEstimate = null;
      this.#updateJumpUnitAvailability();
      this.#syncJumpInputWithState();
      const handleJumpInputChange = () => {
        const value = parseFloat(percentInput.value);
        percentButton.disabled = !this.#isJumpInputValueValid(value);
      };
      percentInput.addEventListener("input", handleJumpInputChange);
      jumpUnitSelect?.addEventListener("change", () => {
        this.jumpUnit = "percent";
        this.#syncJumpInputWithState();
        percentButton.disabled = true;
      });
      percentButton.addEventListener("click", () => {
        const value = parseFloat(percentInput.value);
        if (!this.#isJumpInputValueValid(value)) return;
        this.lastPercentValue = value;
        this.lastKnownFraction = value / 100;
        percentButton.disabled = true;
        this.view.goToFraction(value / 100);
        this.closeSideBar();
      });
      document.addEventListener("keydown", this.#handleKeydown.bind(this));
      const processTouchStart = function(event) {
        if (event.target && event.target.ownerDocument !== document) return;
        window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
          touchedEntryWithElementId: null,
          wasAlreadySelected: false
        });
      };
      document.addEventListener("touchstart", processTouchStart, {
        passive: true
      });
      document.addEventListener("mousedown", processTouchStart, {
        passive: true
      });
      const title = book.metadata?.title ?? "Untitled Book";
      document.title = title;
      $2("#side-bar-title").innerText = title;
      const author = book.metadata?.author;
      let authorText = typeof author === "string" ? author : author?.map((author2) => typeof author2 === "string" ? author2 : author2.name)?.join(", ") ?? "";
      $2("#side-bar-author").innerText = authorText;
      window.webkit.messageHandlers.pageMetadataUpdated.postMessage({
        "title": title,
        "author": authorText,
        "url": window.top.location.href
      });
      Promise.resolve(book.getCover?.())?.then((blob) => {
        blob ? $2("#side-bar-cover").src = URL.createObjectURL(blob) : null;
      });
      const toc = book.toc;
      if (toc) {
        this.#tocView = createTOCView(toc, async (href) => {
          await this.view.goTo(href).catch((e2) => console.error(e2));
          this.closeSideBar();
        });
        $2("#toc-view").append(this.#tocView.element);
      }
      setLoadStateForOwner(this, "reader-open-awaiting-calibre-bookmarks");
      const bookmarks = await book.getCalibreBookmarks?.();
      setLoadStateForOwner(this, "reader-open-calibre-bookmarks-ready");
      if (Array.isArray(bookmarks) && bookmarks.length > 0) {
        try {
          setLoadStateForOwner(this, "reader-open-awaiting-epubcfi-import");
          const {
            fromCalibreHighlight: fromCalibreHighlight2
          } = await Promise.race([
            Promise.resolve().then(() => (init_epubcfi(), epubcfi_exports)),
            new Promise((_2, reject) => {
              setTimeout(() => reject(new Error("epubcfi-import-timeout")), 3e3);
            })
          ]);
          setLoadStateForOwner(this, "reader-open-epubcfi-import-ready");
          for (const obj of bookmarks) {
            if (obj.type === "highlight") {
              const value = fromCalibreHighlight2(obj);
              const color = obj.style.which;
              const note = obj.notes;
              const annotation = {
                value,
                color,
                note
              };
              const list = this.annotations.get(obj.spine_index);
              if (list) list.push(annotation);
              else this.annotations.set(obj.spine_index, [annotation]);
              this.annotationsByValue.set(value, annotation);
            }
          }
        } catch (error) {
          setLoadStateForOwner(this, `reader-open-calibre-bookmarks-skip:${sanitizeErrorValue(error?.message ?? error)}`);
          logFix2("reader.open:calibre-bookmarks-skip", {
            message: error?.message ?? String(error),
            bookmarkCount: bookmarks.length
          });
        }
      }
      setLoadStateForOwner(this, "reader-open-complete");
      if (!this.hasLoadedLastPosition && this.view?.renderer?.firstSection) {
        try {
          setLoadStateForOwner(this, "reader-open-awaiting-initial-first-section");
          await Promise.race([
            this.view.renderer.firstSection(),
            new Promise((_2, reject) => {
              setTimeout(() => reject(new Error("initial-first-section-timeout")), 12e3);
            })
          ]);
          setLoadStateForOwner(this, "reader-open-initial-first-section-ready");
        } catch (error) {
          setLoadStateForOwner(this, `reader-open-initial-first-section-error:${sanitizeErrorValue(error?.message ?? error)}`);
          logFix2("reader.open:initial-first-section-error", {
            message: error?.message ?? String(error)
          });
        }
      }
    }
    async updateNavButtons() {
      document.querySelectorAll(".ispinner.nav-spinner").forEach((spinner) => {
        const btn = spinner.closest("button");
        if (btn && btn._originalIcon) {
          spinner.replaceWith(btn._originalIcon);
          delete btn._originalIcon;
        }
        const label = btn.querySelector(".button-label");
        if (label) label.style.visibility = "";
      });
      if (!this.view?.renderer) return;
      const r2 = this.view.renderer;
      const atSectionStart = typeof r2.isAtSectionStart === "function" ? await r2.isAtSectionStart() : false;
      const atSectionEnd = typeof r2.isAtSectionEnd === "function" ? await r2.isAtSectionEnd() : false;
      const hasPrevSection = typeof r2.getHasPrevSection === "function" ? await r2.getHasPrevSection() : true;
      const hasNextSection = typeof r2.getHasNextSection === "function" ? await r2.getHasNextSection() : true;
      const shouldShowPrev = atSectionStart && hasPrevSection;
      const shouldShowNext = atSectionEnd && hasNextSection;
      this.#show(this.buttons.prev, shouldShowPrev);
      if (shouldShowNext) {
        this.#show(this.buttons.next, true);
        this.#show(this.buttons.finish, false);
        this.#show(this.buttons.restart, false);
      } else if (atSectionEnd && !hasNextSection) {
        this.#show(this.buttons.next, false);
        if (this.markedAsFinished) {
          this.#show(this.buttons.restart, true);
          this.#show(this.buttons.finish, false);
        } else {
          this.#show(this.buttons.finish, true);
          this.#show(this.buttons.restart, false);
        }
      } else {
        this.#show(this.buttons.next, false);
        this.#show(this.buttons.finish, false);
        this.#show(this.buttons.restart, false);
      }
      this.#setForwardChevronHint(shouldShowNext);
      const btnScrollLeft = document.getElementById("btn-scroll-left");
      const btnScrollRight = document.getElementById("btn-scroll-right");
      if (btnScrollLeft && btnScrollRight) {
        if (this.isRTL) {
          btnScrollLeft.disabled = atSectionEnd && !hasNextSection;
          btnScrollRight.disabled = atSectionStart && !hasPrevSection;
        } else {
          btnScrollLeft.disabled = atSectionStart && !hasPrevSection;
          btnScrollRight.disabled = atSectionEnd && !hasNextSection;
        }
      }
      const restartBtn = this.buttons.restart;
      if (restartBtn) {
        const iconPath = restartBtn.querySelector("svg path");
        if (iconPath) {
          iconPath.setAttribute("d", "M13 3a9 9 0 1 0 9 9h-2a7 7 0 1 1-7-7v3l4-4-4-4v3z");
          iconPath.setAttribute("fill", "currentColor");
          iconPath.setAttribute("stroke", "none");
        }
      }
      this.navHUD?.setNavContext({
        atSectionStart,
        atSectionEnd,
        hasPrevSection,
        hasNextSection,
        showingFinish: this.#isButtonVisible(this.buttons.finish),
        showingRestart: this.#isButtonVisible(this.buttons.restart)
      });
    }
    #isButtonVisible(button) {
      if (!button) return false;
      return !button.hidden && button.style.display !== "none";
    }
    #setForwardChevronHint(shouldShow) {
      const forwardBtn = document.getElementById(this.isRTL ? "btn-scroll-left" : "btn-scroll-right");
      if (!forwardBtn) return;
      forwardBtn.classList.toggle("show-next", !!shouldShow);
      const icon = forwardBtn.querySelector(".icon");
      if (!icon) return;
      const isHovered = typeof forwardBtn.matches === "function" ? forwardBtn.matches(":hover") : false;
      const isHeld = this.#chevronAnimator?.isHolding(forwardBtn.id === "btn-scroll-left" ? "l" : "r") ?? false;
      this.#logChevronDiagnostic("chevron:forwardHint", {
        shouldShow,
        isHovered,
        isHeld,
        isPressed: forwardBtn.classList.contains("pressed"),
        iconVisible: icon.classList.contains("chevron-visible"),
        inlineOpacity: icon.style.opacity || null
      });
      if (shouldShow) {
        icon.classList.add("chevron-visible");
        icon.style.opacity = "1";
      } else if (!forwardBtn.classList.contains("pressed") && !isHovered && !isHeld) {
        icon.classList.remove("chevron-visible");
        icon.style.opacity = "";
      }
    }
    #flashChevron(left) {
      this.#logChevronDiagnostic("chevron:flash", { direction: left ? "left" : "right" });
      this.view.dispatchEvent(new CustomEvent("sideNavChevronOpacity", {
        detail: {
          leftOpacity: left ? 1 : 0,
          rightOpacity: left ? 0 : 1,
          holdMs: 260,
          fadeMs: 200,
          source: "keyboard"
        }
      }));
    }
    #requestProgressScrubEnd(cancelRequested) {
      if (!this.#progressScrubState) return;
      this.#progressScrubState.pendingEnd = true;
      this.#progressScrubState.cancelRequested = !!cancelRequested;
      this.#progressScrubState.pendingCommit = true;
      if (this.#progressScrubState.timeoutId) {
        clearTimeout(this.#progressScrubState.timeoutId);
      }
      const cancel = this.#progressScrubState.cancelRequested;
      this.#logScrubDiagnostic("schedule-scrub-end", {
        cancel
      });
      this.#progressScrubState.timeoutId = setTimeout(() => {
        this.#finalizeProgressScrubSession({ cancel });
      }, 400);
    }
    #finalizeProgressScrubSession({ cancel } = {}) {
      if (!this.#progressScrubState) return;
      if (this.#progressScrubState.timeoutId) {
        clearTimeout(this.#progressScrubState.timeoutId);
      }
      const descriptor = cancel ? null : this.navHUD?.getCurrentDescriptor();
      this.navHUD?.endProgressScrubSession(descriptor, {
        cancel,
        releaseFraction: this.#progressScrubState.releaseFraction,
        originDescriptor: this.#progressScrubState.originDescriptor ?? null,
        originFraction: this.#progressScrubState.originFraction ?? null
      });
      this.#logScrubDiagnostic("finalize-scrub-session", {
        cancel
      });
      this.#progressScrubState = null;
    }
    #isJumpInputValueValid(value) {
      if (typeof value !== "number" || isNaN(value)) return false;
      return value >= 0 && value <= 100 && value !== this.lastPercentValue;
    }
    #computeSectionTicks(pageCountsMap) {
      if (!this.book || !Array.isArray(this.book.sections)) return [];
      const ticks = [];
      const counts = [];
      this.book.sections.forEach((section, idx) => {
        if (section?.linear === "no") return;
        const pageCount = pageCountsMap instanceof Map ? pageCountsMap.get(idx) : null;
        const size = typeof pageCount === "number" && pageCount > 0 ? pageCount : typeof section?.size === "number" && section.size > 0 ? section.size : null;
        if (size != null) counts.push(size);
      });
      if (!counts.length) return ticks;
      const total = counts.reduce((a2, b2) => a2 + b2, 0);
      let sum = 0;
      for (const size of counts.slice(0, -1)) {
        sum += size;
        ticks.push(sum / total);
      }
      if (counts.length >= 50) {
        const THRESHOLD = 0.01;
        const collapsed = [];
        let group = [];
        for (let i2 = 0; i2 < ticks.length; ++i2) {
          group.push(ticks[i2]);
          if (i2 === ticks.length - 1 || Math.abs(ticks[i2 + 1] - ticks[i2]) > THRESHOLD) {
            if (group.length > 1) {
              const avg = group.reduce((a2, b2) => a2 + b2, 0) / group.length;
              let closest = group[0];
              let minDist = Math.abs(avg - closest);
              for (const t2 of group) {
                const dist = Math.abs(avg - t2);
                if (dist < minDist) {
                  minDist = dist;
                  closest = t2;
                }
              }
              collapsed.push(closest);
            } else {
              collapsed.push(group[0]);
            }
            group = [];
          }
        }
        return collapsed;
      }
      return ticks;
    }
    #renderSectionTicks(pageCountsMap, precomputedTicks) {
      if (!this.#tickContainer) return;
      const ticks = precomputedTicks ?? this.#computeSectionTicks(pageCountsMap);
      this.#tickContainer.innerHTML = "";
      const isRTL = this.isRTL;
      for (const tick of ticks) {
        if (!Number.isFinite(tick)) continue;
        const pos = Math.max(0, Math.min(1, tick)) * 100;
        const mark = document.createElement("div");
        mark.className = "tick";
        mark.style[isRTL ? "right" : "left"] = `${pos}%`;
        this.#tickContainer.append(mark);
      }
    }
    #fractionFromLocation(locNumber, totalLocs) {
      if (typeof locNumber !== "number" || isNaN(locNumber)) return null;
      if (typeof totalLocs !== "number" || totalLocs <= 0) return null;
      if (totalLocs === 1) return 0;
      const clamped = Math.max(1, Math.min(totalLocs, Math.round(locNumber)));
      return (clamped - 1) / (totalLocs - 1);
    }
    #convertJumpInputValue(value, fromUnit, toUnit) {
      if (typeof value !== "number" || isNaN(value)) return null;
      if (fromUnit === toUnit) return value;
      return fromUnit === "percent" && toUnit === "percent" ? value : null;
    }
    #syncJumpInputWithState(convertedValue = null) {
      const input = this.#jumpInput ?? document.getElementById("percent-jump-input");
      if (!input) return;
      const button = this.#jumpButton ?? document.getElementById("percent-jump-button");
      if (!this.#jumpInput) this.#jumpInput = input;
      if (!this.#jumpButton) this.#jumpButton = button;
      input.min = 0;
      input.max = 100;
      input.step = "any";
      if (typeof convertedValue === "number" && !isNaN(convertedValue)) {
        input.value = convertedValue;
      } else if (typeof this.lastPercentValue === "number") {
        input.value = this.lastPercentValue;
      }
      if (button) {
        button.disabled = true;
      }
    }
    #updateJumpUnitAvailability() {
      const select = this.#jumpUnitSelect ?? document.getElementById("jump-unit-select");
      if (!select) return;
      if (!this.#jumpUnitSelect) this.#jumpUnitSelect = select;
      select.value = "percent";
      this.jumpUnit = "percent";
    }
    async #handleKeydown(event) {
      const k2 = event.key;
      const renderer = this.view.renderer;
      const isRTL = this.isRTL;
      if (k2 === "ArrowLeft" || k2 === "h") {
        if (isRTL && await renderer.atEnd()) {
          this.buttons.next.click();
        } else if (!isRTL && await renderer.atStart()) {
          this.buttons.prev.click();
        } else {
          await this.view.goLeft();
          this.#flashChevron(true);
        }
      } else if (k2 === "ArrowRight" || k2 === "l") {
        if (isRTL && await renderer.atStart()) {
          this.buttons.prev.click();
        } else if (!isRTL && await renderer.atEnd()) {
          this.buttons.next.click();
        } else {
          await this.view.goRight();
          this.#flashChevron(false);
        }
      }
    }
    #onGoTo({
      willLoadNewIndex
    }) {
      this.setLoadingIndicator(true);
    }
    #onDidDisplay({}) {
      this.setLoadingIndicator(false);
    }
    #onRendererRelocate({ detail }) {
      const bodyIsLoading = document?.body?.classList?.contains?.("loading") ?? null;
      logBug4("relocate:renderer", {
        reason: detail?.reason ?? null,
        sectionIndex: typeof detail?.sectionIndex === "number" ? detail.sectionIndex : null,
        bodyIsLoading
      });
      this.setLoadingIndicator(false);
    }
    async #postFallbackReadingProgressMessage({
      reason = "load",
      sectionIndex = null
    } = {}) {
      if (!this.hasLoadedLastPosition) return false;
      try {
        const resolvedSectionIndex = typeof sectionIndex === "number" ? sectionIndex : typeof this.view?.renderer?.currentIndex === "number" ? this.view.renderer.currentIndex : null;
        const sections = this.view?.book?.sections ?? [];
        const boundedSectionIndex = typeof resolvedSectionIndex === "number" ? Math.max(0, Math.min(sections.length - 1, resolvedSectionIndex)) : null;
        const denominator = sections.length > 1 ? sections.length - 1 : 1;
        const fallbackFraction = boundedSectionIndex == null ? 0 : Math.max(0, Math.min(1, boundedSectionIndex / denominator));
        const fallbackCFI = boundedSectionIndex == null ? "" : sections[boundedSectionIndex]?.cfi ?? "";
        this.#postUpdateReadingProgressMessage({
          fraction: fallbackFraction,
          cfi: fallbackCFI,
          reason,
          sectionIndex: boundedSectionIndex
        });
        return true;
      } catch (_error) {
        return false;
      }
    }
    async #onLoad({
      detail: {
        doc,
        location,
        index
      }
    }) {
      doc.addEventListener("keydown", this.#handleKeydown.bind(this));
      this.#ensureRubyFontOverride(doc);
      const currentPageURL = location ?? doc.location.href;
      window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
        topWindowURL: window.top.location.href,
        currentPageURL
      });
      logEBookPageNum2("onLoad:updateCurrentContentPage", {
        topWindowURL: window.top?.location?.href ?? null,
        currentPageURL: currentPageURL ?? null
      });
      await this.#postFallbackReadingProgressMessage({
        reason: "load",
        sectionIndex: typeof index === "number" ? index : null
      });
    }
    #ensureRubyFontOverride(doc) {
      try {
        const hostVar = document.documentElement?.style?.getPropertyValue("--manabi-ruby-font")?.trim();
        const stack = hostVar && hostVar.length > 0 ? hostVar : DEFAULT_RUBY_FONT_STACK;
        doc.documentElement?.style?.setProperty("--manabi-ruby-font", stack);
      } catch (error) {
      }
    }
    #resetSideNavChevrons() {
      this.#chevronAnimator?.reset();
    }
    #deriveRelocateDirection(detail, { previousFraction = null, previousPageEstimate = null } = {}) {
      const explicit = detail?.navigationDirection ?? detail?.direction ?? detail?.pageTurnDirection;
      if (explicit === "forward" || explicit === "backward") {
        return explicit;
      }
      const currentPage = typeof detail?.pageItem?.current === "number" ? detail.pageItem.current : null;
      const lastPage = typeof previousPageEstimate?.current === "number" ? previousPageEstimate.current : null;
      if (currentPage != null && lastPage != null) {
        if (currentPage > lastPage) return "forward";
        if (currentPage < lastPage) return "backward";
      }
      const priorFraction = typeof previousFraction === "number" ? previousFraction : null;
      const nextFraction = typeof detail?.fraction === "number" ? detail.fraction : null;
      if (priorFraction != null && nextFraction != null) {
        const delta = nextFraction - priorFraction;
        const EPSILON = 1e-6;
        if (delta > EPSILON) return "forward";
        if (delta < -EPSILON) return "backward";
      }
      return null;
    }
    #postUpdateReadingProgressMessage = debounce2(({
      fraction,
      cfi,
      reason,
      sectionIndex
    }) => {
      let mainDocumentURL = window.location != window.parent.location ? document.referrer : document.location.href;
      try {
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
          fractionalCompletion: fraction,
          cfi,
          reason,
          sectionIndex: typeof sectionIndex === "number" ? sectionIndex : null,
          mainDocumentURL
        });
      } catch (error) {
        console.error("Failed to post updateReadingProgress", error);
      }
    }, 400);
    async #onRelocate({ detail }) {
      const sectionIndexFromDetail = typeof detail?.sectionIndex === "number" ? detail.sectionIndex : typeof detail?.index === "number" ? detail.index : null;
      const fractionFromDetail = typeof detail?.fraction === "number" ? detail.fraction : null;
      try {
        this.setLoadingIndicator(false);
        const navBar = document.getElementById("nav-bar");
        const progressWrapper = document.getElementById("progress-wrapper");
        const sliderEl = document.getElementById("progress-slider");
        const ticksEl = document.getElementById("progress-ticks");
        logBug4("relocate:start", {
          reason: detail?.reason ?? null,
          sectionIndex: sectionIndexFromDetail,
          fraction: fractionFromDetail,
          bodyClasses: Array.from(document?.body?.classList ?? []),
          navHidden: navBar?.classList?.contains?.("nav-hidden") ?? null,
          sliderVisible: sliderEl?.style?.visibility ?? null
        });
        logNavHide3("relocate:preserve-nav-state", {
          source: detail?.reason ?? null,
          navHiddenClass: navBar?.classList?.contains?.("nav-hidden") ?? null,
          navHiddenScrollClass: navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? null,
          bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null,
          hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
          pendingHideNavigationState
        });
        const {
          fraction,
          location,
          tocItem,
          pageItem,
          cfi,
          reason,
          index: sectionIndex
        } = detail;
        const inferredSectionIndex = (() => {
          if (typeof detail?.sectionIndex === "number") return detail.sectionIndex;
          if (typeof sectionIndex === "number") return sectionIndex;
          const rendererIndex = this.view?.renderer?.currentIndex;
          if (typeof rendererIndex === "number") return rendererIndex;
          return null;
        })();
        const normalizedDetail = {
          ...detail,
          sectionIndex: inferredSectionIndex,
          index: typeof detail?.index === "number" ? detail.index : typeof sectionIndex === "number" ? sectionIndex : inferredSectionIndex
        };
        const previousFraction = typeof this.lastKnownFraction === "number" ? this.lastKnownFraction : null;
        const previousPageEstimate = this.lastPageEstimate;
        const slider = $2("#progress-slider");
        slider.style.visibility = "visible";
        const ticks = document.getElementById("progress-ticks");
        if (ticks) ticks.style.visibility = "visible";
        const scrubbing = !!this.#progressScrubState;
        if (scrubbing) {
          detail.reason = "live-scroll";
          detail.liveScrollPhase = "dragging";
        } else if (detail.reason === "live-scroll") {
          detail.liveScrollPhase = "settled";
        }
        const normalizedReason = (detail.reason || "").toLowerCase();
        const relocateDirection = this.#deriveRelocateDirection(detail, {
          previousFraction,
          previousPageEstimate
        });
        const sectionDelta = typeof sectionIndex === "number" && typeof this._lastRelocateSectionIndex === "number" ? sectionIndex - this._lastRelocateSectionIndex : null;
        logNavHide3("relocate:direction", {
          reason: normalizedReason,
          direction: relocateDirection,
          previousFraction,
          fraction,
          previousSectionIndex: this._lastRelocateSectionIndex ?? null,
          sectionIndex,
          bodyNavHidden: document?.body?.classList?.contains?.("nav-hidden") ?? null,
          navHiddenScrollClass: navBar?.classList?.contains?.("nav-hidden-due-to-scroll") ?? null,
          hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
          sectionDelta
        });
        switch (normalizedReason) {
          case "live-scroll":
          case "selection":
          case "navigation":
            postNavigationChromeVisibility2(false, {
              source: "relocate",
              direction: relocateDirection,
              scrubbing,
              ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason }
            });
            break;
          case "page":
            if (scrubbing) {
              postNavigationChromeVisibility2(false, {
                source: "relocate",
                direction: relocateDirection,
                scrubbing,
                ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason }
              });
            } else if (relocateDirection === "forward") {
              postNavigationChromeVisibility2(true, {
                source: "relocate",
                direction: "forward",
                scrubbing,
                ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason }
              });
            } else if (relocateDirection === "backward") {
              postNavigationChromeVisibility2(false, {
                source: "relocate",
                direction: "backward",
                scrubbing,
                ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason }
              });
            } else {
              postNavigationChromeVisibility2(false, {
                source: "relocate",
                direction: relocateDirection,
                scrubbing,
                ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason }
              });
            }
            logBug4("nav-toggle", {
              reason: normalizedReason,
              direction: relocateDirection,
              hide: relocateDirection === "forward",
              fraction,
              sectionIndex
            });
            break;
          default:
            break;
        }
        if (this.hasLoadedLastPosition) {
          this.#postUpdateReadingProgressMessage({
            fraction,
            cfi,
            reason,
            sectionIndex: normalizedDetail.sectionIndex
          });
        }
        await this.updateNavButtons();
        await this.navHUD?.handleRelocate(normalizedDetail);
        this._lastRelocateContext = {
          fraction,
          sectionIndex,
          reason: normalizedReason,
          relocateDirection,
          previousFraction
        };
        const scrubFraction = this.navHUD?.getScrubberFraction(normalizedDetail) ?? null;
        const effectiveFraction = Number.isFinite(scrubFraction) ? scrubFraction : fraction;
        if ((detail.reason || "").toLowerCase() !== "live-scroll") {
          const sliderValue = Number.isFinite(effectiveFraction) ? effectiveFraction : 0;
          slider.value = sliderValue;
          slider.style.setProperty("--value", sliderValue);
        }
        const percentValue = Number.isFinite(effectiveFraction) ? effectiveFraction : 0;
        const percent = percentFormat.format(percentValue);
        const navLabel = this.navHUD?.getPrimaryDisplayLabel(normalizedDetail);
        const tooltipParts = [];
        if (navLabel) {
          tooltipParts.push(navLabel);
        }
        tooltipParts.push(percent);
        slider.title = tooltipParts.filter(Boolean).join(" \xB7 ");
        if (scrubbing && this.#progressScrubState?.pendingEnd) {
          this.#finalizeProgressScrubSession({ cancel: this.#progressScrubState.cancelRequested });
        }
        this.lastKnownFraction = percentValue;
        const pct = Math.round(percentValue * 100);
        this.lastPercentValue = pct;
        const percentInput = this.#jumpInput ?? document.getElementById("percent-jump-input");
        const percentButton = this.#jumpButton ?? document.getElementById("percent-jump-button");
        if (!this.#jumpInput && percentInput) this.#jumpInput = percentInput;
        if (!this.#jumpButton && percentButton) this.#jumpButton = percentButton;
        const pageEstimate = this.navHUD?.getPageEstimate(normalizedDetail);
        if (pageEstimate) {
          this.lastPageEstimate = pageEstimate;
        }
        logEBookPageNum2("relocate:label", {
          label: navLabel ?? "",
          fraction,
          scrubFraction: scrubFraction ?? null,
          sectionIndex,
          pageEstimateCurrent: pageEstimate?.current ?? null,
          pageEstimateTotal: pageEstimate?.total ?? null,
          lastPercentValue: this.lastPercentValue ?? null
        });
        logEBookPageNum2("relocate", {
          reason: detail.reason ?? null,
          relocateDirection,
          sectionIndex,
          fraction,
          scrubFraction: scrubFraction ?? null,
          pageItemCurrent: pageItem?.current ?? null,
          pageItemTotal: pageItem?.total ?? null,
          locationCurrent: location?.current ?? null,
          locationTotal: location?.total ?? null,
          tocHref: tocItem?.href ?? null,
          pageEstimateCurrent: pageEstimate?.current ?? null,
          pageEstimateTotal: pageEstimate?.total ?? null,
          previousPageEstimateCurrent: previousPageEstimate?.current ?? null,
          previousPageEstimateTotal: previousPageEstimate?.total ?? null,
          previousFraction,
          lastPercentValue: this.lastPercentValue ?? null,
          scrubbing
        });
        this._lastRelocateSectionIndex = sectionIndex;
        this.#updateJumpUnitAvailability();
        this.#syncJumpInputWithState();
        if (percentButton) {
          percentButton.disabled = true;
        }
        logBug4("relocate:end", {
          reason: detail?.reason ?? null,
          sectionIndex: sectionIndexFromDetail,
          fraction,
          scrubFraction: scrubFraction ?? null,
          pageEstimateCurrent: this.lastPageEstimate?.current ?? null,
          pageEstimateTotal: this.lastPageEstimate?.total ?? null,
          navHiddenClass: document?.body?.classList?.contains?.("nav-hidden") ?? null
        });
      } catch (error) {
        logBug4("relocate:error", { message: String(error), stack: error?.stack ?? null });
        console.error(error);
      }
    }
    async #goToDescriptor(descriptor) {
      if (!descriptor) return;
      const fraction = typeof descriptor.fraction === "number" ? Number(descriptor.fraction.toFixed(6)) : null;
      if (descriptor.cfi) {
        await this.view.goTo(descriptor.cfi);
        return;
      }
      if (typeof descriptor.fraction === "number") {
        await this.view.goToFraction(descriptor.fraction);
      }
    }
    async #onNavButtonClick(e2) {
      const btn = e2.currentTarget;
      const type = btn.dataset.buttonType;
      const icon = btn.querySelector("svg");
      const label = btn.querySelector(".button-label");
      if (label) label.style.visibility = "hidden";
      if (icon) {
        btn._originalIcon = icon.cloneNode(true);
        const spinner = document.createElement("div");
        spinner.className = "ispinner nav-spinner";
        spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);
        if (btn._spinnerAfterLabel) {
          if (icon) icon.remove();
          const labels = btn.querySelectorAll(".button-label");
          let targetLabel = null;
          for (const lbl of labels) {
            if (lbl.offsetParent !== null && getComputedStyle(lbl).display !== "none") {
              targetLabel = lbl;
            }
          }
          if (targetLabel) {
            targetLabel.after(spinner);
          } else {
            btn.appendChild(spinner);
          }
        } else {
          icon.replaceWith(spinner);
        }
      }
      const restoreIcon = () => {
        const spinner = btn.querySelector(".ispinner.nav-spinner");
        if (spinner && btn._originalIcon) {
          spinner.replaceWith(btn._originalIcon);
          delete btn._originalIcon;
        }
        if (label) label.style.visibility = "";
      };
      let nav;
      switch (type) {
        // TODO: Clean up, the scroll cases here won't be reached because of above...
        case "prev":
          postNavigationChromeVisibility2(false, { source: "button-prev", direction: "backward" });
          nav = this.view.renderer.prevSection();
          break;
        case "next":
          postNavigationChromeVisibility2(true, { source: "button-next", direction: "forward", scrubbing: false });
          nav = this.view.renderer.nextSection();
          break;
        case "finish":
          window.webkit.messageHandlers.finishedReadingBook.postMessage({
            topWindowURL: window.top.location.href
          });
          nav = Promise.resolve();
          break;
        case "restart":
          window.webkit.messageHandlers.startOver.postMessage({});
          await this.view.renderer.firstSection();
          nav = Promise.resolve();
          break;
      }
      Promise.resolve(nav).catch((err) => {
        const line = `# EBOOK nav:error ${JSON.stringify({ type, message: err?.message ?? String(err) })}`;
      }).finally(() => {
        if (type === "finish" || type === "restart") return;
        restoreIcon();
      });
    }
  };
  var CacheWarmer = class {
    constructor() {
      this.view;
      this.pageCounts = /* @__PURE__ */ new Map();
      globalThis.cacheWarmerPageCounts = this.pageCounts;
      globalThis.cacheWarmerTotalPages = 0;
    }
    async open(source) {
      this.source = source;
      this.view = await getView(source, true);
      this.view.addEventListener("load", this.#onLoad.bind(this));
      this.view.addEventListener("relocate", this.#onRelocate.bind(this));
      const {
        book
      } = this.view;
      this.view.renderer.setAttribute("flow", "paginated");
      await this.view.renderer.firstSection();
    }
    async #onLoad({
      detail: {
        location
      }
    }) {
      window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
        topWindowURL: window.top.location.href,
        frameURL: location
      });
      if (!await this.view.renderer.atEnd()) {
        window.webkit.messageHandlers.ebookCacheWarmerReadyToLoadNextSection.postMessage({
          topWindowURL: window.top.location.href
        });
      } else {
      }
    }
    #broadcastPageCounts() {
      const total = Array.from(this.pageCounts.values()).reduce((acc, v2) => acc + (Number.isFinite(v2) ? v2 : 0), 0);
      globalThis.cacheWarmerTotalPages = total;
      try {
        const key = getBookCacheKey();
        if (key) {
          const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER2];
          handler?.postMessage?.({
            command: "set",
            key: `${key}::pageCounts`,
            entries: Array.from(this.pageCounts.entries()),
            reason: "page-counts"
          });
          logFix2("cachewarmer:store", { key, total, size: this.pageCounts.size });
        }
      } catch (error) {
        logFix2("cachewarmer:store:error", { error: String(error) });
      }
      document.dispatchEvent(new CustomEvent("cachewarmer:pagecounts", {
        detail: {
          counts: Array.from(this.pageCounts.entries()),
          total
        }
      }));
    }
    #onRelocate({ detail }) {
      const sectionIndex = typeof detail?.sectionIndex === "number" ? detail.sectionIndex : typeof this.view?.renderer?.currentIndex === "number" ? this.view.renderer.currentIndex : null;
      const pageCount = typeof detail?.pageCount === "number" && detail.pageCount > 0 ? detail.pageCount : null;
      if (sectionIndex == null || pageCount == null) return;
      this.pageCounts.set(sectionIndex, pageCount);
      this.#broadcastPageCounts();
    }
    //    #postUpdateReadingProgressMessage = debounce(({ fraction, cfi }) => {
    //        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
    //        window.webkit.messageHandlers.updateReadingProgress.postMessage({
    //        fractionalCompletion: fraction,
    //        cfi: cfi,
    //        mainDocumentURL: mainDocumentURL,
    //        })
    //    }, 400)
  };
  var getVisibleReaderFrames = () => {
    const frames = Array.from(document.querySelectorAll("iframe"));
    if (!frames.length) {
      return [];
    }
    const viewportHeight = window.innerHeight || document.documentElement?.clientHeight || 0;
    const viewportWidth = window.innerWidth || document.documentElement?.clientWidth || 0;
    return frames.map((frame) => {
      try {
        const frameWindow = frame.contentWindow;
        const frameDocument = frameWindow?.document;
        const hasReaderContent = !!frameDocument?.querySelector?.("manabi-sentence[data-sentence-identifier]");
        if (!hasReaderContent) {
          return null;
        }
        const rect = frame.getBoundingClientRect();
        const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
        const visibleArea = visibleWidth * visibleHeight;
        return { frame, visibleArea };
      } catch (_error) {
        return null;
      }
    }).filter(Boolean).sort((lhs, rhs) => rhs.visibleArea - lhs.visibleArea).map((entry) => entry.frame);
  };
  var callFrameFunction = (frame, functionName, args = []) => {
    try {
      const frameWindow = frame?.contentWindow;
      const fn2 = frameWindow?.[functionName];
      if (typeof fn2 !== "function") {
        return null;
      }
      return fn2.apply(frameWindow, args);
    } catch (_error) {
      return null;
    }
  };
  var resolvePrimaryReaderFrame = () => {
    const frames = getVisibleReaderFrames();
    return frames[0] || null;
  };
  window.manabi_collectSentencesForAITTS = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
      return [];
    }
    const rows = callFrameFunction(frame, "manabi_collectSentencesForAITTS");
    return Array.isArray(rows) ? rows : [];
  };
  window.manabi_captureVisibleSentenceIdentifier = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
      return null;
    }
    return callFrameFunction(frame, "manabi_captureVisibleSentenceIdentifier");
  };
  window.manabi_setAITTSCurrentSentence = (sentenceIdentifier) => {
    let didApply = false;
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
      const appliedInFrame = callFrameFunction(frame, "manabi_setAITTSCurrentSentence", [sentenceIdentifier]);
      if (appliedInFrame === true) {
        didApply = true;
      }
    }
    return didApply;
  };
  window.manabi_clearAITTSCurrentSentence = () => {
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
      callFrameFunction(frame, "manabi_clearAITTSCurrentSentence");
    }
    return true;
  };
  window.manabi_seekToSentenceIdentifierForReadAloud = (sentenceIdentifier) => {
    if (!sentenceIdentifier) {
      return false;
    }
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
      const didSeek = callFrameFunction(frame, "manabi_seekToSentenceIdentifierForReadAloud", [sentenceIdentifier]);
      if (didSeek === true) {
        return true;
      }
    }
    return false;
  };
  window.manabi_getPlaybackSyncAnchor = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
      return {
        sentenceIdentifier: null,
        transcriptStartSeconds: null
      };
    }
    const anchor = callFrameFunction(frame, "manabi_getPlaybackSyncAnchor");
    if (anchor && typeof anchor === "object") {
      return anchor;
    }
    return {
      sentenceIdentifier: null,
      transcriptStartSeconds: null
    };
  };
  window.manabi_shouldSeekPlaybackAfterViewportCheck = async (options = {}) => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
      return true;
    }
    const frameWindow = frame.contentWindow;
    if (typeof frameWindow?.manabi_shouldSeekPlaybackAfterViewportCheck !== "function") {
      return true;
    }
    try {
      const result = await frameWindow.manabi_shouldSeekPlaybackAfterViewportCheck(options);
      return result !== false;
    } catch (_error) {
      return true;
    }
  };
  var manabiEbookAudioBridge = {
    pausedForLoading: false,
    pendingNavigation: null,
    requestNavigation(payload) {
      if (!payload) {
        return;
      }
      const fraction = this.fractionForPayload(payload);
      if (!Number.isFinite(fraction)) {
        return;
      }
      if (this.pendingNavigation && Math.abs((this.pendingNavigation.fraction ?? fraction) - fraction) < 1e-4) {
        return;
      }
      this.pendingNavigation = Object.assign({}, payload, { fraction });
      this.pauseNativeAudio("section-navigation");
      globalThis.reader?.view?.goToFraction(fraction).catch((error) => {
        console.error("ebook audio navigation failed", error);
        this.resumeNativeAudio("navigation-error");
      });
    },
    sectionReady(metadata) {
      if (metadata?.sectionURL) {
        this.pendingNavigation = null;
      }
      this.resumeNativeAudio("section-ready");
    },
    cancel(reason = "cancelled") {
      this.pendingNavigation = null;
      if (this.pausedForLoading) {
        this.resumeNativeAudio(reason);
      }
    },
    fractionForPayload(payload) {
      if (Number.isFinite(payload?.fraction)) {
        return Math.max(0, Math.min(1, payload.fraction));
      }
      if (Number.isFinite(payload?.wordIndex) && Number.isFinite(payload?.totalWordCount) && payload.totalWordCount > 0) {
        return Math.max(0, Math.min(1, payload.wordIndex / payload.totalWordCount));
      }
      return null;
    },
    pauseNativeAudio(reason) {
      if (this.pausedForLoading) {
        return;
      }
      this.pausedForLoading = true;
      try {
        window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: "pause", reason, timestamp: Date.now() });
      } catch (_error) {
      }
    },
    resumeNativeAudio(reason) {
      if (!this.pausedForLoading) {
        return;
      }
      this.pausedForLoading = false;
      try {
        window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: "resume", reason, timestamp: Date.now() });
      } catch (_error) {
      }
    }
  };
  window.manabiEbookAudioBridge = manabiEbookAudioBridge;
  window.cancelEbookAudioNavigation = (reason) => {
    window.manabiEbookAudioBridge?.cancel?.(reason || "cancelled");
  };
  window.setEbookViewerLayout = (layoutMode) => {
  };
  window.setEbookViewerWritingDirection = async (writingDirection) => {
    globalThis.manabiEbookWritingDirection = writingDirection || "original";
    const renderer = globalThis.reader?.view?.renderer;
    if (renderer && typeof renderer.render === "function") {
      try {
        await renderer.render();
      } catch (_2) {
      }
    }
    try {
      const currentDoc = globalThis.reader?.view?.document;
      if (currentDoc) {
        await globalThis.manabiEnsureCustomFonts?.(currentDoc);
      }
    } catch (_2) {
    }
  };
  window.manabiGetWritingDirectionSnapshot = () => {
    return {
      pageURL: window.location.href,
      writingDirectionOverride: globalThis.manabiEbookWritingDirection || "original",
      vertical: globalThis.manabiTrackingVertical === true,
      verticalRTL: globalThis.manabiTrackingVerticalRTL === true,
      rtl: globalThis.manabiTrackingRTL === true,
      writingMode: globalThis.manabiTrackingWritingMode || null
    };
  };
  window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.view.renderer.nextSection();
  };
  var logReaderBootstrapState = (event) => {
    logFix2(event, {
      hasReader: !!globalThis.reader,
      hasView: !!globalThis.reader?.view,
      hasRenderer: !!globalThis.reader?.view?.renderer,
      hasSectionLayoutController: !!(globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController ?? globalThis.manabiEbookSectionLayoutController),
      pageURL: window.location.href
    });
  };
  window.manabiGetPageTurnProbeSnapshot = async () => {
    try {
      const view = globalThis.reader?.view;
      const renderer = view?.renderer;
      const sectionLayoutController = view?.document?.defaultView?.manabiEbookSectionLayoutController ?? globalThis.manabiEbookSectionLayoutController;
      let layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === "function" ? sectionLayoutController.layoutDiagnostics() : null;
      const chunkLayoutMetrics = typeof globalThis.manabiGetChunkLayoutMetrics === "function" ? globalThis.manabiGetChunkLayoutMetrics({ isEbook: true }) : null;
      const layoutCurrentPageIndex = Number.isFinite(layoutDiagnostics?.currentPageIndex) ? layoutDiagnostics.currentPageIndex : null;
      if (Number.isFinite(layoutCurrentPageIndex) && typeof sectionLayoutController?.ensurePageBuilt === "function" && (!Number.isFinite(layoutDiagnostics?.pageCount) || layoutDiagnostics.pageCount <= layoutCurrentPageIndex + 1)) {
        try {
          sectionLayoutController.ensurePageBuilt(layoutCurrentPageIndex + 1, {
            reason: "page-turn-probe"
          });
          layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === "function" ? sectionLayoutController.layoutDiagnostics() : layoutDiagnostics;
        } catch (_error) {
        }
      }
      const shouldAttemptOverflowRecovery = typeof sectionLayoutController?.rebuildFromCurrentLocation === "function" && layoutDiagnostics?.layoutComplete === true && Number.isFinite(layoutDiagnostics?.pageCount) && layoutDiagnostics.pageCount <= 1 && layoutDiagnostics?.currentChunkOverflow === true && !globalThis.manabiPageTurnOverflowRecoveryAttempted;
      if (shouldAttemptOverflowRecovery) {
        try {
          globalThis.manabiPageTurnOverflowRecoveryAttempted = true;
          sectionLayoutController.rebuildFromCurrentLocation({
            reason: "page-turn-probe-overflow-rebuild"
          });
          layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === "function" ? sectionLayoutController.layoutDiagnostics() : layoutDiagnostics;
        } catch (_error) {
        }
      }
      const layoutPageCount = Number.isFinite(layoutDiagnostics?.pageCount) ? layoutDiagnostics.pageCount : null;
      const layoutPageRecordCount = Number.isFinite(layoutDiagnostics?.pageRecordCount) ? layoutDiagnostics.pageRecordCount : Array.isArray(layoutDiagnostics?.pages) ? layoutDiagnostics.pages.length : null;
      const layoutLiveRootExists = typeof layoutDiagnostics?.liveRootExists === "boolean" ? layoutDiagnostics.liveRootExists : null;
      const layoutLiveRootClassName = typeof layoutDiagnostics?.liveRootClassName === "string" ? layoutDiagnostics.liveRootClassName : null;
      const layoutLiveRootChildCount = Number.isFinite(layoutDiagnostics?.liveRootChildCount) ? layoutDiagnostics.liveRootChildCount : null;
      const layoutLiveRootRectWidth = Number.isFinite(layoutDiagnostics?.liveRootRectWidth) ? layoutDiagnostics.liveRootRectWidth : null;
      const layoutLiveRootRectHeight = Number.isFinite(layoutDiagnostics?.liveRootRectHeight) ? layoutDiagnostics.liveRootRectHeight : null;
      const layoutLiveCurrentPageExists = typeof layoutDiagnostics?.liveCurrentPageExists === "boolean" ? layoutDiagnostics.liveCurrentPageExists : null;
      const layoutLiveCurrentPageClassName = typeof layoutDiagnostics?.liveCurrentPageClassName === "string" ? layoutDiagnostics.liveCurrentPageClassName : null;
      const layoutLiveCurrentPageRectWidth = Number.isFinite(layoutDiagnostics?.liveCurrentPageRectWidth) ? layoutDiagnostics.liveCurrentPageRectWidth : null;
      const layoutLiveCurrentPageRectHeight = Number.isFinite(layoutDiagnostics?.liveCurrentPageRectHeight) ? layoutDiagnostics.liveCurrentPageRectHeight : null;
      const layoutLiveCurrentPageContainsChunkBody = typeof layoutDiagnostics?.liveCurrentPageContainsChunkBody === "boolean" ? layoutDiagnostics.liveCurrentPageContainsChunkBody : null;
      const layoutLiveCurrentChunkExists = typeof layoutDiagnostics?.liveCurrentChunkExists === "boolean" ? layoutDiagnostics.liveCurrentChunkExists : null;
      const layoutLiveCurrentChunkTagName = typeof layoutDiagnostics?.liveCurrentChunkTagName === "string" ? layoutDiagnostics.liveCurrentChunkTagName : null;
      const layoutLiveCurrentChunkClassName = typeof layoutDiagnostics?.liveCurrentChunkClassName === "string" ? layoutDiagnostics.liveCurrentChunkClassName : null;
      const layoutLiveCurrentChunkDisplay = typeof layoutDiagnostics?.liveCurrentChunkDisplay === "string" ? layoutDiagnostics.liveCurrentChunkDisplay : null;
      const layoutLiveCurrentChunkPosition = typeof layoutDiagnostics?.liveCurrentChunkPosition === "string" ? layoutDiagnostics.liveCurrentChunkPosition : null;
      const layoutLiveCurrentChunkFlex = typeof layoutDiagnostics?.liveCurrentChunkFlex === "string" ? layoutDiagnostics.liveCurrentChunkFlex : null;
      const layoutLiveCurrentChunkRectWidth = Number.isFinite(layoutDiagnostics?.liveCurrentChunkRectWidth) ? layoutDiagnostics.liveCurrentChunkRectWidth : null;
      const layoutLiveCurrentChunkRectHeight = Number.isFinite(layoutDiagnostics?.liveCurrentChunkRectHeight) ? layoutDiagnostics.liveCurrentChunkRectHeight : null;
      const layoutLiveCurrentChunkInnerHTMLLength = Number.isFinite(layoutDiagnostics?.liveCurrentChunkInnerHTMLLength) ? layoutDiagnostics.liveCurrentChunkInnerHTMLLength : null;
      const layoutLiveCurrentChunkContainsChunkBody = typeof layoutDiagnostics?.liveCurrentChunkContainsChunkBody === "boolean" ? layoutDiagnostics.liveCurrentChunkContainsChunkBody : null;
      const layoutLiveCurrentChunkChildCount = Number.isFinite(layoutDiagnostics?.liveCurrentChunkChildCount) ? layoutDiagnostics.liveCurrentChunkChildCount : null;
      const layoutLiveCurrentChunkTextLength = Number.isFinite(layoutDiagnostics?.liveCurrentChunkTextLength) ? layoutDiagnostics.liveCurrentChunkTextLength : null;
      const layoutCurrentChunkBodyChildCount = Number.isFinite(layoutDiagnostics?.currentChunkBodyChildCount) ? layoutDiagnostics.currentChunkBodyChildCount : null;
      const layoutCurrentChunkBodyTextLength = Number.isFinite(layoutDiagnostics?.currentChunkBodyTextLength) ? layoutDiagnostics.currentChunkBodyTextLength : null;
      const layoutCurrentChunkBodyDisplay = typeof layoutDiagnostics?.currentChunkBodyDisplay === "string" ? layoutDiagnostics.currentChunkBodyDisplay : null;
      const layoutCurrentChunkBodyPosition = typeof layoutDiagnostics?.currentChunkBodyPosition === "string" ? layoutDiagnostics.currentChunkBodyPosition : null;
      const layoutCurrentChunkBodyFlex = typeof layoutDiagnostics?.currentChunkBodyFlex === "string" ? layoutDiagnostics.currentChunkBodyFlex : null;
      const layoutColumnCount = Number.isFinite(layoutDiagnostics?.columnCount) ? layoutDiagnostics.columnCount : null;
      const layoutCurrentPageChunkCount = Number.isFinite(layoutDiagnostics?.currentPageChunkCount) ? layoutDiagnostics.currentPageChunkCount : null;
      const layoutMaxPageChunkCount = Number.isFinite(layoutDiagnostics?.maxPageChunkCount) ? layoutDiagnostics.maxPageChunkCount : null;
      const layoutUnitCount = Number.isFinite(layoutDiagnostics?.unitCount) ? layoutDiagnostics.unitCount : null;
      const layoutActiveBuildPageIndex = Number.isFinite(layoutDiagnostics?.activeBuildPageIndex) ? layoutDiagnostics.activeBuildPageIndex : null;
      const layoutComplete = typeof layoutDiagnostics?.layoutComplete === "boolean" ? layoutDiagnostics.layoutComplete : null;
      const layoutSpreadCandidateDetected = typeof layoutDiagnostics?.spreadCandidateDetected === "boolean" ? layoutDiagnostics.spreadCandidateDetected : null;
      const layoutVisibleUnitKind = typeof layoutDiagnostics?.visibleUnitKind === "string" ? layoutDiagnostics.visibleUnitKind : null;
      const layoutVisibleUnitAxis = typeof layoutDiagnostics?.visibleUnitAxis === "string" ? layoutDiagnostics.visibleUnitAxis : null;
      const layoutVisiblePageCount = Number.isFinite(layoutDiagnostics?.visiblePageCount) ? layoutDiagnostics.visiblePageCount : null;
      const layoutCurrentUnitIndex = Number.isFinite(layoutDiagnostics?.currentUnitIndex) ? layoutDiagnostics.currentUnitIndex : null;
      const layoutLeadingPageIndex = Number.isFinite(layoutDiagnostics?.leadingPageIndex) ? layoutDiagnostics.leadingPageIndex : null;
      const layoutTrailingPageIndex = Number.isFinite(layoutDiagnostics?.trailingPageIndex) ? layoutDiagnostics.trailingPageIndex : null;
      const layoutHasLeadingSingleton = typeof layoutDiagnostics?.hasLeadingSingleton === "boolean" ? layoutDiagnostics.hasLeadingSingleton : null;
      const layoutHasTrailingSingleton = typeof layoutDiagnostics?.hasTrailingSingleton === "boolean" ? layoutDiagnostics.hasTrailingSingleton : null;
      const layoutMultiUnitActive = typeof layoutDiagnostics?.multiUnitActive === "boolean" ? layoutDiagnostics.multiUnitActive : null;
      const layoutSpreadPagesAllowedForViewport = typeof layoutDiagnostics?.spreadPagesAllowedForViewport === "boolean" ? layoutDiagnostics.spreadPagesAllowedForViewport : null;
      const layoutWritingMode = typeof layoutDiagnostics?.writingMode === "string" ? layoutDiagnostics.writingMode : typeof chunkLayoutMetrics?.writingMode === "string" ? chunkLayoutMetrics.writingMode : null;
      const layoutViewportWidth = Number.isFinite(chunkLayoutMetrics?.viewportWidth) ? chunkLayoutMetrics.viewportWidth : null;
      const layoutViewportHeight = Number.isFinite(chunkLayoutMetrics?.viewportHeight) ? chunkLayoutMetrics.viewportHeight : null;
      const layoutMeasuredGap = Number.isFinite(chunkLayoutMetrics?.gap) ? chunkLayoutMetrics.gap : null;
      const layoutMetricSize = Number.isFinite(chunkLayoutMetrics?.size) ? chunkLayoutMetrics.size : null;
      const layoutColumnInlineSize = Number.isFinite(chunkLayoutMetrics?.columnInlineSize) ? chunkLayoutMetrics.columnInlineSize : null;
      const layoutCurrentChunkClientWidth = Number.isFinite(layoutDiagnostics?.currentChunkClientWidth) ? layoutDiagnostics.currentChunkClientWidth : null;
      const layoutCurrentChunkClientHeight = Number.isFinite(layoutDiagnostics?.currentChunkClientHeight) ? layoutDiagnostics.currentChunkClientHeight : null;
      const layoutCurrentChunkScrollWidth = Number.isFinite(layoutDiagnostics?.currentChunkScrollWidth) ? layoutDiagnostics.currentChunkScrollWidth : null;
      const layoutCurrentChunkScrollHeight = Number.isFinite(layoutDiagnostics?.currentChunkScrollHeight) ? layoutDiagnostics.currentChunkScrollHeight : null;
      const layoutCurrentChunkOverflow = typeof layoutDiagnostics?.currentChunkOverflow === "boolean" ? layoutDiagnostics.currentChunkOverflow : null;
      const shouldLogZeroLayout = layoutLiveRootExists === true && layoutLiveCurrentPageExists === true && layoutLiveCurrentChunkExists === true && (layoutLiveRootRectWidth === 0 || layoutLiveRootRectHeight === 0 || layoutLiveCurrentPageRectWidth === 0 || layoutLiveCurrentPageRectHeight === 0 || layoutLiveCurrentChunkRectWidth === 0 || layoutLiveCurrentChunkRectHeight === 0);
      if (shouldLogZeroLayout) {
        try {
          const liveRoot2 = view?.document?.getElementById?.("reader-content") ?? null;
          const liveRootParent = liveRoot2?.parentElement ?? null;
          const liveRootParentRect = liveRootParent?.getBoundingClientRect?.() ?? null;
          const rootNode = liveRoot2?.getRootNode?.() ?? null;
          const liveRootHost = rootNode instanceof ShadowRoot ? rootNode.host : null;
          const liveRootHostRect = liveRootHost?.getBoundingClientRect?.() ?? null;
          logFix2("page-turn-probe-zero-layout", {
            pageURL: window.location.href,
            attempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
            loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
            liveRootTagName: liveRoot2?.tagName?.toLowerCase?.() ?? null,
            liveRootClassName: liveRoot2?.className ?? null,
            liveRootDisplay: liveRoot2 ? globalThis.getComputedStyle?.(liveRoot2)?.display ?? null : null,
            liveRootVisibility: liveRoot2 ? globalThis.getComputedStyle?.(liveRoot2)?.visibility ?? null : null,
            liveRootParentTagName: liveRootParent?.tagName?.toLowerCase?.() ?? null,
            liveRootParentClassName: liveRootParent?.className ?? null,
            liveRootParentRectWidth: liveRootParentRect ? Math.round(liveRootParentRect.width) : null,
            liveRootParentRectHeight: liveRootParentRect ? Math.round(liveRootParentRect.height) : null,
            liveRootParentDisplay: liveRootParent ? globalThis.getComputedStyle?.(liveRootParent)?.display ?? null : null,
            liveRootParentVisibility: liveRootParent ? globalThis.getComputedStyle?.(liveRootParent)?.visibility ?? null : null,
            liveRootHostTagName: liveRootHost?.tagName?.toLowerCase?.() ?? null,
            liveRootHostClassName: liveRootHost?.className ?? null,
            liveRootHostRectWidth: liveRootHostRect ? Math.round(liveRootHostRect.width) : null,
            liveRootHostRectHeight: liveRootHostRect ? Math.round(liveRootHostRect.height) : null,
            liveRootHostDisplay: liveRootHost ? globalThis.getComputedStyle?.(liveRootHost)?.display ?? null : null,
            liveRootHostVisibility: liveRootHost ? globalThis.getComputedStyle?.(liveRootHost)?.visibility ?? null : null,
            layoutLiveRootRectWidth,
            layoutLiveRootRectHeight,
            layoutLiveCurrentPageRectWidth,
            layoutLiveCurrentPageRectHeight,
            layoutLiveCurrentChunkRectWidth,
            layoutLiveCurrentChunkRectHeight
          });
        } catch (_error) {
        }
      }
      const liveDoc = view?.document ?? null;
      const liveRoot = liveDoc ? liveDoc.getElementById?.("reader-content") || liveDoc.body || null : null;
      const livePageRoot = liveRoot?.querySelector?.(".manabi-page-root") || null;
      const allLivePages = Array.from(liveRoot?.querySelectorAll?.(".manabi-page") || []);
      const sameDocumentDatasetPageIndex = Number.parseInt(
        livePageRoot?.dataset?.manabiCurrentPageIndex ?? "",
        10
      );
      const sameDocumentPageIndex = Number.isFinite(sameDocumentDatasetPageIndex) ? Math.max(0, sameDocumentDatasetPageIndex) : null;
      const sameDocumentPageCount = allLivePages.length > 0 ? allLivePages.length : null;
      const rendererReportedPage = typeof renderer?.page === "function" ? await renderer.page() : layoutCurrentPageIndex;
      const rendererReportedPageCount = typeof renderer?.pages === "function" ? await renderer.pages() : layoutPageCount;
      const page = sameDocumentPageIndex ?? rendererReportedPage;
      const pageCount = sameDocumentPageCount ?? rendererReportedPageCount;
      const currentSectionIndex = Number.isFinite(renderer?.currentIndex) ? renderer.currentIndex : null;
      const currentSectionHref = currentSectionIndex != null ? renderer?.sections?.[currentSectionIndex]?.href ?? renderer?.sections?.[currentSectionIndex]?.url ?? null : null;
      const atSectionStart = typeof renderer?.isAtSectionStart === "function" ? await renderer.isAtSectionStart() : null;
      const atSectionEnd = typeof renderer?.isAtSectionEnd === "function" ? await renderer.isAtSectionEnd() : null;
      const hasPrevSection = typeof renderer?.getHasPrevSection === "function" ? !!renderer.getHasPrevSection() : false;
      const hasNextSection = typeof renderer?.getHasNextSection === "function" ? !!renderer.getHasNextSection() : false;
      const canBackward = atSectionStart === true ? hasPrevSection : Number.isFinite(page) ? page > 0 || hasPrevSection : false;
      const canForward = atSectionEnd === true ? hasNextSection : Number.isFinite(page) && Number.isFinite(pageCount) ? page + 1 < pageCount || hasNextSection : false;
      const bodyStyle = globalThis.getComputedStyle?.(globalThis.document?.body ?? null);
      const computedFontSizeCSS = bodyStyle?.fontSize ?? null;
      const pageIndex = Number.isFinite(page) ? Math.max(0, page) : 0;
      const allLiveChunks = Array.from(liveRoot?.querySelectorAll?.(".manabi-page-column-chunk") || []);
      const closestPageForElement = (element) => element?.closest?.(".manabi-page") || null;
      const closestChunkForElement = (element) => element?.closest?.(".manabi-page-column-chunk") || null;
      const viewportRect = (() => {
        try {
          return document.getElementById("reader-stage")?.getBoundingClientRect?.() || document.getElementById("manabi-same-document-viewport")?.getBoundingClientRect?.() || null;
        } catch {
          return null;
        }
      })();
      const viewportCenterX = viewportRect ? Math.round(viewportRect.left + viewportRect.width / 2) : null;
      const viewportCenterY = viewportRect ? Math.round(viewportRect.top + viewportRect.height / 2) : null;
      const viewportCenterElement = viewportCenterX != null && viewportCenterY != null && liveDoc?.elementFromPoint ? liveDoc.elementFromPoint(viewportCenterX, viewportCenterY) : null;
      const viewportCenterChunk = closestChunkForElement(viewportCenterElement) || allLiveChunks.find((node) => {
        const rect = node?.getBoundingClientRect?.();
        return rect && rect.width > 0 && rect.height > 0 && viewportCenterX != null && viewportCenterY != null && viewportCenterX >= rect.left && viewportCenterX <= rect.right && viewportCenterY >= rect.top && viewportCenterY <= rect.bottom;
      }) || null;
      const liveChunk = viewportCenterChunk || liveRoot?.querySelector?.(".manabi-page .manabi-page-column-chunk") || liveRoot?.querySelector?.(".manabi-page-column-chunk") || null;
      const viewportCenterPage = closestPageForElement(viewportCenterElement) || closestPageForElement(viewportCenterChunk) || allLivePages.find((node) => {
        const rect = node?.getBoundingClientRect?.();
        return rect && rect.width > 0 && rect.height > 0 && viewportCenterX != null && viewportCenterY != null && viewportCenterX >= rect.left && viewportCenterX <= rect.right && viewportCenterY >= rect.top && viewportCenterY <= rect.bottom;
      }) || null;
      const livePage = viewportCenterPage || closestPageForElement(liveChunk) || liveRoot?.querySelector?.(".manabi-page") || null;
      const layoutLiveCurrentPageIndex = livePage ? allLivePages.indexOf(livePage) : -1;
      const layoutLiveCurrentChunkPageIndex = liveChunk ? allLivePages.findIndex((pageNode) => pageNode?.contains?.(liveChunk)) : -1;
      const layoutViewportCenterChunkPageIndex = viewportCenterChunk ? allLivePages.findIndex((pageNode) => pageNode?.contains?.(viewportCenterChunk)) : -1;
      const visibleRangeFor = (index) => {
        try {
          return typeof sectionLayoutController?.visibleSourceRange === "function" ? sectionLayoutController.visibleSourceRange(index) : null;
        } catch {
          return null;
        }
      };
      const sampleForRange = (range) => {
        try {
          const text = range?.toString?.() ?? "";
          const normalized = String(text).replace(/\s+/g, " ").trim();
          return normalized ? normalized.slice(0, 180) : null;
        } catch {
          return null;
        }
      };
      const currentPageTextSample = sampleForRange(visibleRangeFor(pageIndex));
      const nextPageTextSample = Number.isFinite(pageCount) && pageIndex + 1 < pageCount ? sampleForRange(visibleRangeFor(pageIndex + 1)) : null;
      const pageTargets = Array.isArray(globalThis.navHUD?.pageTargets) ? globalThis.navHUD.pageTargets : [];
      const normalizedPageTarget = Number.isFinite(pageIndex) && pageIndex >= 0 ? pageTargets[pageIndex] ?? null : null;
      const normalizedTotalPages = Number.isFinite(pageCount) && pageCount > 0 ? pageCount : pageTargets.length > 0 ? pageTargets.length : null;
      const normalizedDisplayLabel = (value) => {
        if (typeof value !== "string")
          return null;
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : null;
      };
      const currentPageDisplayLabel = (() => {
        const latestLabel = normalizedDisplayLabel(globalThis.navHUD?.latestPrimaryLabel);
        if (latestLabel) {
          return latestLabel;
        }
        if (typeof globalThis.navHUD?.getPrimaryDisplayLabel === "function" && Number.isFinite(pageIndex) && pageIndex >= 0) {
          const computedLabel = normalizedDisplayLabel(globalThis.navHUD.getPrimaryDisplayLabel({
            pageItem: normalizedPageTarget,
            pageNumber: pageIndex + 1,
            pageCount: normalizedTotalPages,
            location: normalizedTotalPages ? { current: pageIndex, total: normalizedTotalPages } : null
          }));
          if (computedLabel) {
            return computedLabel;
          }
        }
        if (Number.isFinite(pageIndex) && pageIndex >= 0) {
          if (typeof normalizedTotalPages === "number" && normalizedTotalPages > 0) {
            return `Page ${pageIndex + 1} of ${normalizedTotalPages}`;
          }
          return `Page ${pageIndex + 1}`;
        }
        return null;
      })();
      const currentPhysicalPageLabel = (() => {
        const diagnosticLabel = normalizedDisplayLabel(globalThis.navHUD?.lastPrimaryLabelDiagnostics?.pageItemLabel);
        if (diagnosticLabel) {
          return diagnosticLabel;
        }
        return normalizedDisplayLabel(normalizedPageTarget?.label);
      })();
      const livePageIndex = Number.isFinite(layoutLiveCurrentPageIndex) && layoutLiveCurrentPageIndex >= 0 ? layoutLiveCurrentPageIndex : null;
      const liveChunkPageIndex = Number.isFinite(layoutLiveCurrentChunkPageIndex) && layoutLiveCurrentChunkPageIndex >= 0 ? layoutLiveCurrentChunkPageIndex : null;
      const viewportCenterChunkPageIndex = Number.isFinite(layoutViewportCenterChunkPageIndex) && layoutViewportCenterChunkPageIndex >= 0 ? layoutViewportCenterChunkPageIndex : null;
      const loadEBookStarted = !!globalThis.manabiLoadEBookStarted;
      const loadEBookReady = !!globalThis.manabiLoadEBookReady;
      const loadEBookAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
      const loadEBookStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0) || 0;
      const loadEBookStartAgeMs = loadEBookStartedAt > 0 ? Math.max(0, Date.now() - loadEBookStartedAt) : null;
      const loadEBookLastState = globalThis.manabiLoadEBookLastState ?? null;
      const previousLoadEBookState = globalThis.manabiPreviousLoadEBookLastState ?? null;
      const previousLoadEBookError = globalThis.manabiPreviousLoadEBookError ?? null;
      const shouldReportPreviousLoadIssue = !view && !renderer && !loadEBookReady && loadEBookLastState !== "open-resolved" && loadEBookLastState !== "posting-loaded";
      return {
        hasView: !!view,
        hasRenderer: !!renderer,
        canNext: typeof view?.next === "function",
        canPrev: typeof view?.prev === "function",
        canForward: canForward || (Number.isFinite(page) && Number.isFinite(pageCount) ? page + 1 < pageCount : false),
        canBackward: canBackward || (Number.isFinite(page) ? page > 0 : false),
        hasSectionLayoutController: !!sectionLayoutController,
        bookDirection: globalThis.reader?.book?.dir ?? view?.book?.dir ?? null,
        isRightToLeft: !!(globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl ?? (globalThis.reader?.book?.dir ?? view?.book?.dir ?? "").toLowerCase() === "rtl"),
        isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
        isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
        currentSectionIndex,
        currentSectionHref,
        currentPage: Number.isFinite(page) ? page : null,
        pageCount: Number.isFinite(pageCount) ? pageCount : null,
        layoutPageRecordCount,
        layoutLiveRootExists,
        layoutLiveRootClassName,
        layoutLiveRootChildCount,
        layoutLiveRootRectWidth,
        layoutLiveRootRectHeight,
        layoutLiveCurrentPageExists,
        layoutLiveCurrentPageClassName,
        layoutLiveCurrentPageRectWidth,
        layoutLiveCurrentPageRectHeight,
        layoutLiveCurrentPageContainsChunkBody,
        layoutLiveCurrentChunkExists,
        layoutLiveCurrentChunkTagName,
        layoutLiveCurrentChunkClassName,
        layoutLiveCurrentChunkDisplay,
        layoutLiveCurrentChunkPosition,
        layoutLiveCurrentChunkFlex,
        layoutLiveCurrentChunkRectWidth,
        layoutLiveCurrentChunkRectHeight,
        layoutLiveCurrentChunkInnerHTMLLength,
        layoutLiveCurrentChunkContainsChunkBody,
        layoutLiveCurrentChunkChildCount,
        layoutLiveCurrentChunkTextLength,
        layoutCurrentChunkBodyChildCount,
        layoutCurrentChunkBodyTextLength,
        layoutCurrentChunkBodyDisplay,
        layoutCurrentChunkBodyPosition,
        layoutCurrentChunkBodyFlex,
        layoutColumnCount,
        layoutCurrentPageIndex,
        layoutCurrentPageChunkCount,
        layoutMaxPageChunkCount,
        layoutUnitCount,
        layoutActiveBuildPageIndex,
        layoutComplete,
        layoutSpreadCandidateDetected,
        layoutVisibleUnitKind,
        layoutVisibleUnitAxis,
        layoutVisiblePageCount,
        layoutCurrentUnitIndex,
        layoutLeadingPageIndex,
        layoutTrailingPageIndex,
        layoutHasLeadingSingleton,
        layoutHasTrailingSingleton,
        layoutMultiUnitActive,
        layoutSpreadPagesAllowedForViewport,
        layoutWritingMode,
        layoutViewportWidth,
        layoutViewportHeight,
        layoutMeasuredGap,
        layoutMetricSize,
        layoutColumnInlineSize,
        layoutCurrentChunkClientWidth,
        layoutCurrentChunkClientHeight,
        layoutCurrentChunkScrollWidth,
        layoutCurrentChunkScrollHeight,
        layoutCurrentChunkOverflow,
        computedFontSizeCSS,
        currentPageTextSample,
        nextPageTextSample,
        currentPageDisplayLabel,
        currentPhysicalPageLabel,
        livePageIndex,
        liveChunkPageIndex,
        viewportCenterChunkPageIndex,
        loadEBookStarted,
        loadEBookReady,
        loadEBookAttemptCount,
        loadEBookStartAgeMs,
        loadEBookLastState,
        probeError: shouldReportPreviousLoadIssue ? previousLoadEBookError ?? previousLoadEBookState ?? null : null
      };
    } catch (error) {
      const loadEBookStarted = !!globalThis.manabiLoadEBookStarted;
      const loadEBookReady = !!globalThis.manabiLoadEBookReady;
      const loadEBookAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
      const loadEBookStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0) || 0;
      const loadEBookStartAgeMs = loadEBookStartedAt > 0 ? Math.max(0, Date.now() - loadEBookStartedAt) : null;
      const loadEBookLastState = globalThis.manabiLoadEBookLastState ?? null;
      const previousLoadEBookState = globalThis.manabiPreviousLoadEBookLastState ?? null;
      const previousLoadEBookError = globalThis.manabiPreviousLoadEBookError ?? null;
      const hasView = !!globalThis.reader?.view;
      const hasRenderer = !!globalThis.reader?.view?.renderer;
      const shouldReportPreviousLoadIssue = !hasView && !hasRenderer && !loadEBookReady && loadEBookLastState !== "open-resolved" && loadEBookLastState !== "posting-loaded";
      return {
        hasView,
        hasRenderer,
        canNext: typeof globalThis.reader?.view?.next === "function",
        canPrev: typeof globalThis.reader?.view?.prev === "function",
        canForward: false,
        canBackward: false,
        hasSectionLayoutController: !!(globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController ?? globalThis.manabiEbookSectionLayoutController),
        bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
        isRightToLeft: !!(globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl ?? (globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? "").toLowerCase() === "rtl"),
        isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
        isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
        currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex) ? globalThis.reader.view.renderer.currentIndex : null,
        currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex) ? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url ?? null : null,
        currentPage: null,
        pageCount: null,
        layoutPageRecordCount: null,
        layoutLiveRootExists: null,
        layoutLiveRootClassName: null,
        layoutLiveRootChildCount: null,
        layoutLiveRootRectWidth: null,
        layoutLiveRootRectHeight: null,
        layoutLiveCurrentPageExists: null,
        layoutLiveCurrentPageClassName: null,
        layoutLiveCurrentPageRectWidth: null,
        layoutLiveCurrentPageRectHeight: null,
        layoutLiveCurrentChunkExists: null,
        layoutLiveCurrentChunkClassName: null,
        layoutLiveCurrentChunkRectWidth: null,
        layoutLiveCurrentChunkRectHeight: null,
        layoutColumnCount: null,
        layoutCurrentPageIndex: null,
        layoutCurrentPageChunkCount: null,
        layoutMaxPageChunkCount: null,
        layoutUnitCount: null,
        layoutActiveBuildPageIndex: null,
        layoutComplete: null,
        layoutSpreadCandidateDetected: null,
        layoutVisibleUnitKind: null,
        layoutVisibleUnitAxis: null,
        layoutVisiblePageCount: null,
        layoutCurrentUnitIndex: null,
        layoutLeadingPageIndex: null,
        layoutTrailingPageIndex: null,
        layoutMultiUnitActive: null,
        layoutSpreadPagesAllowedForViewport: null,
        layoutWritingMode: null,
        layoutViewportWidth: null,
        layoutViewportHeight: null,
        layoutMetricSize: null,
        layoutColumnInlineSize: null,
        layoutCurrentChunkClientWidth: null,
        layoutCurrentChunkClientHeight: null,
        layoutCurrentChunkScrollWidth: null,
        layoutCurrentChunkScrollHeight: null,
        layoutCurrentChunkOverflow: null,
        computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
        currentPageTextSample: null,
        nextPageTextSample: null,
        livePageIndex: null,
        liveChunkPageIndex: null,
        viewportCenterChunkPageIndex: null,
        loadEBookStarted,
        loadEBookReady,
        loadEBookAttemptCount,
        loadEBookStartAgeMs,
        loadEBookLastState,
        probeError: shouldReportPreviousLoadIssue ? previousLoadEBookError ?? previousLoadEBookState ?? String(error) : String(error)
      };
    }
  };
  window.manabiGetPageTurnProbeSnapshotJSON = async () => {
    try {
      return JSON.stringify(await window.manabiGetPageTurnProbeSnapshot());
    } catch (error) {
      return JSON.stringify({
        hasView: !!globalThis.reader?.view,
        hasRenderer: !!globalThis.reader?.view?.renderer,
        canNext: typeof globalThis.reader?.view?.next === "function",
        canPrev: typeof globalThis.reader?.view?.prev === "function",
        canForward: false,
        canBackward: false,
        hasSectionLayoutController: !!(globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController ?? globalThis.manabiEbookSectionLayoutController),
        bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
        isRightToLeft: !!(globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl ?? (globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? "").toLowerCase() === "rtl"),
        isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
        isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
        currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex) ? globalThis.reader.view.renderer.currentIndex : null,
        currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex) ? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url ?? null : null,
        currentPage: null,
        pageCount: null,
        computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
        currentPageTextSample: null,
        nextPageTextSample: null,
        livePageIndex: null,
        liveChunkPageIndex: null,
        viewportCenterChunkPageIndex: null,
        probeError: `probe-json-wrapper:${String(error)}`
      });
    }
  };
  window.loadEBook = ({
    url,
    layoutMode
  }) => {
    const priorAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
    if (priorAttemptCount > 0 && globalThis.manabiLoadEBookReady !== true) {
      globalThis.manabiPreviousLoadEBookLastState = globalThis.manabiLoadEBookLastState ?? `restart-before-ready:attempt-${priorAttemptCount}`;
      globalThis.manabiPreviousLoadEBookError = globalThis.manabiPreviousLoadEBookError ?? globalThis.manabiLoadEBookLastState ?? `restart-before-ready:attempt-${priorAttemptCount}`;
    }
    globalThis.manabiLoadEBookLastState = "called";
    globalThis.manabiLoadEBookStarted = true;
    globalThis.manabiLoadEBookStartedAt = Date.now();
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookAttemptCount = (Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) + 1;
    const loadAttemptNumber = globalThis.manabiLoadEBookAttemptCount;
    logFix2("loadEBook:called", {
      hasURL: !!url,
      attempt: loadAttemptNumber,
      layoutMode: layoutMode ?? null,
      pageURL: window.location.href
    });
    let reader = new Reader();
    globalThis.reader = reader;
    globalThis.manabiLoadEBookLastState = "reader-created";
    logFix2("loadEBook:reader-created", {
      hasReader: !!globalThis.reader,
      hasView: !!globalThis.reader?.view
    });
    setTimeout(() => logReaderBootstrapState("loadEBook:delayed-state:1s"), 1e3);
    setTimeout(() => logReaderBootstrapState("loadEBook:delayed-state:3s"), 3e3);
    setTimeout(() => logReaderBootstrapState("loadEBook:delayed-state:8s"), 8e3);
    if (pendingHideNavigationState !== null) {
      reader.setHideNavigationDueToScroll(pendingHideNavigationState);
      pendingHideNavigationState = null;
    }
    window.cacheWarmer = new CacheWarmer();
    if (url) {
      const source = makeNativeSource(url);
      window.bookSource = source;
      if (layoutMode) {
        window.initialLayoutMode = layoutMode;
      }
      const isCurrentAttempt = () => (Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) === loadAttemptNumber && globalThis.reader === reader;
      setTimeout(() => {
        const currentAttempt = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
        const hasRendererNow = !!globalThis.reader?.view?.renderer;
        if (globalThis.manabiLoadEBookReady || hasRendererNow || currentAttempt !== loadAttemptNumber) {
          return;
        }
        globalThis.manabiPreviousLoadEBookLastState = globalThis.manabiLoadEBookLastState ?? "open-watchdog-timeout";
        globalThis.manabiPreviousLoadEBookError = "open-watchdog-timeout";
        globalThis.manabiLoadEBookStarted = false;
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = "open-watchdog-timeout";
        try {
          globalThis.reader?.close?.();
        } catch (_error) {
        }
        try {
          globalThis.reader?.view?.close?.();
        } catch (_error) {
        }
        globalThis.reader = null;
        logFix2("loadEBook:watchdog-timeout", {
          attempt: loadAttemptNumber,
          pageURL: window.location.href,
          retrying: loadAttemptNumber < 4
        });
        if (loadAttemptNumber < 4) {
          setTimeout(() => {
            if ((Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) === loadAttemptNumber && typeof window.loadEBook === "function") {
              window.loadEBook({ url, layoutMode });
            }
          }, 0);
        }
      }, 6e3);
      globalThis.manabiLoadEBookLastState = "open-requested";
      Promise.resolve(reader.open(source)).then(async () => {
        if (!isCurrentAttempt()) {
          logFix2("loadEBook:open-resolved-stale-attempt", {
            attempt: loadAttemptNumber,
            activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
            localHasView: !!reader?.view,
            localHasRenderer: !!reader?.view?.renderer,
            globalHasView: !!globalThis.reader?.view,
            globalHasRenderer: !!globalThis.reader?.view?.renderer
          });
          return;
        }
        globalThis.manabiLoadEBookReady = true;
        globalThis.manabiLoadEBookLastState = "open-resolved";
        logFix2("loadEBook:open-resolved", {
          hasReader: !!reader,
          hasView: !!reader?.view,
          hasRenderer: !!reader?.view?.renderer
        });
        try {
          const currentDoc = reader?.view?.document;
          if (currentDoc) {
            await globalThis.manabiEnsureCustomFonts?.(currentDoc);
          }
        } catch (_error) {
        }
      }).then(async () => {
        if (!isCurrentAttempt()) {
          logFix2("loadEBook:posting-loaded-stale-attempt", {
            attempt: loadAttemptNumber,
            activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
            localHasView: !!reader?.view,
            localHasRenderer: !!reader?.view?.renderer,
            globalHasView: !!globalThis.reader?.view,
            globalHasRenderer: !!globalThis.reader?.view?.renderer
          });
          return;
        }
        globalThis.manabiLoadEBookLastState = "posting-loaded";
        const loadedProbe = {
          hasView: !!reader?.view,
          hasRenderer: !!reader?.view?.renderer,
          canForward: !!reader?.view?.renderer?.getHasNextSection?.(),
          canBackward: !!reader?.view?.renderer?.getHasPrevSection?.(),
          currentPage: typeof reader?.view?.renderer?.page === "function" ? await Promise.resolve(reader.view.renderer.page()).catch(() => null) : null,
          pageCount: typeof reader?.view?.renderer?.pages === "function" ? await Promise.resolve(reader.view.renderer.pages()).catch(() => null) : null,
          loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
          loadEBookReady: true,
          probeError: null
        };
        logFix2("loadEBook:posting-loaded", {
          hasReader: !!reader,
          hasView: !!reader?.view,
          hasRenderer: !!reader?.view?.renderer,
          probeHasView: loadedProbe?.hasView ?? null,
          probeHasRenderer: loadedProbe?.hasRenderer ?? null
        });
        window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
          probe: loadedProbe
        });
      }).catch((error) => {
        if (!isCurrentAttempt()) {
          logFix2("loadEBook:open-error-stale-attempt", {
            attempt: loadAttemptNumber,
            activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
            message: error?.message ?? String(error)
          });
          return;
        }
        globalThis.manabiPreviousLoadEBookLastState = globalThis.manabiLoadEBookLastState ?? "open-error";
        globalThis.manabiPreviousLoadEBookError = String(error);
        globalThis.manabiLoadEBookStarted = false;
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = "open-error:" + String(error);
        try {
          postReaderOnError({
            message: sanitizeErrorValue(error?.message) ?? "loadEBook failed",
            source: sanitizeErrorValue(url),
            lineno: null,
            colno: null,
            error: sanitizeErrorValue(error?.stack ?? error)
          });
        } catch (_reportError) {
        }
        throw error;
      });
    }
  };
  var scheduleAutomaticInitialBookLoad = () => {
    let parsedURL = null;
    try {
      parsedURL = new URL(window.location.href);
    } catch (_error) {
      return;
    }
    if (parsedURL.protocol !== "ebook:" || !parsedURL.pathname.startsWith("/load/")) {
      return;
    }
    const start = (attempt = 0) => {
      if (globalThis.manabiLoadEBookStarted) {
        return;
      }
      if (typeof window.loadEBook !== "function") {
        if (attempt < 10) {
          setTimeout(() => start(attempt + 1), Math.min(1e3, 100 * (attempt + 1)));
        }
        return;
      }
      logFix2("loadEBook:auto-bootstrap", {
        attempt,
        pageURL: window.location.href
      });
      window.loadEBook({
        url: window.location.href,
        layoutMode: globalThis.window.initialLayoutMode ?? "paginated"
      });
    };
    setTimeout(() => start(0), 0);
  };
  scheduleAutomaticInitialBookLoad();
  window.loadLastPosition = async ({
    cfi,
    fractionalCompletion
  }) => {
    globalThis.reader.hasLoadedLastPosition = true;
    const parsedFraction = Number(fractionalCompletion);
    const hasFractionalCompletion = Number.isFinite(parsedFraction);
    const shouldRestoreFraction = hasFractionalCompletion && parsedFraction > 0;
    const restoreFirstSection = async (reason) => {
      await globalThis.reader.view.renderer.firstSection();
      logFix2("loadLastPosition:first-section", {
        reason,
        hasCFI: cfi.length > 0,
        hasFractionalCompletion,
        fractionalCompletion: hasFractionalCompletion ? parsedFraction : null
      });
    };
    if (cfi.length > 0) {
      await globalThis.reader.view.goTo(cfi).catch(async (e2) => {
        console.error(e2);
        if (shouldRestoreFraction) {
          await globalThis.reader.view.goToFraction(parsedFraction);
          logFix2("loadLastPosition:fraction-fallback", {
            reason: "cfi-error",
            fractionalCompletion: parsedFraction
          });
        } else {
          await restoreFirstSection("cfi-error");
        }
      });
    } else if (shouldRestoreFraction) {
      await globalThis.reader.view.goToFraction(parsedFraction);
      logFix2("loadLastPosition:fraction", {
        fractionalCompletion: parsedFraction
      });
    } else {
      await restoreFirstSection("no-saved-position");
    }
    try {
      const key = getBookCacheKey();
      const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER2];
      if (key && handler?.postMessage) {
        handler.postMessage({ command: "get", key: `${key}::pageCounts` });
      }
    } catch (error) {
      logFix2("pagecount:restore:error", { error: String(error) });
    }
    if (window.bookSource) {
      await window.cacheWarmer.open(window.bookSource);
    }
  };
  globalThis.manabiResolveTrackingSizeCache = function(requestId, entries) {
    if (typeof requestId === "string" && requestId.endsWith("::pageCounts")) {
      try {
        const map = new Map(entries ?? []);
        if (map.size > 0) {
          globalThis.cacheWarmerPageCounts = map;
          globalThis.cacheWarmerTotalPages = Array.from(map.values()).reduce((a2, v2) => a2 + (Number.isFinite(v2) ? v2 : 0), 0);
          document.dispatchEvent(new CustomEvent("cachewarmer:pagecounts", {
            detail: {
              counts: Array.from(map.entries()),
              total: globalThis.cacheWarmerTotalPages,
              source: "cache"
            }
          }));
          logFix2("pagecount:restored", { size: map.size, total: globalThis.cacheWarmerTotalPages });
        }
      } catch (error) {
        logFix2("pagecount:restore:handler:error", { error: String(error) });
      }
    }
    if (typeof globalThis.manabiResolveTrackingSizeCacheOriginal === "function") {
      return globalThis.manabiResolveTrackingSizeCacheOriginal(requestId, entries);
    }
  };
  if (!globalThis.manabiResolveTrackingSizeCacheOriginal) {
    globalThis.manabiResolveTrackingSizeCacheOriginal = globalThis.manabiResolveTrackingSizeCache;
  }
  window.refreshBookReadingProgress = async (articleReadingProgress) => {
    globalThis.reader.markedAsFinished = !!articleReadingProgress.articleMarkedAsFinished;
    await globalThis.reader.updateNavButtons();
  };
  window.nextSection = async () => {
    const btn = globalThis.reader?.buttons?.next;
    if (btn && btn.offsetParent !== null && getComputedStyle(btn).visibility !== "hidden") {
      btn.click();
    } else {
      await globalThis.reader?.view?.renderer?.nextSection?.();
    }
  };
  logFix2("module:posting-initialized", {
    pageURL: window.location.href,
    bodyReady: !!document.body
  });
  globalThis.manabiEbookViewerInitializedAck = false;
  globalThis.manabiMarkEbookViewerInitializedAck = () => {
    globalThis.manabiEbookViewerInitializedAck = true;
  };
  var postEbookViewerInitialized = (attempt = 0) => {
    if (globalThis.manabiEbookViewerInitializedAck) {
      return;
    }
    const handler = window.webkit?.messageHandlers?.ebookViewerInitialized;
    if (handler?.postMessage) {
      try {
        handler.postMessage({ attempt });
        logFix2("ebookViewerInitialized:posted", { attempt });
      } catch (error) {
        logFix2("ebookViewerInitialized:post:error", {
          attempt,
          error: String(error)
        });
      }
    } else {
      logFix2("ebookViewerInitialized:handler:missing", { attempt });
    }
    if (!globalThis.manabiEbookViewerInitializedAck && attempt < 10) {
      setTimeout(() => postEbookViewerInitialized(attempt + 1), Math.min(1e3, 100 * (attempt + 1)));
    }
  };
  postEbookViewerInitialized();
})();
