# Image for the mem0 MCP server, built from the VENDORED fork at ../server.
#
# This is the whole point of vendoring: previously this installed from
# `git+https://github.com/brady-zip/mem0-mcp-selfhosted.git` (unpinned main)
# while the plugin's hooks installed from ../server. Both happened to be v0.11.0,
# but nothing enforced it — a change to hooks.py would reach the hooks
# immediately and the server only on the next rebuild. Now there is one source.
#
# Build context is the PLUGIN ROOT (see stack/docker-compose.yml), not this dir.
FROM python:3.12-slim

# git is not needed to install from a local path, but several scientific wheels
# still shell out to it during metadata resolution on some platforms. Cheap
# insurance; drop it if you ever want a slimmer image and builds stay green.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# The vendored fork. Copied before the install so the layer caches on source
# changes only.
COPY server/ /opt/mem0-mcp-selfhosted/

# Dep extras deliberately differ from the plugin's host-side `uv tool install`.
# The CODE is what must match, and does — both install the same /opt source tree.
#   --with fastembed             : Qdrant BM25 sparse vectors → hybrid (dense+keyword) search.
#   --with "mem0ai[nlp]"         : spaCy lemmatizer feeding BM25 (plural/tense normalization).
#   --with pip                   : `spacy download` shells out to pip; the uv-tool venv needs it.
#   --with sentence-transformers : the local CrossEncoder reranker. Carries torch, which is
#                                  most of this image's size. Omit it AND unset
#                                  MEM0_RERANK_PROVIDER together: config.py reads that key
#                                  whether or not the dependency is present, so dropping only
#                                  one of the two is what produces an import error at startup.
# [direct] pulls mem0ai + its providers: the SERVER runs mem0 in-process, so it
# needs them. Hosts that reach this server over MCP install the package without
# that extra and stay small.
RUN uv tool install "/opt/mem0-mcp-selfhosted[direct]" \
    --with fastembed \
    --with "mem0ai[nlp]" \
    --with pip \
    --with sentence-transformers
ENV PATH="/root/.local/bin:${PATH}"

# Pin the HF cache so models baked at build time (as root) are found at runtime
# (also root) — otherwise fastembed re-downloads the BM25 files on each recreate.
ENV HF_HOME=/root/.cache/huggingface

# Bake both models INTO the image so nothing downloads at runtime.
# en_core_web_sm serves BOTH mem0 spaCy loaders (lemma = BM25 normalization,
# full = graph entity extraction). `spacy download` auto-picks the version
# compatible with the installed spaCy.
RUN /root/.local/share/uv/tools/mem0-mcp-selfhosted/bin/python -m spacy download en_core_web_sm
# Prefetch the fastembed BM25 model (Qdrant/bm25) + its stopword files.
RUN /root/.local/share/uv/tools/mem0-mcp-selfhosted/bin/python \
    -c "from fastembed import SparseTextEmbedding; SparseTextEmbedding('Qdrant/bm25')"
# Prefetch the CrossEncoder reranker. Without this the first search after every
# container recreate pays the model download, and a search is exactly the path
# that must not block — recall hooks fail open, so a slow first call reads as
# memory being empty rather than as a cold start.
RUN /root/.local/share/uv/tools/mem0-mcp-selfhosted/bin/python \
    -c "from sentence_transformers import CrossEncoder; CrossEncoder('cross-encoder/ms-marco-MiniLM-L-6-v2')"

# streamable-http listen port (see MEM0_PORT in .env)
EXPOSE 8081

CMD ["mem0-mcp-selfhosted"]
