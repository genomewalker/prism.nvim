--- prism.nvim memory search module
--- Simple TF-IDF text search for memory retrieval
--- @module prism.memory.search

local M = {}

--- Tokenize text into words
--- @param text string Text to tokenize
--- @return string[] Array of lowercase tokens
function M.tokenize(text)
  if not text or text == "" then
    return {}
  end

  local tokens = {}
  -- Convert to lowercase and split on non-alphanumeric
  for word in text:lower():gmatch("[%w_]+") do
    if #word > 1 then -- Skip single characters
      table.insert(tokens, word)
    end
  end
  return tokens
end

--- Calculate term frequency for a document
--- @param tokens string[] Token array
--- @return table<string, number> Term frequencies
local function term_frequency(tokens)
  local tf = {}
  local total = #tokens

  if total == 0 then
    return tf
  end

  for _, token in ipairs(tokens) do
    tf[token] = (tf[token] or 0) + 1
  end

  -- Normalize by document length
  for token, count in pairs(tf) do
    tf[token] = count / total
  end

  return tf
end

--- Build TF-IDF index from documents
--- @param documents table[] Array of {id, content, ...}
--- @return table Index for searching
function M.index(documents)
  local doc_count = #documents
  local doc_freq = {} -- Document frequency for each term
  local doc_tfs = {} -- Term frequencies per document

  -- Calculate TF for each document and build document frequency
  for i, doc in ipairs(documents) do
    local content = doc.content or ""
    if doc.key then
      content = content .. " " .. doc.key
    end
    if doc.metadata and doc.metadata.tags then
      content = content .. " " .. table.concat(doc.metadata.tags, " ")
    end

    local tokens = M.tokenize(content)
    local tf = term_frequency(tokens)
    doc_tfs[i] = tf

    -- Track which documents contain each term
    local seen = {}
    for _, token in ipairs(tokens) do
      if not seen[token] then
        doc_freq[token] = (doc_freq[token] or 0) + 1
        seen[token] = true
      end
    end
  end

  -- Calculate IDF for each term
  local idf = {}
  for term, df in pairs(doc_freq) do
    idf[term] = math.log(doc_count / df)
  end

  return {
    documents = documents,
    doc_tfs = doc_tfs,
    idf = idf,
    doc_count = doc_count,
  }
end

--- Calculate TF-IDF score for a query against a document
--- @param query_tokens string[] Query tokens
--- @param doc_tf table<string, number> Document term frequencies
--- @param idf table<string, number> Inverse document frequencies
--- @return number Score
local function tfidf_score(query_tokens, doc_tf, idf)
  local score = 0
  local query_tf = term_frequency(query_tokens)

  for term, qtf in pairs(query_tf) do
    local dtf = doc_tf[term] or 0
    local term_idf = idf[term] or 0
    score = score + (qtf * dtf * term_idf)
  end

  return score
end

--- Search the index
--- @param query string Search query
--- @param idx table Index built by M.index()
--- @param k number|nil Max results to return (default 10)
--- @return table[] Matching documents with scores
function M.search(query, idx, k)
  k = k or 10

  if not idx or not idx.documents or #idx.documents == 0 then
    return {}
  end

  local query_tokens = M.tokenize(query)
  if #query_tokens == 0 then
    return {}
  end

  -- Score all documents
  local scores = {}
  for i, doc in ipairs(idx.documents) do
    local score = tfidf_score(query_tokens, idx.doc_tfs[i], idx.idf)
    if score > 0 then
      table.insert(scores, { doc = doc, score = score })
    end
  end

  -- Sort by score descending
  table.sort(scores, function(a, b)
    return a.score > b.score
  end)

  -- Return top k
  local results = {}
  for i = 1, math.min(k, #scores) do
    local item = scores[i]
    results[i] = vim.tbl_extend("force", vim.deepcopy(item.doc), { score = item.score })
  end

  return results
end

--- Calculate TF-IDF vector for a document (for similarity comparisons)
--- @param text string Document text
--- @param idf table<string, number> IDF values from an index
--- @return table<string, number> TF-IDF vector
function M.tfidf(text, idf)
  local tokens = M.tokenize(text)
  local tf = term_frequency(tokens)
  local tfidf_vec = {}

  for term, freq in pairs(tf) do
    local term_idf = idf[term] or 0
    tfidf_vec[term] = freq * term_idf
  end

  return tfidf_vec
end

return M
